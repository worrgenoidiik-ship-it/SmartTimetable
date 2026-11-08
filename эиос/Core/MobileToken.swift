import Foundation
import Security

/// Long-lived sign-in through Moodle's mobile-app service (the same one the official Moodle app
/// uses). The web session (cookies) dies after an idle period; the token does not. When the
/// cookies are gone, the token asks the portal for a one-time "autologin" key, and opening that
/// key's URL creates a fresh web session with no password, no MAX code and no login screen.
struct MobileToken: Codable, Equatable, Sendable {
    let username: String
    let token: String
    /// Needed to request autologin keys. The portal sends it only over HTTPS.
    let privateToken: String?
    var userID: Int?
    var obtainedAt: Date = Date()
}

enum MobileAPIError: Error, Equatable {
    /// Wrong login or password (or the account may not use the mobile service).
    case invalidLogin
    /// The token was revoked or has expired: a new one is needed.
    case invalidToken
    /// Autologin keys can be requested only once per few minutes.
    case lockout
    /// Any other error code reported by the portal.
    case portal(code: String, message: String)
    case invalidResponse

    var journalText: String {
        switch self {
        case .invalidLogin: return "неверный логин или пароль"
        case .invalidToken: return "токен больше не действует"
        case .lockout: return "ключ входа можно запрашивать раз в несколько минут"
        case .portal(let code, let message): return "\(code): \(message)"
        case .invalidResponse: return "непонятный ответ ЭИОС"
        }
    }
}

/// Pure request builders and parsers (tested), plus the three calls.
enum MobileAPI {
    static let service = "moodle_mobile_app"
    static let tokenURL = PortalConfiguration.baseURL.appendingPathComponent("login/token.php")
    static let restURL = PortalConfiguration.baseURL.appendingPathComponent("webservice/rest/server.php")
    /// The portal hands out autologin keys only to clients that identify as the Moodle app.
    static let userAgent = "SmartTimetable (MoodleMobile)"

    /// No cookies at all: token calls must not touch or replace the web session.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    static func post(_ url: URL, _ items: [URLQueryItem]) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Secrets go only in the body: the portal rejects a private token sent in the URL.
        request.httpBody = Data(PortalClient.formEncoded(items).utf8)
        return request
    }

    static func tokenRequest(username: String, password: String) -> URLRequest {
        post(tokenURL, [URLQueryItem(name: "username", value: username),
                        URLQueryItem(name: "password", value: password),
                        URLQueryItem(name: "service", value: service)])
    }

    static func functionRequest(_ function: String, token: String, _ args: [URLQueryItem] = []) -> URLRequest {
        post(restURL, [URLQueryItem(name: "wstoken", value: token),
                       URLQueryItem(name: "wsfunction", value: function),
                       URLQueryItem(name: "moodlewsrestformat", value: "json")] + args)
    }

    /// Moodle reports errors as 200 with {"error"/"exception", "errorcode", "message"}.
    static func error(in object: Any) -> MobileAPIError? {
        guard let dictionary = object as? [String: Any] else { return nil }
        guard dictionary["exception"] != nil || dictionary["error"] != nil || dictionary["errorcode"] != nil else { return nil }
        let code = dictionary["errorcode"] as? String ?? ""
        let message = (dictionary["message"] as? String) ?? (dictionary["error"] as? String) ?? ""
        switch code {
        case "invalidlogin": return .invalidLogin
        case "invalidtoken", "accessexception": return .invalidToken
        case "autologinkeygenerationlockout": return .lockout
        default: return .portal(code: code.isEmpty ? "error" : code, message: String(message.prefix(160)))
        }
    }

    private static func json(_ data: Data) throws -> Any {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw MobileAPIError.invalidResponse }
        if let failure = error(in: object) { throw failure }
        return object
    }

    static func parseToken(_ data: Data, username: String) throws -> MobileToken {
        guard let object = try json(data) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty,
              token.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw MobileAPIError.invalidResponse }
        let privateToken = (object["privatetoken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return MobileToken(username: username, token: token, privateToken: privateToken)
    }

    static func parseUserID(_ data: Data) throws -> Int {
        guard let object = try json(data) as? [String: Any] else { throw MobileAPIError.invalidResponse }
        if let id = object["userid"] as? Int, id > 0 { return id }
        if let text = object["userid"] as? String, let id = Int(text), id > 0 { return id }
        throw MobileAPIError.invalidResponse
    }

    /// The autologin URL must stay on the portal: it is opened with the session cookies.
    static func parseAutologin(_ data: Data, userID: Int) throws -> URL {
        guard let object = try json(data) as? [String: Any],
              let key = object["key"] as? String, !key.isEmpty,
              let base = (object["autologinurl"] as? String).flatMap(URL.init(string:)),
              PortalConfiguration.allowsDataURL(base),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw MobileAPIError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "userid", value: String(userID)),
                                 URLQueryItem(name: "key", value: key),
                                 URLQueryItem(name: "urltogo", value: PortalConfiguration.sessionProbeURL.absoluteString)]
        guard let url = components.url else { throw MobileAPIError.invalidResponse }
        return url
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url.map(PortalConfiguration.allowsDataURL) == true else {
            throw MobileAPIError.invalidResponse
        }
        return data
    }

    /// Exchanges the login and password for a token; also learns the numeric user ID.
    static func requestToken(username: String, password: String) async throws -> MobileToken {
        var token = try parseToken(try await send(tokenRequest(username: username, password: password)), username: username)
        token.userID = try parseUserID(try await send(functionRequest("core_webservice_get_site_info", token: token.token)))
        return token
    }

    /// A one-time URL that turns into a fresh web session (valid about a minute, this IP only).
    static func autologinURL(for token: MobileToken) async throws -> URL {
        guard let privateToken = token.privateToken, let userID = token.userID else { throw MobileAPIError.invalidToken }
        let request = functionRequest("tool_mobile_get_autologin_key", token: token.token,
                                      [URLQueryItem(name: "privatetoken", value: privateToken)])
        return try parseAutologin(try await send(request), userID: userID)
    }
}

/// After the portal refuses a token (for УлГУ: `servicenotavailable`, the mobile service is
/// off) the app does not ask again for a week, except right after a manual login.
enum MobileTokenBackoff {
    static let key = "smarttable.mobileTokenRetryAfter"
    static let pause: TimeInterval = 7 * 24 * 3_600

    static func mayRequest(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard let until = defaults.object(forKey: key) as? Date else { return true }
        return now >= until
    }

    static func isPaused(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        !mayRequest(now: now, defaults: defaults)
    }

    static func refused(now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(now.addingTimeInterval(pause), forKey: key)
    }

    static func reset(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

/// Keychain, this device only, readable after the first unlock (background refresh needs it).
enum MobileTokenVault {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "SmartTable") + ".mobiletoken",
         kSecAttrAccount as String: "token"]
    }

    static func load() -> MobileToken? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(MobileToken.self, from: data)
    }

    static func save(_ token: MobileToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        SecItemDelete(query as CFDictionary)
        var record = query
        record[kSecValueData as String] = data
        record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(record as CFDictionary, nil)
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}
