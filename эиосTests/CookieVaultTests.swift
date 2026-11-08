import XCTest
@testable import SmartTable

final class CookieVaultTests: XCTestCase {
    private func cookie() throws -> StoredCookie {
        let value = try XCTUnwrap(HTTPCookie(properties: [
            .name: "SyntheticSession", .value: "synthetic", .domain: "portal.ulsu.ru", .path: "/", .secure: "TRUE"
        ]))
        return StoredCookie(value)
    }
    func testLateVaultSaveCannotRestoreLoggedOutSession() async throws {
        let vault = CookieVault(storage: MemoryCookieDataStorage())
        let value = try cookie()
        try await vault.save([value], generation: 0)
        try await vault.remove(generation: 1)
        do { try await vault.save([value], generation: 0); XCTFail("Stale session was accepted") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let saved = try await vault.load(generation: 1)
        XCTAssertTrue(saved.isEmpty)
    }
    func testNewVaultGenerationCanSaveAfterLogout() async throws {
        let vault = CookieVault(storage: MemoryCookieDataStorage())
        try await vault.remove(generation: 1)
        try await vault.save([cookie()], generation: 1)
        let saved = try await vault.load(generation: 1)
        XCTAssertEqual(saved.map(\.name), ["SyntheticSession"])
    }
    func testOldClearCannotDeleteNewVaultSession() async throws {
        let vault = CookieVault(storage: MemoryCookieDataStorage())
        try await vault.remove(generation: 1)
        try await vault.save([cookie()], generation: 1)
        do { try await vault.remove(generation: 0); XCTFail("Old clear was accepted") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let saved = try await vault.load(generation: 1)
        XCTAssertEqual(saved.count, 1)
    }
    func testFailedVaultDeleteDoesNotExposeOldSession() async throws {
        let vault = CookieVault(storage: MemoryCookieDataStorage(failsDeletion: true))
        try await vault.save([cookie()], generation: 0)
        do { try await vault.remove(generation: 1); XCTFail("Expected storage failure") } catch {}
        let quarantined = try await vault.load(generation: 1)
        XCTAssertTrue(quarantined.isEmpty, "Old session exposed after failed logout")
        do { try await vault.save([cookie()], generation: 0); XCTFail("Stale session accepted") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testFailedDeleteStillAllowsFreshLoginToReplaceTheSession() async throws {
        let vault = CookieVault(storage: MemoryCookieDataStorage(failsDeletion: true))
        try await vault.save([cookie()], generation: 0)
        do { try await vault.remove(generation: 1); XCTFail("Expected deletion error") } catch {}
        let empty = try await vault.load(generation: 1)
        XCTAssertTrue(empty.isEmpty)
        let fresh = try XCTUnwrap(HTTPCookie(properties: [
            .name: "NewAccountSession", .value: "new-synthetic", .domain: "portal.ulsu.ru", .path: "/"
        ]))
        try await vault.save([StoredCookie(fresh)], generation: 1)
        let saved = try await vault.load(generation: 1)
        XCTAssertEqual(saved.map(\.name), ["NewAccountSession"])
    }
    func testFailedFreshSaveKeepsOldCookiesQuarantinedButNextSaveCanRecover() async throws {
        let storage = MemoryCookieDataStorage(failsDeletion: true)
        let vault = CookieVault(storage: storage)
        try await vault.save([cookie()], generation: 0)
        do { try await vault.remove(generation: 1); XCTFail("Expected deletion failure") } catch {}
        storage.failNextWrite()
        do { try await vault.save([cookie()], generation: 1); XCTFail("Expected write failure") } catch {}
        let afterFailure = try await vault.load(generation: 1)
        XCTAssertTrue(afterFailure.isEmpty)
        try await vault.save([cookie()], generation: 1)
        let recovered = try await vault.load(generation: 1)
        XCTAssertEqual(recovered.count, 1)
    }

}

// Only synthetic data; the tests never access the user's real Keychain.
private final class MemoryCookieDataStorage: CookieDataStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private let failsDeletion: Bool
    private var failsWriting = false
    init(failsDeletion: Bool = false) { self.failsDeletion = failsDeletion }
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func failNextWrite() { lock.lock(); defer { lock.unlock() }; failsWriting = true }
    func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failsWriting { failsWriting = false; throw PortalFailure.storage("synthetic write failure") }
        self.data = data
    }
    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        if failsDeletion { throw PortalFailure.storage("synthetic failure") }
        data = nil
    }
}
