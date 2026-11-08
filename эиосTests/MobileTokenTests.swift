import XCTest
@testable import SmartTable

final class MobileTokenTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testTokenParsedWithPrivateToken() throws {
        let token = try MobileAPI.parseToken(data(#"{"token":"abc123","privatetoken":"XyZ789"}"#), username: "ivanov")
        XCTAssertEqual(token.token, "abc123")
        XCTAssertEqual(token.privateToken, "XyZ789")
        XCTAssertEqual(token.username, "ivanov")
        XCTAssertNil(token.userID)
    }

    func testTokenWithoutPrivateToken() throws {
        let token = try MobileAPI.parseToken(data(#"{"token":"abc123","privatetoken":null}"#), username: "u")
        XCTAssertNil(token.privateToken)
    }

    func testInvalidLoginIsRecognized() {
        XCTAssertThrowsError(try MobileAPI.parseToken(
            data(#"{"error":"Неверный логин","errorcode":"invalidlogin","stacktrace":null}"#), username: "u")) {
            XCTAssertEqual($0 as? MobileAPIError, .invalidLogin)
        }
    }

    func testDisabledServiceKeepsCode() {
        XCTAssertThrowsError(try MobileAPI.parseToken(
            data(#"{"error":"Веб-службы отключены","errorcode":"enablewsdescription"}"#), username: "u")) {
            guard case .portal(let code, _)? = $0 as? MobileAPIError else { return XCTFail("\($0)") }
            XCTAssertEqual(code, "enablewsdescription")
        }
    }

    func testTokenRejectsGarbage() {
        XCTAssertThrowsError(try MobileAPI.parseToken(data("<html>login</html>"), username: "u"))
        XCTAssertThrowsError(try MobileAPI.parseToken(data(#"{"token":"a b"}"#), username: "u"))
    }

    func testUserIDFromSiteInfo() throws {
        XCTAssertEqual(try MobileAPI.parseUserID(data(#"{"sitename":"ЭИОС","userid":4521,"username":"x"}"#)), 4521)
    }

    func testExpiredTokenAndLockout() {
        XCTAssertThrowsError(try MobileAPI.parseUserID(
            data(#"{"exception":"moodle_exception","errorcode":"invalidtoken","message":"Invalid token"}"#))) {
            XCTAssertEqual($0 as? MobileAPIError, .invalidToken)
        }
        XCTAssertThrowsError(try MobileAPI.parseAutologin(
            data(#"{"exception":"moodle_exception","errorcode":"autologinkeygenerationlockout","message":"wait"}"#), userID: 1)) {
            XCTAssertEqual($0 as? MobileAPIError, .lockout)
        }
    }

    func testAutologinURLBuiltOnPortal() throws {
        let url = try MobileAPI.parseAutologin(
            data(#"{"key":"K3y","autologinurl":"https://portal.ulsu.ru/admin/tool/mobile/autologin.php","warnings":[]}"#), userID: 77)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.host, "portal.ulsu.ru")
        XCTAssertEqual(url.path, "/admin/tool/mobile/autologin.php")
        XCTAssertEqual(items.first { $0.name == "userid" }?.value, "77")
        XCTAssertEqual(items.first { $0.name == "key" }?.value, "K3y")
        XCTAssertEqual(items.first { $0.name == "urltogo" }?.value, PortalConfiguration.sessionProbeURL.absoluteString)
    }

    func testAutologinURLOffPortalRejected() {
        XCTAssertThrowsError(try MobileAPI.parseAutologin(
            data(#"{"key":"K","autologinurl":"https://evil.example/autologin.php"}"#), userID: 1))
    }

    func testSecretsOnlyInBodyAndAppUserAgent() throws {
        let request = MobileAPI.functionRequest("tool_mobile_get_autologin_key", token: "tok",
                                                [URLQueryItem(name: "privatetoken", value: "secret")])
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("privatetoken=secret"))
        XCTAssertTrue(body.contains("wstoken=tok"))
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("MoodleMobile") == true)

        let login = MobileAPI.tokenRequest(username: "a+b", password: "p&q=1")
        XCTAssertNil(login.url?.query)
        let loginBody = String(data: try XCTUnwrap(login.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(loginBody.contains("service=moodle_mobile_app"))
        XCTAssertFalse(loginBody.contains("p&q=1"), "password must be percent-encoded")
    }

    func testRefusalPausesRequestsForAWeek() {
        let defaults = UserDefaults(suiteName: "MobileTokenBackoffTests")!
        defaults.removePersistentDomain(forName: "MobileTokenBackoffTests")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(MobileTokenBackoff.mayRequest(now: now, defaults: defaults))
        MobileTokenBackoff.refused(now: now, defaults: defaults)
        XCTAssertFalse(MobileTokenBackoff.mayRequest(now: now.addingTimeInterval(6 * 86_400), defaults: defaults))
        XCTAssertTrue(MobileTokenBackoff.mayRequest(now: now.addingTimeInterval(7 * 86_400), defaults: defaults))
        MobileTokenBackoff.reset(defaults: defaults)
        XCTAssertTrue(MobileTokenBackoff.mayRequest(now: now, defaults: defaults))
    }

    func testServiceNotAvailableIsAPortalRefusal() {
        XCTAssertThrowsError(try MobileAPI.parseToken(
            data(#"{"error":"Веб-служба недоступна","errorcode":"servicenotavailable"}"#), username: "u")) {
            guard case .portal(let code, _)? = $0 as? MobileAPIError else { return XCTFail("\($0)") }
            XCTAssertEqual(code, "servicenotavailable")
        }
    }
}
