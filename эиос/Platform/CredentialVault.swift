import Foundation
import Security

/// Optional saved login, used only to sign in again after the portal ends the session.
/// Keychain, this device only (no iCloud, no backups), readable after the first unlock
/// so a background check can tell whether a re-login is possible. Deleted on logout.
/// The MAX code is never stored.
enum CredentialVault {
    struct Credentials: Codable, Equatable {
        let username: String
        let password: String
    }

    static let enabledKey = "smarttable.rememberLogin"
    private static let flagKey = "smarttable.hasSavedLogin"

    /// The user's choice on the login screen; on by default.
    static var isEnabled: Bool {
        get { (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if !newValue { delete() }
        }
    }

    /// The flag avoids a Keychain read on every check; after a reinstall (UserDefaults wiped,
    /// Keychain kept) it is rebuilt from the Keychain once.
    static var hasCredentials: Bool {
        if let flag = UserDefaults.standard.object(forKey: flagKey) as? Bool { return flag }
        let present = load() != nil
        UserDefaults.standard.set(present, forKey: flagKey)
        return present
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "SmartTable") + ".login",
         kSecAttrAccount as String: "credentials"]
    }

    @MainActor private static var lastAutoSubmit: Date?

    /// True at most once per 15 minutes per app run.
    @MainActor static func claimAutoSubmit() -> Bool {
        if let last = lastAutoSubmit, Date().timeIntervalSince(last) < 900 { return false }
        lastAutoSubmit = Date()
        return true
    }

    static func load() -> Credentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess, let data = value as? Data,
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
              !credentials.username.isEmpty, !credentials.password.isEmpty else { return nil }
        return credentials
    }

    static func save(_ credentials: Credentials) {
        guard isEnabled, let data = try? JSONEncoder().encode(credentials) else { return }
        SecItemDelete(query as CFDictionary)
        var record = query
        record[kSecValueData as String] = data
        record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(record as CFDictionary, nil) == errSecSuccess
        UserDefaults.standard.set(saved, forKey: flagKey)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.set(false, forKey: flagKey)
    }
}
