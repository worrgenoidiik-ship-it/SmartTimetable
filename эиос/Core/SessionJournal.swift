import Foundation

/// A short local log of what happened to the portal session: why the app decided it had
/// ended, keep-alive results, background runs, logins. Shown in Settings so the next drop
/// can be explained from facts. Never contains cookies, sesskeys, passwords or page text.
enum SessionJournal {
    static let key = "smarttable.sessionJournal"
    static let limit = 250
    private static let lock = NSLock()

    struct Entry: Codable, Sendable, Identifiable {
        let date: Date
        let text: String
        var id: String { "\(date.timeIntervalSince1970)|\(text)" }
    }

    static func add(_ text: String, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        var values = load(defaults)
        values.append(Entry(date: Date(), text: text))
        if values.count > limit { values.removeFirst(values.count - limit) }
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key) }
    }

    static func entries(defaults: UserDefaults = .standard) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return load(defaults)
    }

    static func clear(defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }

    /// Plain text for «Скопировать»: newest first, one line per event.
    static func text(defaults: UserDefaults = .standard) -> String {
        let format = CampusDate.formatter("dd.MM HH:mm:ss")
        return entries(defaults: defaults).reversed().map { format.string(from: $0.date) + "  " + $0.text }
            .joined(separator: "\n")
    }

    /// Only host and path: a query can carry tokens of the identity provider.
    static func place(_ url: URL?) -> String {
        guard let url = url else { return "?" }
        return (url.host ?? "") + url.path
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes >= 2 * 1_440 { return "\(minutes / 1_440) дн. \(minutes % 1_440 / 60) ч" }
        if minutes >= 60 { return "\(minutes / 60) ч \(minutes % 60) мин" }
        return "\(minutes) мин"
    }

    private static func load(_ defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
