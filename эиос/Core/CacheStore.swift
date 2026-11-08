import Foundation

struct CacheStore {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartTable", isDirectory: true).appendingPathComponent("snapshot-v1.json")
    }

    func load() throws -> PortalSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(PortalSnapshot.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1 else { throw PortalFailure.storage("неизвестная версия кэша") }
        return value
    }

    func save(_ snapshot: PortalSnapshot) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var protectedURL = parent
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        let data = try JSONEncoder().encode(snapshot)
        // Writing is the last throwing operation; a failed write preserves the previous file.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
