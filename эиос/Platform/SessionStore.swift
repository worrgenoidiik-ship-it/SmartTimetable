import Foundation
import Security
import WebKit
import UIKit

struct StoredCookie: Codable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Date?
    let secure: Bool
    let httpOnly: Bool
    init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
        expires = cookie.expiresDate; secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly
    }
    var cookie: HTTPCookie? {
        guard expires.map({ $0 > Date() }) ?? true else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path, .secure: secure ? "TRUE" : "FALSE"
        ]
        if let expires = expires { properties[.expires] = expires }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }
}

protocol CookieDataStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

private struct KeychainCookieStorage: CookieDataStorage {
    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "SmartTable") + ".portal",
         kSecAttrAccount as String: "session-cookies"]
    }
    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw PortalFailure.storage("Keychain, код \(status)")
        }
        return data
    }
    func write(_ data: Data) throws {
        let update = [kSecValueData as String: data] as [String: Any]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var record = query
            record[kSecValueData as String] = data
            record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(record as CFDictionary, nil)
            guard added == errSecSuccess else { throw PortalFailure.storage("Keychain, код \(added)") }
        } else if status != errSecSuccess { throw PortalFailure.storage("Keychain, код \(status)") }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PortalFailure.storage("Keychain, код \(status)")
        }
    }
}

// All synchronous Security calls execute on this actor, outside MainActor.
// A stale save queued before logout cannot re-create a deleted session afterwards.
actor CookieVault {
    private let storage: any CookieDataStorage
    private var generation = 0
    private var discardStoredCookies = false
    private var quarantinedStoredCookies = false
    init(storage: any CookieDataStorage) { self.storage = storage }
    init() { storage = KeychainCookieStorage() }
    func load(generation token: Int) throws -> [StoredCookie] {
        guard token == generation else { throw CancellationError() }
        // A failed delete must not restore the old account, but also must not
        // prevent a fresh login. Quarantined data is treated as no saved session.
        guard !discardStoredCookies, !quarantinedStoredCookies else { return [] }
        guard let data = try storage.read() else { return [] }
        return try JSONDecoder().decode([StoredCookie].self, from: data)
    }
    func save(_ cookies: [StoredCookie], generation token: Int) throws {
        guard token == generation else { throw CancellationError() }
        try storage.write(JSONEncoder().encode(cookies))
        quarantinedStoredCookies = false
    }
    func remove(generation token: Int) throws {
        guard token >= generation else { throw CancellationError() }
        generation = token
        discardStoredCookies = true
        quarantinedStoredCookies = true
        defer { discardStoredCookies = false }
        try storage.delete()
        // If delete throws, only old stored data stays quarantined. A successful
        // save from the current generation always admits a fresh login.
        quarantinedStoredCookies = false
    }
}

@MainActor
final class SessionStore {
    static let shared = SessionStore()
    let websiteDataStore = WKWebsiteDataStore.default()
    private var generation = 0
    private var prepared = false
    private var clearing = false
    private let vault = CookieVault()
    private var lastValidatedCookies: [HTTPCookie]?

    func prepare() async throws {
        guard !prepared else { return }
        let token = generation
        try validate(token)
        let stored = try await vault.load(generation: token)
        try validate(token)
        let saved = stored.compactMap(\.cookie)
        if !saved.isEmpty {
            lastValidatedCookies = allowed(saved)
            replaceHTTPCookies(allowed(saved))
            prepared = true
            return // Background refresh needs Keychain/HTTP, not a WebKit process.
        }
        guard UIApplication.shared.applicationState == .active else { return }
        let web = await webCookies()
        try validate(token)
        // Without a verified checkpoint, WebKit provides a candidate only.
        replaceHTTPCookies(allowed(web))
        prepared = true
    }
    /// Keychain items outlive an app deletion, so after a reinstall the previous session's
    /// cookies may still be here even though the profile cache is gone.
    var hasSavedSession: Bool { !(lastValidatedCookies ?? []).isEmpty }

