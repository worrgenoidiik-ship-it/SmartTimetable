import Foundation
import SwiftSoup

enum PortalParser {
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalized(_ text: String) -> String {
        clean(text).lowercased().replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
    }

    /// Markers of a page that asks to sign in, with a label for the session journal.
    static let loginMarkers: [(String, String)] = [
        ("input[name=logintoken]", "форма входа Moodle"), ("form#login", "форма входа Moodle"),
        ("form#kc-form-login", "форма входа SSO"), ("input[name=otp]", "запрос одноразового кода"),
        (".loginwait-modal, #loginwait-content", "окно подтверждения MAX")
    ]

    static func authenticatedProfile(html: String, url: URL) throws -> StudentProfile {
        guard !PortalConfiguration.isAuthenticationURL(url) else {
            SessionJournal.add("Ответ — страница входа: \(SessionJournal.place(url))")
            throw PortalFailure.loginRequired
        }
        let doc = try SwiftSoup.parse(html, url.absoluteString)
        for (selector, label) in loginMarkers where try !doc.select(selector).isEmpty() {
            SessionJournal.add("На \(SessionJournal.place(url)) вместо данных: \(label)")
            throw PortalFailure.loginRequired
        }
        let name = clean(try doc.select("span.usertext").text())
        let logout = try doc.select("a[href*='/login/logout.php']").first()
        guard !name.isEmpty, logout != nil else {
            throw PortalFailure.unrecognized("подтверждение входа")
        }
        var serverID: String?
        for link in try doc.select(".usermenu a[href*='/user/profile.php']").array() {
            let href = try link.attr("href")
            if let target = URL(string: href, relativeTo: url)?.absoluteURL,
               target.host == PortalConfiguration.baseURL.host,
               let value = URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "id" })?.value,
               let id = Int(value), id > 0 { serverID = String(id); break }
        }
        // The supplied page exposes the real Moodle profile ID. Do not use a name
        // as an account identifier: two students can share the same full name.
        guard let serverID = serverID else { throw PortalFailure.unrecognized("идентификатор пользователя") }
        let identity = "id:\(serverID)"
        return StudentProfile(accountKey: StableID.make([url.host ?? "", identity]),
                              name: name, identityUsesName: false)
    }

    static func grades(html: String, mapping: GradeTableMapping, source: URL) throws -> [GradeItem] {
        let doc = try SwiftSoup.parse(html, source.absoluteString)
        let tables = try doc.select(mapping.selector).array()
        guard tables.count == 1, let table = tables.first else {
            throw PortalFailure.unrecognized("таблица оценок")
        }
        return try gradeTable(table, mapping: mapping, source: source)
    }

    // att0/att1 identify SEMESTERS on the real page, not different assessment types.
    // Follow every semester tab and commit the whole collection only after all pass.
    static func academicProgress(html: String, source: URL) throws -> [GradeItem] {
        let doc = try SwiftSoup.parse(html, source.absoluteString)
        let tabs = try doc.select("a.academic-link[role=tab]").array()
        let panes = try doc.select("#pills-tabContent > .tab-pane").array()
        let tables = try doc.select("#pills-tabContent table.academic-table").array()
        guard !tabs.isEmpty, tabs.count == tables.count else {
            throw PortalFailure.unrecognized("вкладки семестров")
        }
        var visited: Set<String> = []
        var labels: Set<String> = []
        var result: [GradeItem] = []
        for tab in tabs {
            let href = try tab.attr("href")
            let semester = clean(try tab.text())
            guard href.hasPrefix("#"), href.count > 1, !semester.isEmpty,
                  labels.insert(semester).inserted, visited.insert(String(href.dropFirst())).inserted else {
                throw PortalFailure.unrecognized("ссылка семестра")
            }
            let paneID = String(href.dropFirst())
            guard let pane = try panes.first(where: { try $0.attr("id") == paneID }) else {
                throw PortalFailure.unrecognized("содержимое семестра \(semester)")
            }
            let semesterTables = try pane.select("table.academic-table").array()
            guard semesterTables.count == 1, let table = semesterTables.first else {
                throw PortalFailure.unrecognized("таблица семестра \(semester)")
            }
            result += try gradeTable(table, mapping: PortalConfiguration.gradesTable, source: source, semesterLabel: semester)
        }
        return result
    }

    private static func gradeTable(_ table: Element, mapping: GradeTableMapping, source: URL,
                                   semesterLabel: String = "") throws -> [GradeItem] {
        let rows = try table.select("tr").array()
        let fields = [mapping.subjectHeaders, mapping.typeHeaders, mapping.gradeHeaders,
                      mapping.dateHeaders, mapping.teacherHeaders]
        var indices: [Int]?
        var headerIndex = -1
        var headerTexts: [String] = []
        var semesterIndex: Int?
        var retakeIndex: Int?
        for (index, row) in rows.enumerated() {
            let cells = directCells(row)
            let texts = try cells.map { normalized(try $0.text()) }
            let matches = fields.map { aliases in texts.firstIndex { aliases.map(normalized).contains($0) } }
            if matches.allSatisfy({ $0 != nil }) {
                indices = matches.compactMap { $0 }
                headerIndex = index
                headerTexts = texts
                semesterIndex = texts.firstIndex { mapping.semesterHeaders.map(normalized).contains($0) }
                retakeIndex = texts.firstIndex { mapping.retakeHeaders.map(normalized).contains($0) }
                break
            }
        }
        guard let indices = indices, Set(indices).count == fields.count else {
            throw PortalFailure.unrecognized("заголовки таблицы оценок")
        }
        var items: [GradeItem] = []
        for (offset, row) in rows.enumerated() where offset > headerIndex {
            let cells = directCells(row)
            if cells.isEmpty { continue }
            let texts = try cells.map { clean(try $0.text()) }
            if texts.map(normalized) == headerTexts { continue }
            if let empty = mapping.emptySelector, try !row.select(empty).isEmpty() { continue }
            let spans = try cells.map { try $0.attr("colspan") }
            guard cells.count == headerTexts.count,
                  spans.allSatisfy({ $0.isEmpty || $0 == "1" }),
                  !texts[indices[0]].isEmpty else {
                throw PortalFailure.unrecognized("строка таблицы оценок")
            }
            let subject = texts[indices[0]], type = texts[indices[1]], grade = texts[indices[2]]
            let date = texts[indices[3]]
            let teacher = try teacherText(cells[indices[4]])
            let semester = semesterLabel.isEmpty ? (semesterIndex.map { texts[$0] } ?? "") : semesterLabel
            let retake = retakeIndex.map { texts[$0] }
            let id = StableID.make([source.absoluteString, subject, type, date, semester, teacher, String(offset)])
            items.append(GradeItem(id: id, subject: subject, type: type, grade: grade,
                                   date: date, teacher: teacher, semester: semester, retake: retake))
        }
        if items.isEmpty {
            guard let selector = mapping.emptySelector, try !table.select(selector).isEmpty() else {
                throw PortalFailure.unrecognized("пустая таблица без подтверждения отсутствия данных")
            }
        }
        return items
    }

    private static func teacherText(_ cell: Element) throws -> String {
        // The real portal separates full names with <br>, including a trailing <br>.
        let separator = "\u{241E}"
        let html = try cell.html().replacingOccurrences(of: "<br\\s*/?>", with: separator,
                                                        options: [.regularExpression, .caseInsensitive])
        let names = try html.components(separatedBy: separator).map { fragment in
            clean(try SwiftSoup.parse(fragment).text())
        }.filter { !$0.isEmpty }
        return names.joined(separator: "\n")
    }

    static func courses(html: String, source: URL) throws -> [Course] {
        let doc = try SwiftSoup.parse(html, source.absoluteString)
        let cards = try doc.select("[data-region=course-content][data-course-id]").array()
        var courses: [Course] = []
        var seen: Set<String> = []
        if !cards.isEmpty {
            for card in cards {
                let rawID = try card.attr("data-course-id")
                guard let id = Int(rawID), id > 0,
                      let link = try card.select("a.coursename[href]").first(),
                      let url = courseURL(try link.attr("href"), source: source),
                      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == String(id) else {
                    throw PortalFailure.unrecognized("карточка курса")
                }
                var title = clean(try link.select(".multiline").text())
                // The supplied card truncates .multiline with literal dots. Its
                // dropdown's accessible label preserves the actual full name.
                let prefix = "Действия для текущего курса "
                for label in try card.select("button .sr-only").array() {
                    let value = clean(try label.text())
                    if value.hasPrefix(prefix) {
                        title = clean(String(value.dropFirst(prefix.count)))
                        break
                    }
                }
                guard !title.isEmpty else { throw PortalFailure.unrecognized("название курса") }
                if seen.insert(String(id)).inserted {
                    courses.append(Course(id: String(id), title: title, teacher: "", url: url))
                }
            }
        } else {
            // Older server-rendered pages use plain links in the main region.
            for link in try doc.select("#region-main a[href]").array() {
                guard let url = courseURL(try link.attr("href"), source: source),
                      let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else { continue }
                let title = clean(try link.text())
                guard !title.isEmpty, title != "Изображение курса", seen.insert(id).inserted else { continue }
                courses.append(Course(id: id, title: title, teacher: "", url: url))
            }
        }
        guard !courses.isEmpty else { throw PortalFailure.unrecognized("список курсов") }
        return courses
    }

    private static func courseURL(_ href: String, source: URL) -> URL? {
        guard let url = URL(string: href, relativeTo: source)?.absoluteURL,
              PortalConfiguration.allowsDataURL(url), url.path == "/course/view.php",
              let rawID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              let id = Int(rawID), id > 0 else { return nil }
        var canonical = URLComponents(url: PortalConfiguration.baseURL, resolvingAgainstBaseURL: false)!
        canonical.path = "/course/view.php"
        canonical.queryItems = [URLQueryItem(name: "id", value: String(id))]
        return canonical.url
    }

    static func notifications(html: String, source: URL) throws -> [PortalNotification] {
        let doc = try SwiftSoup.parse(html, source.absoluteString)
        guard PortalConfiguration.allowsDataURL(source),
              source.path == PortalConfiguration.notificationsURL.path,
              let area = try doc.select("[data-region=notification-area]").first() else {
            throw PortalFailure.unrecognized("область уведомлений")
        }
        let rows = try area.select("[data-region=notification-content-item-container]").array()
        // The supplied DOM includes 'Уведомлений нет' even when it has 16 entries.
        // That label alone never authorizes erasing the saved inbox.
        guard !rows.isEmpty else { throw PortalFailure.unrecognized("загруженный список уведомлений") }
        var items: [PortalNotification] = []
        var seen: Set<String> = []
        for row in rows {
            let id = try row.attr("data-id")
            let message = clean(try row.select(".notification-message").text())
            let timestamp = clean(try row.select(".timestamp").text())
            guard let number = Int(id), number > 0, !message.isEmpty, !timestamp.isEmpty,
                  seen.insert(id).inserted else { throw PortalFailure.unrecognized("строка уведомления") }
            let unread = (try row.attr("class")).split(separator: " ").contains("unread")
            items.append(PortalNotification(id: id, message: message, sourceTimeLabel: timestamp, isUnread: unread))
        }
        return items
    }

    static func mergingObservedNotifications(_ observed: [PortalNotification], into cached: [PortalNotification]) -> [PortalNotification] {
        let ids = Set(observed.map(\.id))
        return observed + cached.filter { !ids.contains($0.id) }
    }

    static func mergingObservedCourses(_ observed: [Course], into cached: [Course], seenAt: Date? = nil) -> [Course] {
        var result = cached
        for var course in observed {
            if let seenAt = seenAt { course.lastSeen = seenAt }
            if let index = result.firstIndex(where: { $0.id == course.id }) { result[index] = course }
            else { result.append(course) }
        }
        return result
    }

    static func preservingScheduleHistory(_ observed: ScheduleWindow, previous: ScheduleWindow?) -> ScheduleWindow {
        guard let previous = previous, previous.origin != .manual else { return observed }
        let replaced = Set(observed.days)
        let days = Set(previous.days).union(replaced).sorted()
        let items = (previous.items.filter { !replaced.contains($0.day) } + observed.items)
            .sorted { ($0.day, $0.timeStart, $0.id) < ($1.day, $1.timeStart, $1.id) }
        return ScheduleWindow(days: days, items: items, origin: .portal)
    }

    /// Parses the JSON envelope returned by blocks/schedule/ajax_schedule.php.
    /// NetworkManager verifies the account before requesting this fragment.
    static func parseAjaxSchedule(jsonString: String, source: URL) throws -> [String: [ScheduleItem]] {
        struct Response: Decodable { let html: String }
        guard jsonString.utf8.count < 8_000_000 else { throw PortalFailure.invalidResponse }
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: Data(jsonString.utf8)) }
        catch { throw PortalFailure.invalidResponse }
        guard !clean(response.html).isEmpty else { throw PortalFailure.incompleteSchedule }

        let doc = try SwiftSoup.parse(response.html, source.absoluteString)
        if try !doc.select("form#login, form#kc-form-login, input[name=logintoken], input[name=otp], .loginwait-modal").isEmpty() {
            throw PortalFailure.loginRequired
        }
        // Do not filter by .active or visibility: version2.html switches entire
        // [data-schedule-week-panel] containers with .d-none, including week two.
        let panes = try doc.select(".tab-content .tab-pane").array()
        guard !panes.isEmpty else { throw PortalFailure.incompleteSchedule }
        let formatter = CampusDate.formatter("yyyyMMdd")
        var days: [String: [ScheduleItem]] = [:]

        for pane in panes {
            let identifier = try pane.attr("id")
            guard identifier.range(of: #"^day[0-9]{8}$"#, options: .regularExpression) != nil else {
                throw PortalFailure.unrecognized("идентификатор дня расписания")
            }
            let rawDate = String(identifier.dropFirst(3))
            guard let date = formatter.date(from: rawDate), formatter.string(from: date) == rawDate else {
                throw PortalFailure.unrecognized("дата расписания")
            }
            let day = CampusDate.key(date)
            guard days[day] == nil else { throw PortalFailure.unrecognized("повторяющийся день расписания") }
            let tables = try pane.select("table.schedule-table").array()
            guard tables.count == 1, let table = tables.first else { throw PortalFailure.incompleteSchedule }
            let bodies = try table.select("tbody").array()
            guard bodies.count == 1, let body = bodies.first else { throw PortalFailure.incompleteSchedule }
            let rows = try pane.select("table.schedule-table tbody tr").array()
            // A dated table with an empty body represents that returned day with no rows.
            // A missing table or an unknown message is not evidence of an empty day.
            if rows.isEmpty, !clean(try body.text()).isEmpty { throw PortalFailure.incompleteSchedule }

            var items: [ScheduleItem] = []
            var occurrences: [String: Int] = [:]
            for row in rows {
                let time = try ajaxScheduleField(".schedule-table_time", in: row)
                    .replacingOccurrences(of: #"[–—−]"#, with: "-", options: .regularExpression)
                let bounds = time.components(separatedBy: "-").map(clean)
                guard bounds.count == 2, validTime(bounds[0]), validTime(bounds[1]), bounds[0] < bounds[1] else {
                    throw PortalFailure.unrecognized("время занятия в расписании")
                }
                let start = bounds[0], end = bounds[1]
                let subject = try ajaxScheduleField(".schedule-table_exam", in: row)
                guard !subject.isEmpty else { throw PortalFailure.unrecognized("название занятия") }
                let type = try ajaxScheduleField(".schedule-table_type", in: row)
                let teacher = try ajaxScheduleField(".schedule-table_category", in: row, multiline: true)
                // "adress" with one d is the actual class in the portal response.
                let place = try ajaxScheduleField(".schedule-table_adress", in: row)
                let subgroup = ""
                let fingerprint = StableID.make([day, start, end, subject, type, teacher, place, subgroup])
                let occurrence = occurrences[fingerprint, default: 0]
                occurrences[fingerprint] = occurrence + 1
                // Row order may vary between refreshes; identical rows remain distinct.
                let id = StableID.make(["ajax-schedule", fingerprint, String(occurrence)])
                items.append(ScheduleItem(id: id, day: day, timeStart: start, timeEnd: end,
                                          type: type, subject: subject, teacher: teacher,
                                          place: place, subgroup: subgroup))
            }
            days[day] = items.sorted { ($0.timeStart, $0.id) < ($1.timeStart, $1.id) }
        }
        return days
    }

    private static func ajaxScheduleField(_ selector: String, in row: Element, multiline: Bool = false) throws -> String {
        let matches = try row.select(selector).array()
        guard matches.count == 1, let element = matches.first else {
            throw PortalFailure.unrecognized("поле занятия \(selector)")
        }
        if multiline { return try teacherText(element) }
        return clean(try element.text())
    }

    /// Builds a snapshot from exactly the returned dates, without padding missing days.
    /// The array allows combining already-parsed data; it never generates week requests.
    static func mergeSchedule(_ pages: [[String: [ScheduleItem]]]) throws -> ScheduleWindow {
        guard !pages.isEmpty else { throw PortalFailure.incompleteSchedule }
        let formatter = CampusDate.formatter("yyyy-MM-dd")
        var all: [String: [ScheduleItem]] = [:]
        for page in pages {
            guard !page.isEmpty else { throw PortalFailure.incompleteSchedule }
            for (day, lessons) in page {
                guard let date = formatter.date(from: day), formatter.string(from: date) == day,
                      lessons.allSatisfy({ $0.day == day }),
                      Set(lessons.map(\.id)).count == lessons.count else {
                    throw PortalFailure.incompleteSchedule
                }
                let sorted = lessons.sorted { ($0.timeStart, $0.id) < ($1.timeStart, $1.id) }
                if let existing = all[day], existing != sorted { throw PortalFailure.incompleteSchedule }
                all[day] = sorted
            }
        }
        let dates = all.keys.sorted()
        return ScheduleWindow(days: dates, items: dates.flatMap { all[$0] ?? [] })
    }

    private static func directCells(_ row: Element) -> [Element] {
        row.children().array().filter { ["td", "th"].contains($0.tagName()) }
    }

    private static func validTime(_ text: String) -> Bool {
        text.range(of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil
    }
}
