import XCTest
import WebKit
@testable import SmartTable

final class PortalLoginWebKitTests: XCTestCase {
    // This test needs an iOS test host. No external URL is loaded and no password is sent.
    @MainActor
    func testActualAdapterReturnsJSONStringThroughCallAsyncJavaScript() async throws {
        let bundle = Bundle(for: Self.self)
        let fixture = try XCTUnwrap(bundle.url(forResource: "login_attached_20261004", withExtension: "html", subdirectory: "Fixtures") ??
                                    bundle.url(forResource: "login_attached_20261004", withExtension: "html"))
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        let ready = expectation(description: "Local HTML loaded in WebKit")
        let delegate = LocalLoginDocumentDelegate(ready: ready)
        view.navigationDelegate = delegate
        defer { view.stopLoading(); view.navigationDelegate = nil }
        view.loadHTMLString(try String(contentsOf: fixture, encoding: .utf8), baseURL: PortalConfiguration.loginURL)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNil(delegate.failure)
        let raw = try await view.callAsyncJavaScript(PortalLoginBridge.script,
            arguments: ["mode": "inspect", "username": "", "password": "", "code": ""], in: nil, contentWorld: .page)
        XCTAssertTrue(raw is String, "Production adapter must cross WebKit as JSON text")
        let value = PortalLoginController.decodeBridgeResult(raw)
        XCTAssertEqual(value["kind"] as? String, "credentials")
        XCTAssertNil(value["submitted"])
    }
    @MainActor
    func testAsyncOverloadAwaitsPromiseAndReturnsItsString() async throws {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        let ready = expectation(description: "Empty local document loaded")
        let delegate = LocalLoginDocumentDelegate(ready: ready)
        view.navigationDelegate = delegate
        defer { view.stopLoading(); view.navigationDelegate = nil }
        view.loadHTMLString("<html><body></body></html>", baseURL: nil)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNil(delegate.failure)
        let result = try await view.callAsyncJavaScript(
            "await new Promise(resolve => setTimeout(resolve, 50)); return 'smarttable-wk-v3';",
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? String, "smarttable-wk-v3")
    }

}

@MainActor
private final class LocalLoginDocumentDelegate: NSObject, WKNavigationDelegate {
    let ready: XCTestExpectation
    var failure: Error?
    private var resolved = false
    init(ready: XCTestExpectation) { self.ready = ready }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { resolve(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { resolve(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { resolve(error) }
    private func resolve(_ error: Error?) {
        guard !resolved else { return }
        resolved = true; failure = error; ready.fulfill()
    }
}
