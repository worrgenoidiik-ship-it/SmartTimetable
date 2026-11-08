import Foundation
import SwiftSoup

// Native quiz: the app reads the same pages a browser gets (view.php → attempt.php →
// summary.php → review.php) and posts the same forms the site's buttons post. ЭИОС itself
// stores the answers. Nothing is ever finished without the student's explicit confirmation.

struct QuizOption: Identifiable, Hashable {
    let id: String     // input id
    let name: String
    let value: String
    let label: String
}

enum QuizAnswer: Equatable {
    case single(name: String, options: [QuizOption])
    case multiple(options: [QuizOption])
    case text(name: String, multiline: Bool)
    case selects([QuizSelect])
    case unsupported(String)
}

struct QuizSelect: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let prompt: String
    let options: [PortalForm.Option]
}

struct QuizQuestion: Identifiable, Equatable {
    let id: String
    let number: String
    let state: String
    let grade: String
    let prompt: String
    let text: String
    let images: [URL]
    let answer: QuizAnswer

    var isSupported: Bool { if case .unsupported = answer { return false } else { return true } }
}

/// One page of an attempt (`form#responseform`).
struct QuizAttemptPage: Equatable {
    /// Every form control in document order: the payload is rebuilt in the same order
    /// (Moodle relies on a hidden «0» being followed by the ticked checkbox «1»).
    enum Entry: Equatable {
        case hidden(name: String, value: String)
        case choice(id: String, name: String, value: String)      // radio or checkbox
        case input(name: String, value: String)                   // text field / textarea / select
    }
    let title: String
    let url: URL
    let action: URL
    let entries: [Entry]
    let questions: [QuizQuestion]
    let next: (name: String, value: String)?
    let previous: (name: String, value: String)?
    let timeLeft: TimeInterval?
    let pageNumber: Int

    static func == (a: QuizAttemptPage, b: QuizAttemptPage) -> Bool {
        a.url == b.url && a.entries == b.entries && a.questions == b.questions
    }

    var hasUnsupported: Bool { questions.contains { !$0.isSupported } }

    /// The answers already on the page (radio/checkbox ticks, typed text) as editable state.
    var initialState: (values: [String: String], checked: Set<String>) {
        var values: [String: String] = [:], checked: Set<String> = []
        for entry in entries {
            if case .input(let name, let value) = entry { values[name] = value }
        }
        for question in questions {
            switch question.answer {
            case .single(let name, let options): if let picked = options.first(where: { initialChecked.contains($0.id) }) { values[name] = picked.value }
            case .multiple(let options): checked.formUnion(options.map(\.id).filter(initialChecked.contains))
            default: break
            }
        }
        return (values, checked)
    }
    var initialChecked: Set<String> = []

    /// What the browser would send for these answers. `button` is next/previous/timeup.
    func payload(values: [String: String], checked: Set<String>, button: (name: String, value: String)?,
                 timeUp: Bool = false) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        let radios = Set(questions.compactMap { question -> String? in
            if case .single(let name, _) = question.answer { return name } else { return nil }
        })
        for entry in entries {
            switch entry {
            case .hidden(let name, let value):
                items.append(URLQueryItem(name: name, value: name == "timeup" && timeUp ? "1" : value))
            case .choice(let id, let name, let value):
                if radios.contains(name) {
                    if values[name] == value { items.append(URLQueryItem(name: name, value: value)) }
                } else if checked.contains(id) {
                    items.append(URLQueryItem(name: name, value: value))
                }
            case .input(let name, let value):
                items.append(URLQueryItem(name: name, value: values[name] ?? value))
            }
        }
        if let button = button { items.append(URLQueryItem(name: button.name, value: button.value)) }
        return items
    }
}

/// summary.php: status of each question and the «Отправить всё и завершить тест» form.
struct QuizSummary: Equatable {
    struct Row: Equatable { let question: String; let status: String }
    let title: String
    let rows: [Row]
    let finishAction: URL?
    let finishFields: [URLQueryItem]
    let returnURL: URL?
    let timeLeft: TimeInterval?
}

/// view.php: description, previous attempts and the start/continue button.
struct QuizStart: Equatable {
    let title: String
    let info: [String]
    let attempts: [PortalTable]
    let action: URL?
    let fields: [URLQueryItem]
    let buttonTitle: String
}

enum QuizContent: Equatable {
    case start(QuizStart)
    case attempt(QuizAttemptPage)
    case summary(QuizSummary)
    case review(title: String, rows: [(String, String)], url: URL)
    case unknown(String)

    static func == (a: QuizContent, b: QuizContent) -> Bool {
        switch (a, b) {
        case (.start(let x), .start(let y)): return x == y
        case (.attempt(let x), .attempt(let y)): return x == y
        case (.summary(let x), .summary(let y)): return x == y
        case (.review(_, _, let x), .review(_, _, let y)): return x == y
        case (.unknown(let x), .unknown(let y)): return x == y
        default: return false
        }
    }
}

