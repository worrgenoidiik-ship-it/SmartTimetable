import Foundation
import SwiftSoup

/// The student's group and current semester, read from data the portal already gives us,
/// so classmates from other groups get their own schedule and the right semester by default.
enum StudentGroup {
    /// «ИС-О-25/1», «ИС_О_25/1» → «ИС-О-25/1».
    static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "").uppercased()
    }

    /// Most frequent group code in the course titles (they look like «… ИС-О-25/1 (…)»).
    /// Codes of other faculties have small letters too («ФКиС-О-23/1», «ИСм-О-25/1», «ЭК-Зу-22/1»);
    /// they are compared without case but shown as the portal writes them.
    static func detect(in courses: [Course]) -> String? {
        var counts: [String: Int] = [:]
        var spelling: [String: String] = [:]
        for course in courses {
            for match in course.title.matches(of: #/([А-ЯЁA-Z][А-ЯЁа-яёA-Za-z]{0,7})[-_]([А-ЯЁA-Z][А-ЯЁа-яёA-Za-z]{0,3})[-_](\d{2})(?:/(\d+))?/#) {
                let code = "\(match.1)-\(match.2)-\(match.3)" + (match.4.map { "/\($0)" } ?? "")
                let key = normalized(code)
                counts[key, default: 0] += 1
                if spelling[key] == nil { spelling[key] = code }
            }
        }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }.flatMap { spelling[$0.key] }
    }

    /// A plan belongs to one group and is shown only to that group. When the group is unknown
    /// (courses not loaded yet, or their titles carry no code) a plan the student imported is
    /// still theirs, but the built-in one is not guessed: other faculties get the portal schedule.
    static func planApplies(to snapshot: PortalSnapshot) -> Bool {
        planApplies(group: detect(in: snapshot.courses?.value ?? []), plan: ManualSchedule.group, imported: ManualSchedule.isImported)
    }

    static func planApplies(group: String?, plan: String, imported: Bool) -> Bool {
        guard let group else { return imported }
        return sameGroup(group, plan)
    }

    /// «ИС-О-25/1» and «ИС-О-25» (subgroup unknown) match; «ИС-О-25/1» and «ИС-О-25/10» do not.
    static func sameGroup(_ a: String, _ b: String) -> Bool {
        let left = normalized(a).split(separator: "/", maxSplits: 1).map(String.init)
        let right = normalized(b).split(separator: "/", maxSplits: 1).map(String.init)
        guard left.first == right.first else { return false }
        return left.count < 2 || right.count < 2 || left[1] == right[1]
    }

    /// Semester number from the enrolment year in the group code: ИС-О-25 → 2025;
    /// September–January is the odd (autumn) semester, February–August the even one.
    static func currentSemester(group: String?, on date: Date = Date()) -> Int? {
        guard let group = group, let match = group.firstMatch(of: #/-(\d{2})(?:/|$)/#), let short = Int(match.1) else { return nil }
        let calendar = CampusDate.calendar
        let year = calendar.component(.year, from: date), month = calendar.component(.month, from: date)
        let academicYear = month >= 9 ? year : year - 1          // year the academic year started
        let course = academicYear - (2000 + short)                 // 0 for the first year
        guard course >= 0, course < 7 else { return nil }
        return course * 2 + (month >= 9 || month == 1 ? 1 : 2)
    }
}

/// «Задать вопрос» (CDO/questionizer.php): the page sends a plain GET to /CDO/lib.php.
struct QuestionForm: Equatable {
    struct Category: Identifiable, Hashable { let id: String; let title: String }
    let categories: [Category]
    let email: String
}

extension PortalParser {
    static func questionForm(html: String, source: URL) throws -> QuestionForm {
        let doc = try SwiftSoup.parse(html, source.absoluteString)
        let options = try doc.select("select#cat option").array().compactMap { option -> QuestionForm.Category? in
            let id = try option.attr("value"), title = clean(try option.text())
            return id.isEmpty || title.isEmpty ? nil : .init(id: id, title: title)
        }
        guard !options.isEmpty, try !doc.select("#subject, #message").isEmpty() else {
            throw PortalFailure.unrecognized("форма вопроса")
        }
        return QuestionForm(categories: options, email: try doc.select("input#reply_type").first()?.attr("value") ?? "")
    }
}

