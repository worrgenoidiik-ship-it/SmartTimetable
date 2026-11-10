import CryptoKit
import Foundation
import Security

/// The user's own VPS keeps the ЭИОС session alive while the iPhone sleeps (Server/keeper).
/// The app sends it the validated portal cookies after each login and whenever they change;
/// the server opens one protected page every 30–60 minutes. No password or MAX code leaves
/// the phone. Logout tells the server to forget the cookies.
struct KeeperStatus: Codable, Equatable, Sendable {
    let hasSession: Bool
    let alive: Bool
    let lastOK: Int?
    let lastCheck: Int?
    let error: String?
    let timeout: Int?
    let nextIn: Int?
    let pings: Int?

    enum CodingKeys: String, CodingKey {
        case hasSession = "has_session", alive, lastOK = "last_ok", lastCheck = "last_check"
        case error, timeout, nextIn = "next_in", pings
    }
}

enum KeeperError: LocalizedError, Equatable {
    case notConfigured, invalidAddress, badKey, rejected(String), invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Сервер-пингер не настроен"
        case .invalidAddress: return "Адрес сервера должен начинаться с https://"
        case .badKey: return "Сервер не принял ключ"
        case .rejected(let text): return text
        case .invalidResponse: return "Сервер ответил непонятно"
        }
    }
}

enum Keeper {
    static let addressKey = "smarttable.keeperAddress"
    static let pushedKey = "smarttable.keeperPushedHash"
    static let defaultAddress = "" // each user enters their own server

    static var address: String {
        get { UserDefaults.standard.string(forKey: addressKey) ?? defaultAddress }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: addressKey) }
    }

    static var isConfigured: Bool { KeeperSecret.load() != nil && baseURL(address) != nil }

    static func baseURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    /// Only cookies the portal itself receives, name → value.
    static func portalCookies(_ cookies: [HTTPCookie]) -> [String: String] {
        // The same name can exist for "portal.ulsu.ru" and ".ulsu.ru" (an old copy): the exact
        // host wins, then the longer domain, so a stale duplicate is never sent.
        let live = cookies.filter {
            cookieApplies($0.domain) && !isAnalytics($0.name) && ($0.expiresDate.map { $0 > Date() } ?? true)
        }
        func rank(_ cookie: HTTPCookie) -> Int {
            cookie.domain.lowercased() == PortalConfiguration.baseURL.host!.lowercased() ? 1_000 : cookie.domain.count
        }
        var result: [String: (rank: Int, value: String)] = [:]
        for cookie in live where (result[cookie.name]?.rank ?? -1) < rank(cookie) {
            result[cookie.name] = (rank(cookie), cookie.value)
        }
        return result.mapValues(\.value)
    }

    /// Counters that the portal's pages set next to the session (Яндекс.Метрика, Top.Mail.Ru,
    /// Google Analytics). The keeper does not need them, so they never leave the phone.
    static func isAnalytics(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["_ym", "_ga", "_gid", "_gat", "_gcl", "_fbp", "tmr_", "top100", "yandexuid", "ymex", "yabs"]
            .contains { lower.hasPrefix($0) } || lower == "domain_sid"
    }

    static func cookieApplies(_ domain: String) -> Bool {
        let host = domain.lowercased()
        let portal = PortalConfiguration.baseURL.host!.lowercased()
        if host == portal { return true }
        guard host.hasPrefix(".") else { return false }
        let suffix = String(host.dropFirst())
        return portal == suffix || portal.hasSuffix("." + suffix)
    }

    static func fingerprint(_ cookies: [String: String], address: String) -> String {
        let text = address + "|" + cookies.keys.sorted().map { "\($0)=\(cookies[$0]!)" }.joined(separator: ";")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func request(_ method: String, _ path: String, base: URL, secret: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    static func sessionBody(_ cookies: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["cookies": cookies], options: [.sortedKeys])
    }

    static func parse(_ data: Data, status: Int) throws -> KeeperStatus {
        if status == 401 { throw KeeperError.badKey }
        guard (200..<300).contains(status) else {
            let text = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw KeeperError.rejected(text ?? "Сервер ответил HTTP \(status)")
        }
        guard let value = try? JSONDecoder().decode(KeeperStatus.self, from: data) else { throw KeeperError.invalidResponse }
        return value
    }

    /// No cookies of its own: the keeper is not the portal.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 40
        return URLSession(configuration: config)
    }()

    private static func send(_ method: String, _ path: String, body: Data? = nil) async throws -> KeeperStatus {
        guard let secret = KeeperSecret.load() else { throw KeeperError.notConfigured }
        guard let base = baseURL(address) else { throw KeeperError.invalidAddress }
        let (data, response) = try await session.data(for: request(method, path, base: base, secret: secret, body: body))
        return try parse(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func status() async throws -> KeeperStatus { try await send("GET", "status") }

    /// Sends the cookies when they differ from the last ones the server accepted (or `force`).
    @discardableResult
    static func push(_ cookies: [String: String], force: Bool = false) async throws -> KeeperStatus? {
        guard isConfigured, !cookies.isEmpty else { return nil }
        let print = fingerprint(cookies, address: address)
        if !force, UserDefaults.standard.string(forKey: pushedKey) == print { return nil }
        let value = try await send("PUT", "session", body: try sessionBody(cookies))
        UserDefaults.standard.set(print, forKey: pushedKey)
        return value
    }

    /// Cookies of the session the server still keeps alive (it checks them first), or nil.
    static func liveSession() async throws -> [String: String]? {
        guard let secret = KeeperSecret.load() else { throw KeeperError.notConfigured }
        guard let base = baseURL(address) else { throw KeeperError.invalidAddress }
        let (data, response) = try await session.data(for: request("GET", "session", base: base, secret: secret))
        return try parseLiveSession(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func parseLiveSession(_ data: Data, status: Int) throws -> [String: String]? {
        if status == 404 { return nil }
        if status == 401 { throw KeeperError.badKey }
        guard (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["alive"] as? Bool == true,
              let cookies = object["cookies"] as? [String: String], !cookies.isEmpty,
              cookies.keys.contains(where: { $0.hasPrefix("MoodleSession") }) else { throw KeeperError.invalidResponse }
        return cookies
    }

    /// Server cookies become portal cookies on the phone (host-only, HTTPS only).
    static func httpCookies(_ values: [String: String]) -> [HTTPCookie] {
        let host = PortalConfiguration.baseURL.host!
        return values.keys.sorted().compactMap { name in
            HTTPCookie(properties: [.name: name, .value: values[name]!, .domain: host, .path: "/", .secure: "TRUE"])
        }
    }

    static func forget() async {
        UserDefaults.standard.removeObject(forKey: pushedKey)
        guard isConfigured else { return }
        _ = try? await send("DELETE", "session")
    }
}

/// The keeper's key: Keychain, this device only.
enum KeeperSecret {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "SmartTable") + ".keeper",
         kSecAttrAccount as String: "secret"]
    }

    static func load() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess, let data = value as? Data,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    static func save(_ secret: String) {
        let clean = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: Keeper.pushedKey)
        guard !clean.isEmpty else { return }
        var record = query
        record[kSecValueData as String] = Data(clean.utf8)
        record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(record as CFDictionary, nil)
    }
}