enum QuizParser {
    private static func clean(_ text: String) -> String { PortalParser.clean(text) }

    static func parse(html: String, url: URL) throws -> QuizContent {
        let doc = try SwiftSoup.parse(html, url.absoluteString)
        let heading = clean(try doc.select("#page-header h1, .page-header-headings h1").first()?.text() ?? "")
        let pageTitle = clean(try doc.title()).components(separatedBy: ":").first ?? "Тест"
        let title = heading.isEmpty ? pageTitle : heading
        if let form = try doc.select("form#responseform").first() { return .attempt(try attempt(form, doc: doc, html: html, url: url, title: title)) }
        if try !doc.select("table.quizsummaryofattempt, form input[name=finishattempt]").isEmpty() {
            return .summary(try summary(doc, html: html, url: url, title: title))
        }
        if let table = try doc.select("table.quizreviewsummary").first() {
            let rows = try table.select("tr").array().compactMap { row -> (String, String)? in
                let key = clean(try row.select("th").text()), value = clean(try row.select("td").text())
                return key.isEmpty || value.isEmpty ? nil : (key, value)
            }
            return .review(title: title, rows: rows, url: url)
        }
        if let form = try doc.select("form[action*=startattempt.php]").first() {
            let document = try? PortalParser.document(html: html, source: url)
            let info = try doc.select("#region-main .quizinfo p, #region-main .box.quizinfo p, #region-main #intro p").array()
                .map { clean(try $0.text()) }.filter { !$0.isEmpty }
            let buttonText = clean(try form.select("button").first()?.text() ?? "")
            let inputText = try form.select("input[type=submit]").first()?.attr("value") ?? ""
            return .start(QuizStart(title: title, info: info, attempts: document?.tables ?? [],
                                    action: URL(string: try form.attr("action"), relativeTo: url)?.absoluteURL,
                                    fields: try hiddenFields(form),
                                    buttonTitle: !buttonText.isEmpty ? buttonText : (inputText.isEmpty ? "Начать тестирование" : inputText)))
        }
        let notice = PortalParser.notices(html: html, source: url)?.text
            ?? (try? PortalParser.document(html: html, source: url))?.paragraphs.first
        return .unknown(notice ?? "Страница теста не распознана.")
    }

    private static func hiddenFields(_ form: Element) throws -> [URLQueryItem] {
        try form.select("input[type=hidden][name]").array().map { URLQueryItem(name: try $0.attr("name"), value: try $0.attr("value")) }
    }

