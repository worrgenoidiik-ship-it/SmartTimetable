import XCTest
@testable import SmartTable

/// 1.9.4: the user's VPS keeps the portal session alive (Server/keeper).
final class KeeperTests: XCTestCase {
    private func cookie(_ name: String, _ value: String, domain: String, expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    func testOnlyCookiesThePortalReceives() {
        let cookies = [
            cookie("MoodleSession", "abc", domain: "portal.ulsu.ru"),
            cookie("shared", "1", domain: ".ulsu.ru"),
            cookie("sso", "x", domain: "sso.ulsu.ru"),
            cookie("other", "y", domain: ".example.com"),
            cookie("old", "z", domain: "portal.ulsu.ru", expires: Date(timeIntervalSinceNow: -60)),
        ]
        XCTAssertEqual(Keeper.portalCookies(cookies), ["MoodleSession": "abc", "shared": "1"])
    }

    func testFingerprintDependsOnValuesAndAddressNotOrder() {
        let a = Keeper.fingerprint(["A": "1", "B": "2"], address: "https://h:1")
        XCTAssertEqual(a, Keeper.fingerprint(["B": "2", "A": "1"], address: "https://h:1"))
        XCTAssertNotEqual(a, Keeper.fingerprint(["A": "1", "B": "3"], address: "https://h:1"))
        XCTAssertNotEqual(a, Keeper.fingerprint(["A": "1", "B": "2"], address: "https://h:2"))
    }

    func testAddressMustBeHTTPS() {
        XCTAssertNotNil(Keeper.baseURL(" https://203.0.113.10:49154 "))
        XCTAssertNil(Keeper.baseURL("http://203.0.113.10:49154"))
        XCTAssertNil(Keeper.baseURL("https://user:pw@host"))
        XCTAssertNil(Keeper.baseURL("https://host/?q=1"))
    }

    func testRequestCarriesKeyInHeaderAndCookiesInBody() throws {
        let base = try XCTUnwrap(Keeper.baseURL("https://h:49154"))
        let body = try Keeper.sessionBody(["MoodleSession": "abc"])
        let request = Keeper.request("PUT", "session", base: base, secret: "k3y", body: body)
        XCTAssertEqual(request.url?.absoluteString, "https://h:49154/session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k3y")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8), #"{"cookies":{"MoodleSession":"abc"}}"#)
    }

    func testStatusParsing() throws {
        let data = Data(#"{"has_session":true,"alive":true,"last_ok":1800000000,"last_check":1800000000,"error":null,"timeout":7200,"next_in":2400,"pings":3}"#.utf8)
        let status = try Keeper.parse(data, status: 200)
        XCTAssertTrue(status.alive)
        XCTAssertEqual(status.timeout, 7200)
        XCTAssertEqual(status.nextIn, 2400)
        XCTAssertNil(status.error)
    }

    func testErrorsFromServer() {
        XCTAssertThrowsError(try Keeper.parse(Data(#"{"error":"неверный ключ"}"#.utf8), status: 401)) {
            XCTAssertEqual($0 as? KeeperError, .badKey)
        }
        XCTAssertThrowsError(try Keeper.parse(Data(#"{"error":"слишком много"}"#.utf8), status: 429)) {
            XCTAssertEqual($0 as? KeeperError, .rejected("слишком много"))
        }
        XCTAssertThrowsError(try Keeper.parse(Data("<html>".utf8), status: 200))
    }

    func testLiveSessionParsing() throws {
        let ok = Data(#"{"cookies":{"MoodleSession":"abc","_ym_uid":"1"},"alive":true}"#.utf8)
        XCTAssertEqual(try Keeper.parseLiveSession(ok, status: 200), ["MoodleSession": "abc", "_ym_uid": "1"])
        XCTAssertNil(try Keeper.parseLiveSession(Data(#"{"error":"нет"}"#.utf8), status: 404))
        XCTAssertThrowsError(try Keeper.parseLiveSession(Data(#"{"cookies":{"x":"1"},"alive":true}"#.utf8), status: 200))
        XCTAssertThrowsError(try Keeper.parseLiveSession(Data("{}".utf8), status: 401)) {
            XCTAssertEqual($0 as? KeeperError, .badKey)
        }
    }

    func testServerCookiesBecomeSecurePortalCookies() {
        let cookies = Keeper.httpCookies(["MoodleSession": "abc"])
        XCTAssertEqual(cookies.count, 1)
        XCTAssertEqual(cookies[0].domain, "portal.ulsu.ru")
        XCTAssertTrue(cookies[0].isSecure)
        XCTAssertEqual(Keeper.portalCookies(cookies), ["MoodleSession": "abc"])
    }

    func testExactHostCookieWinsOverDuplicate() {
        let cookies = [
            cookie("MoodleSession", "fresh", domain: "portal.ulsu.ru"),
            cookie("MoodleSession", "stale", domain: ".ulsu.ru"),
        ]
        XCTAssertEqual(Keeper.portalCookies(cookies), ["MoodleSession": "fresh"])
        XCTAssertEqual(Keeper.portalCookies(cookies.reversed()), ["MoodleSession": "fresh"])
    }
}
