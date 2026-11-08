import Foundation
import SwiftSoup

/// Parsers added in 1.1. Only news_items is confirmed by a saved page (version2.html);
/// course pages and the calendar follow standard Moodle markup; CDO pages
/// (attestation, debts, study plan) use the generic `document` reader because their
/// exact markup has not been supplied. Every parser throws instead of returning an
/// empty result it cannot justify, so the cache keeps the last good data.
extension PortalParser {

    // MARK: Session keep-alive

    /// M.cfg.sesskey printed into every Moodle page.
    static func sesskey(in html: String) -> String? {
        guard let match = html.firstMatch(of: #/"sesskey"\s*:\s*"([A-Za-z0-9]{6,64})"/#) else { return nil }
        return String(match.1)
    }

    /// Parses the service.php batch answer. Any error (expired session, invalid sesskey)
    /// means the session can no longer be touched and must be re-checked with a page load.
    static func sessionTouchResult(_ data: Data) throws -> TimeInterval? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { throw PortalFailure.invalidResponse }
        if let object = json as? [String: Any], object["error"] != nil {
            SessionJournal.add("core_session_touch отклонён: \(errorCode(object).isEmpty ? "без кода" : errorCode(object))")
            throw PortalFailure.loginRequired
        }
        guard let results = json as? [[String: Any]], !results.isEmpty else { throw PortalFailure.invalidResponse }
        for result in results where (result["error"] as? Bool) == true {
            SessionJournal.add("core_session_touch отклонён: \(errorCode(result).isEmpty ? "без кода" : errorCode(result))")
            throw PortalFailure.loginRequired
        }
        if results.count > 1, let info = results[1]["data"] as? [String: Any],
           let seconds = (info["timeremaining"] as? NSNumber)?.doubleValue, seconds > 0 {
            return seconds
        }
        return nil
    }

    /// Moodle user ID from the user-menu profile link (same source as authenticatedProfile).
    static func moodleUserID(in html: String) -> Int? {
        guard let menu = html.range(of: "usermenu") else { return nil }
        let tail = html[menu.upperBound...].prefix(20_000)
        guard let match = tail.firstMatch(of: #/user/profile\.php\?id=(\d+)/#), let id = Int(match.1), id > 0 else { return nil }
        return id
    }

    /// The single result of a service.php call. Session problems become loginRequired so the
    /// caller can re-check the session; other errors keep Moodle's own message.
    static func ajaxResult(_ data: Data) throws -> Any {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw PortalFailure.invalidResponse
        }
        func failure(_ object: [String: Any]) -> PortalFailure {
            let exception = object["exception"] as? [String: Any]
            let code = errorCode(object)
            let message = (exception?["message"] as? String) ?? (object["error"] as? String) ?? (object["message"] as? String) ?? code
            if ["servicerequireslogin", "invalidsesskey", "requireloginerror", "sitepolicynotagreed"].contains(code) {
                SessionJournal.add("AJAX отклонён: \(code)")
                return .loginRequired
            }
            return .unrecognized(message.isEmpty ? "ответ ЭИОС" : message)
        }
        if let object = json as? [String: Any], object["error"] != nil { throw failure(object) }
        guard let results = json as? [[String: Any]], let first = results.first else { throw PortalFailure.invalidResponse }
        if (first["error"] as? Bool) == true { throw failure(first) }
        return first["data"] ?? NSNull()
    }

    /// Moodle's error code from a service.php error object (top level or inside «exception»).
    static func errorCode(_ object: [String: Any]) -> String {
        let exception = object["exception"] as? [String: Any]
        return (object["errorcode"] as? String) ?? (exception?["errorcode"] as? String) ?? ""
    }