    private static func timer(_ html: String) -> TimeInterval? {
        guard let match = html.firstMatch(of: #/M\.mod_quiz\.timer\.init\(Y,\s*(\d+)/#), let seconds = Double(match.1), seconds > 0 else { return nil }
        return seconds
    }

    static func attempt(_ form: Element, doc: Document, html: String, url: URL, title: String) throws -> QuizAttemptPage {
        guard let action = URL(string: try form.attr("action"), relativeTo: url)?.absoluteURL,
              PortalConfiguration.allowsDataURL(action), action.path.hasSuffix("processattempt.php") else {
            throw PortalFailure.unrecognized("форма теста")
        }
        var entries: [QuizAttemptPage.Entry] = []
        var initiallyChecked: Set<String> = []
        var next: (String, String)?, previous: (String, String)?
        for element in try form.select("input[name], select[name], textarea[name]").array() {
            let name = try element.attr("name")
            switch element.tagName() {
            case "select":
                let selected = try element.select("option[selected]").first()?.attr("value") ?? ""
                entries.append(.input(name: name, value: selected))
            case "textarea":
                entries.append(.input(name: name, value: try element.text()))
            default:
                switch try element.attr("type").lowercased() {
                case "hidden": entries.append(.hidden(name: name, value: try element.attr("value")))
                case "radio", "checkbox":
                    let id = try element.attr("id").ifEmptyThen("\(name)=\(try element.attr("value"))")
                    if element.hasAttr("checked") { initiallyChecked.insert(id) }
                    entries.append(.choice(id: id, name: name, value: try element.attr("value")))
                case "submit":
                    if name == "next" { next = (name, try element.attr("value")) }
                    if name == "previous" { previous = (name, try element.attr("value")) }
                case "image", "button", "file": continue
                default: entries.append(.input(name: name, value: try element.attr("value")))
                }
            }
        }
        let questions = try form.select(".que").array().map { try question($0, url: url) }
        guard !questions.isEmpty else { throw PortalFailure.unrecognized("вопросы теста") }
        let page = Int(entries.compactMap { entry -> String? in
            if case .hidden("thispage", let value) = entry { return value } else { return nil }
        }.first ?? "0") ?? 0
        var result = QuizAttemptPage(title: title, url: url, action: action, entries: entries, questions: questions,
                                     next: next, previous: previous, timeLeft: timer(html), pageNumber: page)
        result.initialChecked = initiallyChecked
        return result
    }

    private static func question(_ que: Element, url: URL) throws -> QuizQuestion {
        let classes = try que.className().split(separator: " ").map(String.init)
        let type = classes.dropFirst().first ?? ""
        let qtext = try que.select(".qtext").first()
        let text = PortalParser.plainText(fromHTML: try qtext?.html() ?? "")
        let images = try qtext?.select("img[src]").array().compactMap {
            URL(string: try $0.attr("src"), relativeTo: url)?.absoluteURL
        }.filter(PortalConfiguration.allowsDataURL) ?? []
        func label(for input: Element) throws -> String {
            let id = try input.attr("id")
            if !id.isEmpty, let label = try que.select("label[for=\"\(id)\"]").first() { return clean(try label.text()) }
            return clean(try input.parent()?.text() ?? "")
        }
        let radios = try que.select("input[type=radio]").array()
        let boxes = try que.select("input[type=checkbox]").array()
        let texts = try que.select(".ablock input[type=text], .answer input[type=text]").array()
        let areas = try que.select("textarea[name]").array()
        let selects = try que.select("select[name]").array()
        let answer: QuizAnswer
        let hasFileUpload = try !que.select("input[type=file]").isEmpty()
        if ["ddimageortext", "ddmarker", "ddwtos", "ordering"].contains(type) || hasFileUpload {
            answer = .unsupported(type)
        } else if !radios.isEmpty {
            let options = try radios.map { QuizOption(id: try $0.attr("id").ifEmptyThen("\(try $0.attr("name"))=\(try $0.attr("value"))"),
                                                      name: try $0.attr("name"), value: try $0.attr("value"), label: try label(for: $0)) }
                .filter { $0.value != "-1" && !$0.label.isEmpty }          // «Очистить мой выбор» is not an answer
            answer = .single(name: options.first?.name ?? "", options: options)
        } else if !boxes.isEmpty {
            answer = .multiple(options: try boxes.map { QuizOption(id: try $0.attr("id"), name: try $0.attr("name"),
                                                                    value: try $0.attr("value"), label: try label(for: $0)) })
        } else if let area = areas.first {
            answer = .text(name: try area.attr("name"), multiline: true)
        } else if let field = texts.first {
            answer = .text(name: try field.attr("name"), multiline: false)
        } else if !selects.isEmpty {
            answer = .selects(try selects.map { select in
                let row = PortalParser.ancestor(of: select, where: { $0.tagName() == "tr" })
                let prompt = clean(try row?.select("td.text, .text").first()?.text() ?? "")
                return QuizSelect(name: try select.attr("name"), prompt: prompt,
                                  options: try select.select("option").array().map { PortalForm.Option(value: try $0.attr("value"), title: clean(try $0.text())) })
            })
        } else {
            answer = .unsupported(type)
        }
        return QuizQuestion(id: try que.attr("id"), number: clean(try que.select(".qno").text()),
                            state: clean(try que.select(".state").text()), grade: clean(try que.select(".grade").text()),
                            prompt: clean(try que.select(".prompt").text()), text: text, images: images, answer: answer)
    }

    private static func summary(_ doc: Document, html: String, url: URL, title: String) throws -> QuizSummary {
        let rows = try doc.select("table.quizsummaryofattempt tbody tr").array().compactMap { row -> QuizSummary.Row? in
            let cells = try row.select("td, th").array().map { clean(try $0.text()) }
            return cells.count >= 2 ? QuizSummary.Row(question: cells[0], status: cells[1]) : nil
        }
        let finish = try doc.select("form").array().first { try !$0.select("input[name=finishattempt]").isEmpty() }
        let action = try finish.flatMap { URL(string: try $0.attr("action"), relativeTo: url)?.absoluteURL }
        // «Вернуться к попытке» is a GET form whose hidden fields (attempt, cmid) belong in the URL.
        let back = try doc.select("form[action*=attempt.php], a[href*=attempt.php]").array().compactMap { element -> URL? in
            if element.tagName() == "form" {
                guard let base = URL(string: try element.attr("action"), relativeTo: url)?.absoluteURL,
                      var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
                components.queryItems = (components.queryItems ?? []) + (try hiddenFields(element))
                return components.url
            }
            return URL(string: try element.attr("href"), relativeTo: url)?.absoluteURL
        }.first { $0.path.hasSuffix("/attempt.php") && PortalConfiguration.allowsDataURL($0) }
        return QuizSummary(title: title, rows: rows, finishAction: action,
                           finishFields: try finish.map(hiddenFields) ?? [], returnURL: back, timeLeft: timer(html))
    }
}

private extension String {
    func ifEmptyThen(_ fallback: @autoclosure () throws -> String) rethrows -> String { isEmpty ? try fallback() : self }
}
