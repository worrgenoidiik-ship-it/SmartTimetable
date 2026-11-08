import XCTest
@testable import SmartTable

/// 2.0: the session journal that explains why the portal asked to sign in again.
final class SessionJournalTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SessionJournalTests")
        defaults.removePersistentDomain(forName: "SessionJournalTests")
    }

    func testKeepsOnlyTheNewestEntries() {
        for index in 0..<(SessionJournal.limit + 5) { SessionJournal.add("событие \(index)", defaults: defaults) }
        let entries = SessionJournal.entries(defaults: defaults)
        XCTAssertEqual(entries.count, SessionJournal.limit)
        XCTAssertEqual(entries.first?.text, "событие 5")
        XCTAssertEqual(entries.last?.text, "событие \(SessionJournal.limit + 4)")
    }

    func testCopiedTextIsNewestFirstAndClearEmptiesIt() {
        SessionJournal.add("первое", defaults: defaults)
        SessionJournal.add("второе", defaults: defaults)
        let lines = SessionJournal.text(defaults: defaults).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("второе"))
        SessionJournal.clear(defaults: defaults)
        XCTAssertTrue(SessionJournal.entries(defaults: defaults).isEmpty)
    }

    func testPlaceDropsQueryWithTokens() {
        let url = URL(string: "https://sso.ulsu.ru/auth/login-actions/authenticate?session_code=secret&tab_id=1")!
        XCTAssertEqual(SessionJournal.place(url), "sso.ulsu.ru/auth/login-actions/authenticate")
    }

    func testDurations() {
        XCTAssertEqual(SessionJournal.duration(25 * 60), "25 мин")
        XCTAssertEqual(SessionJournal.duration(3 * 3_600 + 600), "3 ч 10 мин")
        XCTAssertEqual(SessionJournal.duration(2 * 86_400 + 3_600), "2 дн. 1 ч")
    }

    func testAjaxErrorCodeIsReadFromExceptionToo() {
        XCTAssertEqual(PortalParser.errorCode(["errorcode": "invalidsesskey"]), "invalidsesskey")
        XCTAssertEqual(PortalParser.errorCode(["exception": ["errorcode": "servicerequireslogin"]]), "servicerequireslogin")
        XCTAssertEqual(PortalParser.errorCode([:]), "")
    }

    func testServiceAnswerOnlyRedirectOrUnauthorizedMeansSignIn() {
        let service = URL(string: "https://portal.ulsu.ru/lib/ajax/service.php")!
        func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        func isLogin(_ value: HTTPURLResponse) -> Bool {
            do { try PortalClient.checkService(value, method: "test"); return false }
            catch let failure as PortalFailure { if case .loginRequired = failure { return true }; return false }
            catch { return false }
        }
        XCTAssertNoThrow(try PortalClient.checkService(response(service, 200), method: "test"))
        XCTAssertTrue(isLogin(response(service, 302)))   // blocked redirect to SSO
        XCTAssertTrue(isLogin(response(service, 401)))
        XCTAssertTrue(isLogin(response(URL(string: "https://portal.ulsu.ru/login/index.php")!, 200)))
        XCTAssertFalse(isLogin(response(service, 503)))  // server trouble is not a logout
    }
}