    /// Message bodies arrive as HTML; keep paragraphs and line breaks as plain text.
    static func plainText(fromHTML html: String) -> String {
        let marked = html.replacingOccurrences(of: #"<br\s*/?>|</p>|</div>|</li>"#, with: "\u{241E}",
                                               options: [.regularExpression, .caseInsensitive])
        let text = (try? SwiftSoup.parse(marked).text()) ?? marked
        return text.components(separatedBy: "\u{241E}").map(clean).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// core_calendar_get_action_events_by_timesort (the «Временная шкала» block): upcoming
    /// quizzes, assignments and other dated activities across all courses.
    static func actionEvents(_ data: Any) throws -> [DeadlineItem] {
        guard let root = data as? [String: Any], let events = root["events"] as? [[String: Any]] else {
            throw PortalFailure.unrecognized("события временной шкалы")
        }
        return events.compactMap { event -> DeadlineItem? in
            guard let id = (event["id"] as? NSNumber)?.intValue, let name = event["name"] as? String,
                  let sort = (event["timesort"] as? NSNumber)?.doubleValue else { return nil }
            let course = (event["course"] as? [String: Any])?["fullname"] as? String ?? ""
            let module = event["modulename"] as? String ?? ""
            let url = (event["url"] as? String).flatMap(URL.init(string:)).flatMap { PortalConfiguration.allowsDataURL($0) ? $0 : nil }
            let due = Date(timeIntervalSince1970: sort)
            return DeadlineItem(id: String(id), title: clean(name), course: CourseTitle(course).subject,
                                kind: module.isEmpty ? "" : "mod_" + module,
                                whenLabel: CampusDate.formatter("d MMMM, HH:mm").string(from: due), due: due, url: url)
        }.sorted { ($0.due ?? .distantFuture, $0.id) < ($1.due ?? .distantFuture, $1.id) }
    }

    // MARK: Generic page

    static func document(html: String, source: URL) throws -> PortalDocument {
        let doc = try SwiftSoup.parse(html, source.absoluteString)
        guard let main = try doc.select("#region-main [role=main]").first()
                ?? doc.select("#region-main").first()
                ?? doc.select("[role=main]").first() else {
            throw PortalFailure.unrecognized("содержимое страницы")
        }
        try main.select("script, style, noscript, template, .sr-only, .accesshide, .skip-block, [hidden], .modal").remove()
        let pageTitle = clean(try doc.title()).components(separatedBy: ":").first ?? ""
        let title = clean(try main.select("h1, h2").first()?.text() ?? "").ifEmpty(pageTitle)

        var tables: [PortalTable] = []
        for table in try main.select("table").array() {
            if ancestor(of: table, where: { $0.tagName() == "table" }) != nil { continue } // nested tables belong to their parent
            if let parsed = try readTable(table, in: doc) { tables.append(parsed) }
        }

        var paragraphs: [String] = []
        var seenText: Set<String> = []
        for element in try main.select("h3, h4, h5, p, li, dt, dd, .alert, .box, .generalbox").array() {
            if ancestor(of: element, where: { $0.tagName() == "table" }) != nil { continue }
            // Keep only leaf-ish blocks so a container does not repeat its children.
            // SwiftSoup's select() includes the element itself, so compare identities.
            if element.tagName() != "li", try element.select("p, li, table").array().contains(where: { $0 !== element }) { continue }
            let text = clean(try element.text())
            guard text.count > 1, text.count < 2_000, seenText.insert(text).inserted else { continue }
            paragraphs.append(text)
            if paragraphs.count >= 200 { break }
        }

        var links: [PortalLink] = []
        var seenLinks: Set<String> = []
        for link in try main.select("a[href]").array() {
            if ancestor(of: link, where: { $0.tagName() == "table" }) != nil { continue }
            guard let url = URL(string: try link.attr("href"), relativeTo: source)?.absoluteURL,
                  PortalConfiguration.allowsDataURL(url),
                  !url.absoluteString.contains("sesskey"), !url.path.contains("/login/"),
                  url.fragment == nil || url.path != source.path else { continue }
            let text = clean(try link.text())
            guard !text.isEmpty, seenLinks.insert(url.absoluteString).inserted else { continue }
            links.append(PortalLink(title: text, url: url))
            if links.count >= 100 { break }
        }

        // Some CDO pages print a bare sentence («Текущая успеваемость не найдена!») with no
        // paragraph or table around it: keep that text rather than calling the page unknown.
        if tables.isEmpty && paragraphs.isEmpty {
            let text = clean(try main.text())
            if !text.isEmpty && text.count < 600 && text != title {
                paragraphs = [text]
            }
        }
        guard !tables.isEmpty || !paragraphs.isEmpty else {
            throw PortalFailure.unrecognized("содержимое страницы «\(title)»")
        }
        return PortalDocument(title: title, tables: tables, paragraphs: tables.isEmpty ? paragraphs : Array(paragraphs.prefix(30)), links: links)
    }

    private static func readTable(_ table: Element, in doc: Document) throws -> PortalTable? {
        let rows = try table.select("tr").array().filter { ancestor(of: $0, where: { $0.tagName() == "table" }) === table }
        var headers: [String] = []
        var body: [[String]] = []
        for row in rows {
            let cells = row.children().array().filter { ["td", "th"].contains($0.tagName()) }
            guard !cells.isEmpty else { continue }
            var texts: [String] = []
            for cell in cells {
                let text = try cellText(cell)
                let span = min(max(Int(try cell.attr("colspan")) ?? 1, 1), 12)
                texts.append(text)
                if span > 1 { texts.append(contentsOf: Array(repeating: "", count: span - 1)) }
            }
            if texts.allSatisfy({ $0.isEmpty }) { continue }
            let isHeader = cells.allSatisfy { $0.tagName() == "th" } || row.parent()?.tagName() == "thead"
            if isHeader && body.isEmpty { headers = texts } else { body.append(texts) }
        }
        guard !body.isEmpty else { return nil }
        var caption = clean(try table.select("caption").first()?.text() ?? "")
        if caption.isEmpty, let pane = ancestor(of: table, where: { $0.hasClass("tab-pane") }) {
            let id = try pane.attr("id")
            if !id.isEmpty { caption = clean(try doc.select("a[href=\"#\(id)\"]").first()?.text() ?? "") }
        }
        if caption.isEmpty, let previous = try table.previousElementSibling(), ["h2", "h3", "h4", "h5"].contains(previous.tagName()) {
            caption = clean(try previous.text())
        }
        return PortalTable(caption: caption, headers: headers, rows: body)
    }

    static func ancestor(of element: Element, where match: (Element) -> Bool) -> Element? {
        var current = element.parent()
        while let node = current {
            if match(node) { return node }
            current = node.parent()
        }
        return nil
    }

    private static func cellText(_ cell: Element) throws -> String {
        let separator = "\u{241E}"
        let html = try cell.html().replacingOccurrences(of: "<br\\s*/?>", with: separator,
                                                        options: [.regularExpression, .caseInsensitive])
        return try html.components(separatedBy: separator)
            .map { clean(try SwiftSoup.parse($0).text()) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: Dashboard news (block_news_items, confirmed in version2.html)

    static func news(html: String, source: URL) throws -> [NewsItem] {
        let doc = try SwiftSoup.parse(html, source.absoluteString)
        guard let block = try doc.select("[data-block=news_items]").first() else {
            throw PortalFailure.unrecognized("блок объявлений")
        }
        var items: [NewsItem] = []
        for post in try block.select(".post").array() {
            guard let link = try post.select(".info a[href]").first(),
                  let url = URL(string: try link.attr("href"), relativeTo: source)?.absoluteURL,
                  PortalConfiguration.allowsDataURL(url) else { continue }
            let title = clean(try link.text())
            guard !title.isEmpty else { continue }
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "d" }?.value
                ?? StableID.make([url.absoluteString])
            items.append(NewsItem(id: id, title: title, author: clean(try post.select(".name").text()),
                                  dateLabel: clean(try post.select(".date").text()), url: url))
        }
        // An empty block is valid only when the site renders no posts at all.
        if items.isEmpty, try !block.select(".post").isEmpty() { throw PortalFailure.unrecognized("объявления") }
        return items
    }

    // MARK: Course page (standard Moodle: li.section > li.activity.modtype_*)

    static func courseContents(html: String, source: URL) throws -> [CourseSection] {
        let doc = try SwiftSoup.parse(html, source.absoluteString)
        let sections = try doc.select("li.section, li[data-for=section]").array()
        guard !sections.isEmpty else { throw PortalFailure.unrecognized("разделы курса") }
        var result: [CourseSection] = []
        for (index, section) in sections.enumerated() {
            let title = clean(try section.select(".sectionname, h3.section-title, [data-for=section_title]").first()?.text() ?? "")
            let summaryElement = try section.select(".summary, .summarytext").first()
            let summary = clean(try summaryElement?.text() ?? "")
            var activities: [CourseActivity] = []
            for activity in try section.select("li.activity").array() {
                let classes = try activity.className().split(separator: " ").map(String.init)
                let kind = classes.first { $0.hasPrefix("modtype_") }.map { String($0.dropFirst("modtype_".count)) } ?? ""
                let nameElement = try activity.select(".instancename, .activityname, [data-activityname]").first()
                try nameElement?.select(".accesshide").remove()
                var name = clean(try nameElement?.text() ?? "")
                if name.isEmpty, kind == "label" { name = clean(try activity.text()) }
                guard !name.isEmpty else { continue }
                let href = try activity.select("a.aalink[href], a[href*='/mod/']").first()?.attr("href") ?? ""
                let url = URL(string: href, relativeTo: source).map(\.absoluteURL).flatMap { PortalConfiguration.allowsDataURL($0) ? $0 : nil }
                let info = clean(try activity.select(".activity-dates, [data-region=activity-dates], .availabilityinfo, .contentafterlink .text-muted").text())
                let id = try activity.attr("id").ifEmpty(StableID.make([String(index), name, href]))
                activities.append(CourseActivity(id: id, name: kind == "label" ? String(name.prefix(300)) : name,
                                                 kind: kind, info: info, url: url))
            }
            if title.isEmpty && activities.isEmpty && summary.isEmpty { continue }
            let id = try section.attr("id").ifEmpty("section-\(index)")
            result.append(CourseSection(id: id, title: title.ifEmpty(index == 0 ? "Общее" : "Раздел \(index)"),
                                        summary: String(summary.prefix(600)), activities: activities))
        }
        guard !result.isEmpty else { throw PortalFailure.unrecognized("содержимое курса") }
        return result
    }

    // MARK: Upcoming events (calendar/view.php?view=upcoming)

    static func deadlines(html: String, source: URL) throws -> [DeadlineItem] {
        let doc = try SwiftSoup.parse(html, source.absoluteString)
        guard let main = try doc.select("#region-main").first() else { throw PortalFailure.unrecognized("календарь") }
        let events = try main.select("[data-type=event][data-event-id], .event[data-event-id]").array()
        if events.isEmpty {
            // Moodle prints this sentence when the list is genuinely empty.
            let text = normalized(try main.text())
            if text.contains("нет предстоящих") || text.contains("no upcoming") { return [] }
            throw PortalFailure.unrecognized("список событий календаря")
        }
        var items: [DeadlineItem] = []
        var seen: Set<String> = []
        for event in events {
            let id = try event.attr("data-event-id")
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            let title = clean(try event.attr("data-event-title").ifEmpty(try event.select("h3.name, .name").first()?.text() ?? ""))
            guard !title.isEmpty else { continue }
            let kind = try event.attr("data-event-component")
            let course = clean(try event.select("a[href*='/course/view.php']").first()?.text() ?? "")
            let dateRow = try event.select(".description .row, .description .col-11, .description div").first()
            let whenLabel = clean(try dateRow?.text() ?? "")
            let dayLink = try event.select("a[href*='view=day'][href*='time=']").first()?.attr("href") ?? ""
            let actionHref = try event.select(".card-footer a[href], a.card-link[href]").first()?.attr("href") ?? ""
            let url = URL(string: actionHref, relativeTo: source).map(\.absoluteURL).flatMap { PortalConfiguration.allowsDataURL($0) ? $0 : nil }
            items.append(DeadlineItem(id: id, title: title, course: course, kind: kind, whenLabel: whenLabel,
                                      due: dueDate(dayLink: dayLink, label: whenLabel), url: url))
        }
        return items.sorted { ($0.due ?? .distantFuture, $0.id) < ($1.due ?? .distantFuture, $1.id) }
    }

    /// The day link carries a Unix timestamp of that day; the label carries HH:mm.
    static func dueDate(dayLink: String, label: String) -> Date? {
        guard let raw = URLComponents(string: dayLink.replacingOccurrences(of: "&amp;", with: "&"))?
                .queryItems?.first(where: { $0.name == "time" })?.value,
              let seconds = TimeInterval(raw), seconds > 0 else { return nil }
        let day = CampusDate.calendar.startOfDay(for: Date(timeIntervalSince1970: seconds))
        let times = label.matches(of: #/\b([01]?\d|2[0-3]):([0-5]\d)\b/#)
        guard let last = times.last, let hour = Int(last.1), let minute = Int(last.2) else { return nil }
        return CampusDate.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
}

private extension String {
    func ifEmpty(_ fallback: @autoclosure () throws -> String) rethrows -> String { isEmpty ? try fallback() : self }
}
