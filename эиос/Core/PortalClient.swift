import Foundation

struct PortalPage: Sendable {
    let html: String
    let url: URL
    let profile: StudentProfile
}

private final class ReadRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Background reads do not follow redirects to identity providers or unknown hosts.
        completionHandler(request.url.map(PortalConfiguration.allowsDataURL) == true ? request : nil)
    }
}

actor PortalClient {
    private let session: URLSession
    /// Moodle CSRF token of the current session, taken from the last verified page.
    private var sesskey: String?
    /// Last moment the server confirmed this session (any page or a touch).
    private(set) var lastContact: Date?
    /// Numeric Moodle ID of the signed-in user (from the user menu); needed by messaging calls.
    private(set) var userID: Int?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: ReadRedirectPolicy(), delegateQueue: nil)
    }

    func page(at url: URL, expectedAccount: String? = nil) async throws -> PortalPage {
        guard PortalConfiguration.allowsDataURL(url) else { throw PortalFailure.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await read(request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, let finalURL = response.url else { throw PortalFailure.invalidResponse }
        if response.statusCode == 401 {
            SessionJournal.add("HTTP 401 на \(SessionJournal.place(finalURL))")
            throw PortalFailure.loginRequired
        }
        if (300..<400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"),
           let redirect = URL(string: location, relativeTo: finalURL)?.absoluteURL,
           PortalConfiguration.isAuthenticationURL(redirect) {
            SessionJournal.add("ЭИОС перенаправила \(SessionJournal.place(url)) на вход: \(SessionJournal.place(redirect))")
            throw PortalFailure.loginRequired
        }
        guard (200..<300).contains(response.statusCode) else { throw PortalFailure.httpStatus(response.statusCode) }
        guard PortalConfiguration.allowsDataURL(finalURL), data.count < 8_000_000,
              ["text/html", "application/xhtml+xml"].contains(response.mimeType ?? "") else { throw PortalFailure.invalidResponse }
        let encoding: String.Encoding = response.textEncodingName?.lowercased() == "windows-1251" ? .windowsCP1251 : .utf8
        guard let html = String(data: data, encoding: encoding) else { throw PortalFailure.invalidResponse }
        guard html.range(of: "</html>", options: .caseInsensitive) != nil,
              html.range(of: "</body>", options: .caseInsensitive) != nil else { throw PortalFailure.invalidResponse }
        let profile = try PortalParser.authenticatedProfile(html: html, url: finalURL)
        if let expected = expectedAccount, profile.accountKey != expected {
            SessionJournal.add("На \(SessionJournal.place(finalURL)) открыт другой аккаунт")
            throw PortalFailure.loginRequired
        }
        // Checkpoint rotation before parsing optional sections or starting another
        // request. A later timeout must not lose a verified session cookie.
        try await SessionStore.shared.checkpointValidatedHTTP()
        sesskey = PortalParser.sesskey(in: html) ?? sesskey
        userID = PortalParser.moodleUserID(in: html) ?? userID
        lastContact = Date()
        return PortalPage(html: html, url: finalURL, profile: profile)
    }

    func grades(at url: URL, mapping: GradeTableMapping, account: String) async throws -> [GradeItem] {
        let page = try await page(at: url, expectedAccount: account)
        return try PortalParser.grades(html: page.html, mapping: mapping, source: page.url)
    }

    func academicProgress(from page: PortalPage) throws -> [GradeItem] {
        try PortalParser.academicProgress(html: page.html, source: page.url)
    }

    func courses(account: String) async throws -> [Course] {
        let page = try await page(at: PortalConfiguration.coursesURL, expectedAccount: account)
        return try PortalParser.courses(html: page.html, source: page.url)
    }

    /// /my/ carries both the course cards and the news block; one GET serves both.
    func dashboard(account: String) async throws -> PortalPage {
        try await page(at: PortalConfiguration.coursesURL, expectedAccount: account)
    }

    func document(_ kind: PortalPageKind, account: String) async throws -> PortalDocument {
        let page = try await page(at: kind.url, expectedAccount: account)
        return try PortalParser.document(html: page.html, source: page.url)
    }

    func courseContents(_ course: Course, account: String) async throws -> [CourseSection] {
        let page = try await page(at: course.url, expectedAccount: account)
        return try PortalParser.courseContents(html: page.html, source: page.url)
    }

    func deadlines(account: String) async throws -> [DeadlineItem] {
        let page = try await page(at: PortalConfiguration.calendarURL, expectedAccount: account)
        return try PortalParser.deadlines(html: page.html, source: page.url)
    }

    func questionForm(account: String) async throws -> QuestionForm {
        let page = try await page(at: PortalConfiguration.questionURL, expectedAccount: account)
        return try PortalParser.questionForm(html: page.html, source: page.url)
    }

    /// GET step of a portal form (e.g. choosing the kind of certificate): a read, like page(at:).
    func openForm(_ form: PortalForm, values: [String: String], account: String) async throws -> PortalPage {
        var components = URLComponents(url: form.action, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + form.payload(values)
        guard let url = components.url else { throw PortalFailure.invalidURL }
        return try await page(at: url, expectedAccount: account)
    }

    /// POST of a portal form. Sent once: no retry, the caller shows the result or the error.
    func submitForm(_ form: PortalForm, values: [String: String], account: String) async throws -> PortalPage {
        guard form.isPost else { throw PortalFailure.invalidURL }
        return try await post(form.action, items: form.payload(values), account: account)
    }

    /// One urlencoded POST (forms, quiz pages). Never retried by the network layer.
    func post(_ url: URL, items: [URLQueryItem], account: String) async throws -> PortalPage {
        guard PortalConfiguration.allowsDataURL(url) else { throw PortalFailure.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncoded(items).utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else { throw PortalFailure.invalidResponse }
        if PortalConfiguration.isAuthenticationURL(finalURL) || http.statusCode == 401 { throw PortalFailure.loginRequired }
        guard (200..<400).contains(http.statusCode), let html = String(data: data, encoding: .utf8) else {
            throw PortalFailure.httpStatus(http.statusCode)
        }
        let profile = try PortalParser.authenticatedProfile(html: html, url: finalURL)
        guard profile.accountKey == account else { throw PortalFailure.loginRequired }
        lastContact = Date()
        return PortalPage(html: html, url: finalURL, profile: profile)
    }

    /// application/x-www-form-urlencoded: everything except unreserved characters is escaped,
    /// so «&», «=» and «+» inside an answer cannot break the form.
    static func formEncoded(_ items: [URLQueryItem]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return items.map { encode($0.name) + "=" + encode($0.value ?? "") }.joined(separator: "&")
    }

    /// Sends «Задать вопрос» exactly like the site's button (GET /CDO/lib.php?API=sendQ).
    /// Not routed through read(): a question must never be sent twice by a retry.
    func sendQuestion(category: String, subject: String, message: String, email: String) async throws {
        var components = URLComponents(url: PortalConfiguration.baseURL.appendingPathComponent("CDO/lib.php"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "API", value: "sendQ"), URLQueryItem(name: "subject", value: subject),
                                 URLQueryItem(name: "message", value: message), URLQueryItem(name: "reply_type", value: email),
                                 URLQueryItem(name: "message_type", value: category)]
        guard let url = components.url, PortalConfiguration.allowsDataURL(url) else { throw PortalFailure.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url,
              !PortalConfiguration.isAuthenticationURL(finalURL) else { throw PortalFailure.loginRequired }
        guard (200..<300).contains(http.statusCode) else { throw PortalFailure.httpStatus(http.statusCode) }
        // The site treats any non-empty answer as success.
        let answer = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !answer.isEmpty, answer != "0", answer.lowercased() != "false" else { throw PortalFailure.unrecognized("ответ на отправку вопроса") }
        lastContact = Date()
    }

    func notifications(account: String) async throws -> [PortalNotification] {
        let page = try await page(at: PortalConfiguration.notificationsURL, expectedAccount: account)
        return try PortalParser.notifications(html: page.html, source: page.url)
    }

    /// One GET using the restored session. The caller must verify the account and
    /// cancel on logout/browser opening before committing the result (NetworkManager does).
    func ajaxSchedule() async throws -> [String: [ScheduleItem]] {
        let url = PortalConfiguration.scheduleURL
        guard PortalConfiguration.allowsDataURL(url), url.query == nil, url.fragment == nil else {
            throw PortalFailure.invalidURL
        }
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (data, response) = try await read(request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, let finalURL = response.url else {
            throw PortalFailure.invalidResponse
        }
        if response.statusCode == 401 || PortalConfiguration.isAuthenticationURL(finalURL) {
            throw PortalFailure.loginRequired
        }
        if (300..<400).contains(response.statusCode),
           let location = response.value(forHTTPHeaderField: "Location"),
           let redirect = URL(string: location, relativeTo: finalURL)?.absoluteURL,
           PortalConfiguration.isAuthenticationURL(redirect) { throw PortalFailure.loginRequired }
        guard (200..<300).contains(response.statusCode) else { throw PortalFailure.httpStatus(response.statusCode) }
        guard PortalConfiguration.allowsDataURL(finalURL), finalURL.path == url.path,
              finalURL.query == nil, finalURL.fragment == nil else { throw PortalFailure.invalidURL }
        // Some PHP handlers return JSON with text/html or text/plain. Decode JSON
        // strictly below rather than treating that header alone as proof of HTML/login.
        let mime = response.mimeType?.lowercased() ?? ""
        let compatible = ["application/json", "text/json", "text/plain", "text/html"].contains(mime)
            || (mime.hasPrefix("application/") && mime.hasSuffix("+json"))
        guard compatible, data.count < 8_000_000, let json = String(data: data, encoding: .utf8) else {
            throw PortalFailure.invalidResponse
        }
        return try PortalParser.parseAjaxSchedule(jsonString: json, source: finalURL)
    }

    private func read(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // One retry of an idempotent GET. Never resend login, MAX or test answers.
        do { return try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            guard (request.httpMethod ?? "GET") == "GET", RefreshPolicy.isTransient(error) else { throw error }
            try await Task.sleep(nanoseconds: 750_000_000)
            try Task.checkCancellation()
            return try await session.data(for: request)
        }
    }

    /// Opens a one-time autologin URL from the mobile token. The portal answers with a new
    /// session cookie and a redirect; the caller verifies the result with a protected page.
    /// Not retried: the key works only once.
    func openAutologin(_ url: URL) async throws {
        guard PortalConfiguration.allowsDataURL(url) else { throw PortalFailure.invalidURL }
        sesskey = nil
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(MobileAPI.userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw PortalFailure.invalidResponse
        }
    }

    /// Keep-alive: Moodle's own AJAX methods that the site uses for its session-timeout warning.
    /// `core_session_touch` resets the idle timer; `core_session_time_remaining` reports the
    /// server timeout, so the app can ping just often enough. Never sends credentials.
    /// Returns the remaining seconds, or nil when the server did not report them.
    func touchSession() async throws -> TimeInterval? {
        guard let key = sesskey else { throw PortalFailure.loginRequired }
        var components = URLComponents(url: PortalConfiguration.baseURL.appendingPathComponent("lib/ajax/service.php"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sesskey", value: key),
                                 URLQueryItem(name: "info", value: "core_session_touch,core_session_time_remaining")]
        guard let url = components.url, PortalConfiguration.allowsDataURL(url) else { throw PortalFailure.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = Data(#"[{"index":0,"methodname":"core_session_touch","args":{}},{"index":1,"methodname":"core_session_time_remaining","args":{}}]"#.utf8)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try Self.checkService(response, method: "core_session_touch")
        let remaining = try PortalParser.sessionTouchResult(data)
        lastContact = Date()
        return remaining
    }

    /// One call to Moodle's AJAX service (the same endpoint the site's own messenger uses).
    /// No automatic retry: a send must never be repeated by the network layer.
    func ajax(_ method: String, _ args: [String: Any]) async throws -> Any {
        guard let key = sesskey else { throw PortalFailure.loginRequired }
        var components = URLComponents(url: PortalConfiguration.baseURL.appendingPathComponent("lib/ajax/service.php"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sesskey", value: key), URLQueryItem(name: "info", value: method)]
        guard let url = components.url, PortalConfiguration.allowsDataURL(url) else { throw PortalFailure.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = try JSONSerialization.data(withJSONObject: [["index": 0, "methodname": method, "args": args]])
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try Self.checkService(response, method: method)
        let result = try PortalParser.ajaxResult(data)
        lastContact = Date()
        return result
    }

    /// service.php answers 200 with JSON. A redirect (the one to SSO is blocked and arrives
    /// as a bare 3xx) or 401 means the session is gone; a server error is only a failed
    /// request and must not send the user to the login screen.
    static func checkService(_ response: URLResponse, method: String) throws {
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else { throw PortalFailure.invalidResponse }
        if PortalConfiguration.isAuthenticationURL(finalURL) || http.statusCode == 401 || (300..<400).contains(http.statusCode) {
            SessionJournal.add("\(method): ЭИОС требует вход (HTTP \(http.statusCode), \(SessionJournal.place(finalURL)))")
            throw PortalFailure.loginRequired
        }
        guard (200..<300).contains(http.statusCode) else { throw PortalFailure.httpStatus(http.statusCode) }
    }

    func cancelAll() async {
        let tasks = await session.allTasks
        for task in tasks { task.cancel() }
    }
}