    func captureWebSession() async throws {
        let token = generation
        try validate(token)
        let cookies = allowed(await webCookies())
        try validate(token)
        replaceHTTPCookies(cookies)
        // Candidate only. Login/MAX pages can contain anonymous cookies.
        // PortalClient checkpoints these only after verifying the account.
        prepared = true
    }
    func recoverHTTPFromWeb() async throws -> Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        let token = generation
        let cookies = allowed(await webCookies())
        try validate(token)
        let before = values(allowed(HTTPCookieStorage.shared.cookies ?? []))
        let after = values(cookies)
        guard !after.isEmpty, before != after else { return false }
        replaceHTTPCookies(cookies)
        return true
    }
    /// Puts the last verified cookies back. Returns true when the current ones were different,
    /// i.e. the failed request did not use the verified session and it is worth one more try.
    @discardableResult
    func restoreValidatedHTTP() -> Bool {
        guard !clearing, let cookies = lastValidatedCookies, !cookies.isEmpty else { return false }
        let current = allowed(HTTPCookieStorage.shared.cookies ?? [])
        let changed = values(current) != values(allowed(cookies))
        replaceHTTPCookies(allowed(cookies))
        return changed
    }
    /// Puts the keeper's live session in place of the phone's cookies of the same names.
    func installKeeperCookies(_ cookies: [HTTPCookie]) {
        let names = Set(cookies.map(\.name))
        for cookie in allowed(HTTPCookieStorage.shared.cookies ?? []) where names.contains(cookie.name) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
    }

    /// The last cookies a protected page accepted, as the portal receives them (for the keeper).
    func validatedPortalCookies() -> [String: String] {
        guard !clearing else { return [:] }
        return Keeper.portalCookies(lastValidatedCookies ?? [])
    }

    func checkpointValidatedHTTP() async throws {
        let token = generation
        try validate(token)
        let cookies = allowed(HTTPCookieStorage.shared.cookies ?? [])
        lastValidatedCookies = cookies
        try await vault.save(cookies.map(StoredCookie.init), generation: token)
        try validate(token)
        // Do not wait for WebKit from a background task. browserWillOpen publishes
        // the latest checkpoint before the first foreground page request.
        prepared = true
    }
    func persistHTTPToWeb() async throws {
        let token = generation
        try validate(token)
        let cookies = allowed(lastValidatedCookies ?? HTTPCookieStorage.shared.cookies ?? [])
        let keys = Set(cookies.map(cookieKey))
        let existing = allowed(await webCookies())
        try validate(token)
        for cookie in existing where !keys.contains(cookieKey(cookie)) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                websiteDataStore.httpCookieStore.delete(cookie) { continuation.resume() }
            }
            try validate(token)
        }
        for cookie in cookies {
            try validate(token)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                websiteDataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
            }
        }
        try validate(token)
    }
    func clear() async throws {
        guard !clearing else { throw CancellationError() }
        generation += 1; prepared = false
        clearing = true
        defer { clearing = false }
        let token = generation
        var vaultError: Error?
        lastValidatedCookies = nil
        replaceHTTPCookies([])
        do { try await vault.remove(generation: token) } catch { vaultError = error }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
        if let error = vaultError { throw error }
    }
    private func webCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }
    private func replaceHTTPCookies(_ cookies: [HTTPCookie]) {
        for cookie in allowed(HTTPCookieStorage.shared.cookies ?? []) { HTTPCookieStorage.shared.deleteCookie(cookie) }
        for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
    }
    private func allowed(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter { PortalConfiguration.isUniversityCookieDomain($0.domain) && ($0.expiresDate.map { $0 > Date() } ?? true) }
    }
    private func values(_ cookies: [HTTPCookie]) -> [String: String] {
        Dictionary(cookies.map { (cookieKey($0), $0.value) }, uniquingKeysWith: { _, new in new })
    }
    private func cookieKey(_ cookie: HTTPCookie) -> String { "\(cookie.domain)|\(cookie.path)|\(cookie.name)" }
    private func validate(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == generation, !clearing else { throw CancellationError() }
    }
}