/// A Moodle form (`form.mform`) read generically: visible fields become native controls,
/// hidden ones (sesskey, record book…) are sent back unchanged.
struct PortalForm: Equatable {
    struct Option: Hashable { let value: String; let title: String }
    struct Field: Identifiable, Equatable {
        enum Kind: Equatable { case hidden, text, textarea, select, checkbox }
        var id: String { name }
        let name: String
        let label: String
        let kind: Kind
        let value: String
        let options: [Option]
    }
    let action: URL
    let isPost: Bool
    let fields: [Field]
    let submit: (name: String, value: String)?

    static func == (a: PortalForm, b: PortalForm) -> Bool {
        a.action == b.action && a.isPost == b.isPost && a.fields == b.fields && a.submit?.name == b.submit?.name
    }

    var visibleFields: [Field] { fields.filter { $0.kind != .hidden } }

    /// All name/value pairs for submission, with the user's values for visible fields.
    func payload(_ values: [String: String]) -> [URLQueryItem] {
        var items = fields.compactMap { field -> URLQueryItem? in
            if field.kind == .checkbox && values[field.name] != "1" { return nil }
            return URLQueryItem(name: field.name, value: values[field.name] ?? field.value)
        }
        if let submit = submit { items.append(URLQueryItem(name: submit.name, value: submit.value)) }
        return items
    }
}

extension PortalParser {
    static func forms(html: String, source: URL) throws -> [PortalForm] {
        let doc = try SwiftSoup.parse(html, source.absoluteString)
        // The portal can give several fields the same id (id_form_fields_), so a label is taken
        // from the field's own form row first and by id only when that id is unique.
        var labels: [String: String] = [:]
        var repeated: Set<String> = []
        for label in try doc.select("label[for]").array() {
            let text = clean(try label.text()), target = try label.attr("for")
            if labels[target] != nil { repeated.insert(target) }
            if !text.isEmpty { labels[target] = text }
        }
        func label(of element: Element) throws -> String {
            if let row = ancestor(of: element, where: { $0.hasClass("fitem") || $0.hasClass("form-group") }),
               let text = try row.select("label").array().map({ clean(try $0.text()) }).first(where: { !$0.isEmpty }) {
                return text
            }
            let id = try element.attr("id")
            return repeated.contains(id) ? "" : (labels[id] ?? "")
        }
        return try doc.select("#region-main form.mform").array().compactMap { form in
            guard let action = URL(string: try form.attr("action"), relativeTo: source)?.absoluteURL,
                  PortalConfiguration.allowsDataURL(action) else { return nil }
            var fields: [PortalForm.Field] = []
            var submit: (String, String)?
            for element in try form.select("input[name], select[name], textarea[name]").array() {
                let name = try element.attr("name")
                let label = try label(of: element)
                switch element.tagName() {
                case "select":
                    let options = try element.select("option").array().map {
                        PortalForm.Option(value: try $0.attr("value"), title: clean(try $0.text()))
                    }
                    let selected = try element.select("option[selected]").first()?.attr("value") ?? options.first?.value ?? ""
                    fields.append(.init(name: name, label: label, kind: .select, value: selected, options: options))
                case "textarea":
                    fields.append(.init(name: name, label: label, kind: .textarea, value: try element.text(), options: []))
                default:
                    let type = try element.attr("type").lowercased()
                    if type == "submit" { if submit == nil { submit = (name, try element.attr("value")) }; continue }
                    if type == "button" || type == "file" { continue }
                    let kind: PortalForm.Field.Kind = type == "hidden" ? .hidden : (type == "checkbox" ? .checkbox : .text)
                    fields.append(.init(name: name, label: label, kind: kind, value: try element.attr("value"), options: []))
                }
            }
            return PortalForm(action: action, isPost: (try form.attr("method")).lowercased() == "post", fields: fields, submit: submit)
        }
    }

    /// Text of the portal's notices after a submission (success or error).
    static func notices(html: String, source: URL) -> (text: String, isError: Bool)? {
        guard let doc = try? SwiftSoup.parse(html, source.absoluteString),
              let notice = try? doc.select("#region-main .alert, #user-notifications .alert, #region-main .box.generalbox, #region-main .notifyproblem, #region-main .notifysuccess").first() else { return nil }
        let text = clean((try? notice.text()) ?? "")
        guard !text.isEmpty else { return nil }
        let classes = (try? notice.className()) ?? ""
        return (text, classes.contains("danger") || classes.contains("error") || classes.contains("problem"))
    }
}
