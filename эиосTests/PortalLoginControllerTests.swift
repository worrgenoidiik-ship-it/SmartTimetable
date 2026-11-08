import XCTest
import WebKit
import UIKit
@testable import SmartTable

final class PortalLoginControllerTests: XCTestCase {
    @MainActor
    private func makeController(_ page: LoginPageDouble, timeout: UInt64 = 1_000_000_000,
                                verificationTimeout: UInt64 = 1_000_000_000,
                                inspectionAttempts: Int = 2) -> PortalLoginController {
        var dependencies = PortalLoginDependencies()
        dependencies.prepare = { await page.prepare() }
        dependencies.verify = { page.verifications += 1; return await page.verify() }
        dependencies.canRetryVerification = { page.retryVerification }
        dependencies.finish = { page.finishes += 1 }
        dependencies.loginError = { nil }
        dependencies.websiteDataStore = .nonPersistent()
        dependencies.presentDialog = { page.dialogs.append($0) }
        dependencies.load = { request in page.requests.append(request); page.onLoad?() }
        dependencies.evaluate = { mode, _ in
            let value: [String: Any]
            if mode == "inspect" {
                page.reads += 1
                if let raw = page.rawResult { return raw }
                if let suspended = page.suspendedRead { value = await suspended() }
                else if !page.inspectionResults.isEmpty { value = page.inspectionResults.removeFirst() }
                else { value = page.result }
            } else {
                page.submissions.append(mode)
                page.result = page.nextResult
                if let suspended = page.suspendedSubmission { value = await suspended() }
                else { value = page.submissionReply ?? ["kind": mode, "submitted": true] }
            }
            return String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)
        }
        dependencies.inspectionAttempts = inspectionAttempts
        dependencies.inspectionInterval = 1_000_000
        dependencies.timeoutInterval = timeout
        dependencies.verificationTimeoutInterval = verificationTimeout
        dependencies.verificationRetryInterval = 1_000_000
        return PortalLoginController(dependencies: dependencies)
    }
    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Controller did not reach the expected state within one second")
    }
    @MainActor
    func testFormBecomesReadyOnCommitWithoutWaitingForDidFinish() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "credentials"]
        let controller = makeController(page); defer { controller.close() }
        await controller.start()
        controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        XCTAssertFalse(controller.busy)
        XCTAssertEqual(controller.form, .credentials)
        XCTAssertEqual(page.requests.count, 1)
        XCTAssertEqual(page.submissions, [])
    }
    @MainActor
    func testRetryLoadsFreshGETAndOnePressSubmitsOnlyOnce() async throws {
        let page = LoginPageDouble()
        let controller = makeController(page); defer { controller.close() }
        page.onLoad = { [weak controller] in
            guard let controller = controller else { return }
            controller.webView(controller.webView, didCommit: nil)
        }
        await controller.start()
        try await waitUntil { !controller.busy }
        XCTAssertFalse(controller.formReady)
        page.result = ["kind": "credentials"]
        let sent = await controller.submit(username: "synthetic-student", password: "synthetic-password")
        try await waitUntil { controller.form == .oneTimeCode && controller.formReady }
        XCTAssertTrue(sent)
        XCTAssertEqual(page.requests.count, 2, "Retry must leave the previous failed document")
        XCTAssertTrue(page.requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
        XCTAssertEqual(page.requests.last?.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(page.submissions, ["credentials"])
    }
    @MainActor
    func testLateDidFinishDoesNotInvalidateAnAlreadyReadyForm() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "credentials"]
        let controller = makeController(page); defer { controller.close() }
        await controller.start()
        controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        let reads = page.reads
        page.result = ["kind": "web", "reason": "login_form_missing"]
        controller.webView(controller.webView, didFinish: nil)
        await Task.yield()
        XCTAssertTrue(controller.formReady)
        XCTAssertEqual(page.reads, reads)
    }
    @MainActor
    func testMAXRetryInspectsCurrentChallengeWithoutLoadingLoginAgain() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "code"]
        let controller = makeController(page); defer { controller.close() }
        await controller.start()
        controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        page.result = ["kind": "web", "reason": "code_form_missing"]
        controller.webView(controller.webView, didStartProvisionalNavigation: nil)
        controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { !controller.busy }
        page.result = ["kind": "code"]
        controller.retryConnection()
        try await waitUntil { controller.formReady }
        XCTAssertEqual(controller.form, .oneTimeCode)
        XCTAssertEqual(page.requests.count, 1)
        XCTAssertTrue(page.submissions.isEmpty)
    }
    @MainActor
    func testUnknownBridgeResultHasUsefulDiagnosticWithoutArbitrarySecretText() async throws {
        let page = LoginPageDouble()
        page.result = ["kind": "web", "reason": "untrusted-secret-value", "error": "synthetic server error"]
        let controller = makeController(page); defer { controller.close() }
        await controller.start()
        controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { !controller.busy }
        XCTAssertEqual(controller.error, "synthetic server error")
        XCTAssertTrue(controller.diagnosticText.contains("unknown_form"))
        XCTAssertFalse(controller.diagnosticText.contains("untrusted-secret-value"))
        XCTAssertFalse(controller.diagnosticText.contains("synthetic server error"))
    }
    @MainActor
    func testClosingRejectsAReadWhichCompletesAfterwards() async throws {
        let page = LoginPageDouble()
        var continuation: CheckedContinuation<[String: Any], Never>?
        page.suspendedRead = { await withCheckedContinuation { continuation = $0 } }
        let controller = makeController(page)
        await controller.start()
        controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { continuation != nil }
        controller.close()
        continuation?.resume(returning: ["kind": "credentials"])
        await Task.yield()
        XCTAssertFalse(controller.formReady)
        XCTAssertTrue(page.submissions.isEmpty)
    }
    @MainActor
    func testTimeoutStopsSpinnerAndRejectsLateReadyResult() async throws {
        let page = LoginPageDouble()
        var continuation: CheckedContinuation<[String: Any], Never>?
        page.suspendedRead = { await withCheckedContinuation { continuation = $0 } }
        let controller = makeController(page, timeout: 50_000_000); defer { controller.close() }
        await controller.start()
        controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { continuation != nil }
        try await waitUntil { !controller.busy }
        continuation?.resume(returning: ["kind": "credentials"])
        await Task.yield()
        XCTAssertFalse(controller.formReady)
        XCTAssertNotNil(controller.error)
        XCTAssertTrue(page.submissions.isEmpty)
    }
}

extension PortalLoginControllerTests {
    func testJSONTextDecoderPreservesUnicodeAndSubmission() {
        let value = PortalLoginController.decodeBridgeResult("{\"kind\":\"code\",\"submitted\":true,\"error\":\"Неверный код\",\"responseRevision\":2}")
        XCTAssertEqual(value["kind"] as? String, "code")
        XCTAssertEqual(value["submitted"] as? Bool, true)
        XCTAssertEqual(value["error"] as? String, "Неверный код")
        XCTAssertEqual(value["responseRevision"] as? Int, 2)
    }
    func testJSONDecoderRejectsRawObjectsMalformedTextAndWrongShape() {
        let samples: [(Any?, String)] = [
            (["kind": "credentials"], "invalid_bridge_result"), (nil, "invalid_bridge_result"),
            ("undefined", "invalid_bridge_json"), ("[]", "invalid_bridge_json"),
            ("{}", "invalid_bridge_payload"), ("{\"kind\":\"unknown\"}", "invalid_bridge_payload"),
            ("{\"kind\":\"code\",\"submitted\":\"true\"}", "invalid_bridge_payload")
        ]
        for (raw, reason) in samples { XCTAssertEqual(PortalLoginController.decodeBridgeResult(raw)["reason"] as? String, reason) }
    }
    @MainActor
    func testControllerRejectsNonStringBridgeThroughProductionDecoder() async throws {
        let page = LoginPageDouble(); page.rawResult = ["kind": "credentials"]
        let controller = makeController(page); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { !controller.busy }
        XCTAssertFalse(controller.formReady)
        XCTAssertTrue(controller.diagnosticText.contains("invalid_bridge_result"))
        XCTAssertEqual(page.reads, 1)
    }
    @MainActor
    func testHTTP403SurvivesPolicyCancellationAndLateDidFinish() async throws {
        let page = LoginPageDouble()
        let controller = makeController(page)
        defer { controller.close() }
        await controller.start()
        XCTAssertFalse(controller.acceptHTTPStatus(403))
        let message = controller.error
        controller.webView(controller.webView, didFailProvisionalNavigation: nil,
                           withError: NSError(domain: "WebKitErrorDomain", code: 102))
        controller.webView(controller.webView, didFinish: nil)
        XCTAssertEqual(controller.error, message)
        XCTAssertTrue(controller.diagnosticText.contains("HTTP: 403"))
        XCTAssertTrue(controller.diagnosticText.contains("Причина: http_error"))
        XCTAssertFalse(controller.busy)
        XCTAssertTrue(page.submissions.isEmpty)
    }
    @MainActor
    func testUnsolicited102DuringLoadIsStillReported() async throws {
        let controller = makeController(LoginPageDouble()); defer { controller.close() }
        await controller.start()
        controller.webView(controller.webView, didFailProvisionalNavigation: nil,
                           withError: NSError(domain: "WebKitErrorDomain", code: 102))
        XCTAssertTrue(controller.diagnosticText.contains("navigation_error_102"))
        XCTAssertFalse(controller.busy)
    }
    @MainActor
    func testSubmissionTimeoutInspectsMAXAndIgnoresLateBridgeReply() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "credentials"]
        var continuation: CheckedContinuation<[String: Any], Never>?
        page.suspendedSubmission = { await withCheckedContinuation { continuation = $0 } }
        let controller = makeController(page, timeout: 50_000_000); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        let sending = Task { await controller.submit(username: "test", password: "synthetic") }
        try await waitUntil { continuation != nil }
        try await waitUntil { controller.form == .oneTimeCode && controller.formReady }
        continuation?.resume(returning: ["kind": "credentials", "submitted": true])
        _ = await sending.value
        XCTAssertEqual(controller.form, .oneTimeCode)
        XCTAssertTrue(controller.formReady)
        XCTAssertFalse(controller.isAwaitingResult)
        XCTAssertEqual(page.requests.count, 1)
        XCTAssertEqual(page.submissions, ["credentials"])
    }
    @MainActor
    func testUnknownPOSTResultRetryDoesNotReloadOrResubmitCredentials() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "credentials"]; page.nextResult = page.result
        let controller = makeController(page); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        _ = await controller.submit(username: "test", password: "synthetic")
        try await waitUntil { !controller.busy }
        XCTAssertTrue(controller.isAwaitingResult)
        XCTAssertTrue(controller.diagnosticText.contains("submission_result_pending"))
        page.result = ["kind": "code"]
        let resubmitted = await controller.submit()
        XCTAssertFalse(resubmitted)
        try await waitUntil { controller.formReady }
        XCTAssertEqual(controller.form, .oneTimeCode)
        XCTAssertEqual(page.requests.count, 1)
        XCTAssertEqual(page.submissions, ["credentials"])
    }
    @MainActor
    func testProtectedVerificationUsesSeparateDeadlineAndCompletes() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "credentials"]; page.nextResult = ["kind": "authenticated"]
        page.verify = { try? await Task.sleep(nanoseconds: 100_000_000); return true }
        let controller = makeController(page, timeout: 40_000_000, verificationTimeout: 500_000_000)
        defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        _ = await controller.submit(username: "test", password: "synthetic")
        try await waitUntil { controller.completed }
        XCTAssertFalse(controller.busy)
        XCTAssertFalse(controller.isAwaitingResult)
        XCTAssertNil(controller.error)
        XCTAssertEqual(page.verifications, 1)
    }
    @MainActor
    func testCloseCancelsVerificationRejectsLateSuccessAndWaitsBeforeCookieFinish() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "authenticated"]
        var continuation: CheckedContinuation<Bool, Never>?
        var wasCancelled = false
        page.verify = {
            let result = await withCheckedContinuation { continuation = $0 }
            wasCancelled = Task.isCancelled
            return result
        }
        let controller = makeController(page)
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { continuation != nil }
        controller.close()
        await Task.yield()
        XCTAssertEqual(page.finishes, 0)
        continuation?.resume(returning: true)
        try await waitUntil { page.finishes == 1 }
        XCTAssertTrue(wasCancelled)
        XCTAssertFalse(controller.completed)
        XCTAssertFalse(controller.formReady)
    }
    @MainActor
    func testVerificationTimeoutKeepsReadOnlyRecoveryAndRejectsLateSuccess() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "authenticated"]
        var continuation: CheckedContinuation<Bool, Never>?
        page.verify = { await withCheckedContinuation { continuation = $0 } }
        let controller = makeController(page, verificationTimeout: 50_000_000); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { continuation != nil }
        try await waitUntil { !controller.busy }
        XCTAssertTrue(controller.diagnosticText.contains("verification_timeout"))
        XCTAssertTrue(controller.isAwaitingResult)
        continuation?.resume(returning: true)
        await Task.yield()
        XCTAssertFalse(controller.completed)
        XCTAssertEqual(page.requests.count, 1)
        XCTAssertTrue(page.submissions.isEmpty)
    }
    @MainActor
    func testRepeatedMAXErrorWithNewRevisionIsAcceptedOnFirstInspection() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "code", "error": "Неверный код", "responseRevision": 1]
        page.nextResult = ["kind": "code", "error": "Неверный код", "responseRevision": 2]
        page.submissionReply = ["kind": "code", "submitted": true, "responseRevision": 1]
        let controller = makeController(page); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        let reads = page.reads
        _ = await controller.submit(code: "123456")
        try await waitUntil { !controller.busy }
        XCTAssertTrue(controller.formReady)
        XCTAssertFalse(controller.isAwaitingResult)
        XCTAssertEqual(controller.error, "Неверный код")
        XCTAssertEqual(page.reads - reads, 1)
    }
    @MainActor
    func testUnchangedMAXErrorRemainsPendingInsteadOfPretendingToBeNew() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "code", "error": "Неверный код", "responseRevision": 1]
        page.nextResult = page.result
        page.submissionReply = ["kind": "code", "submitted": true, "responseRevision": 1]
        let controller = makeController(page); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        _ = await controller.submit(code: "123456")
        try await waitUntil { !controller.busy }
        XCTAssertTrue(controller.isAwaitingResult)
        XCTAssertFalse(controller.formReady)
        XCTAssertEqual(page.submissions, ["code"])
    }
    @MainActor
    func testNavigationResponseWinsRaceWithOldBridgeAndAcceptsSameLoginError() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "credentials", "error": "Неверный пароль"]
        page.nextResult = page.result
        var continuation: CheckedContinuation<[String: Any], Never>?
        page.suspendedSubmission = { await withCheckedContinuation { continuation = $0 } }
        let controller = makeController(page); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        let sending = Task { await controller.submit(username: "test", password: "synthetic") }
        try await waitUntil { continuation != nil }
        controller.webView(controller.webView, didStartProvisionalNavigation: nil)
        controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        continuation?.resume(returning: ["kind": "web", "reason": "invalid_bridge_result"])
        _ = await sending.value
        XCTAssertTrue(controller.formReady)
        XCTAssertFalse(controller.isAwaitingResult)
        XCTAssertEqual(controller.error, "Неверный пароль")
        XCTAssertEqual(page.submissions, ["credentials"])
    }
    @MainActor
    func testCloseWaitsForPreparationBeforeReleasingBrowser() async throws {
        let page = LoginPageDouble()
        var continuation: CheckedContinuation<Void, Never>?
        page.prepare = { await withCheckedContinuation { continuation = $0 } }
        let controller = makeController(page)
        let starting = Task { await controller.start() }
        try await waitUntil { continuation != nil }
        controller.close(); await Task.yield()
        XCTAssertEqual(page.finishes, 0)
        continuation?.resume(); await starting.value
        try await waitUntil { page.finishes == 1 }
        XCTAssertTrue(page.requests.isEmpty)
    }
    @MainActor
    func testCloseResolvesAllJavaScriptDialogKindsExactlyOnce() {
        let page = LoginPageDouble()
        // Use a retained presentation seam; no UI window or portal is involved.
        let tested = makeController(page)
        var alerts = 0, confirms: [Bool] = [], prompts: [String?] = []
        tested.showAlert(message: "synthetic") { alerts += 1 }
        tested.showConfirm(message: "synthetic") { confirms.append($0) }
        tested.showPrompt(message: "synthetic", defaultText: nil) { prompts.append($0) }
        XCTAssertEqual(page.dialogs.count, 3)
        tested.close(); tested.close()
        XCTAssertEqual(alerts, 1)
        XCTAssertEqual(confirms, [false])
        XCTAssertEqual(prompts.count, 1)
        XCTAssertNil(prompts.first!)
    }
    @MainActor
    func testDialogReplyCannotRunTwiceAfterLateAction() {
        var values: [Bool] = []
        let reply = LoginDialogReply<Bool> { values.append($0) }
        reply.resolve(false); reply.resolve(true)
        XCTAssertEqual(values, [false])
    }
}

extension PortalLoginControllerTests {
    func testVoidFromCallbackOverloadHasExplicitSafeDiagnostic() {
        func noResult() {}
        let raw: Any = noResult()
        let decoded = PortalLoginController.decodeBridgeResult(raw)
        XCTAssertEqual(decoded["reason"] as? String, "invalid_bridge_result")
        XCTAssertEqual(decoded["wireType"] as? String, "void")
    }
    func testMissingResultAndValidJSONStringHaveDistinctNativeTypes() {
        XCTAssertEqual(PortalLoginController.decodeBridgeResult(nil)["wireType"] as? String, "nil")
        let decoded = PortalLoginController.decodeBridgeResult("{\"kind\":\"credentials\"}")
        XCTAssertEqual(decoded["kind"] as? String, "credentials")
        XCTAssertEqual(decoded["wireType"] as? String, "string")
    }
    @MainActor
    func testCopiedDiagnosticContainsOnlyWireCategoryAndNotRawValue() async throws {
        let page = LoginPageDouble(); page.rawResult = ["private-value": "never-copy-this"]
        let controller = makeController(page); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { !controller.busy }
        XCTAssertTrue(controller.diagnosticText.contains("Ответ JS: object"))
        XCTAssertFalse(controller.diagnosticText.contains("never-copy-this"))
        XCTAssertFalse(controller.diagnosticText.contains("private-value"))
    }
}

extension PortalLoginControllerTests {
    @MainActor
    func testPartlyMountedMAXFormWaitsForCompleteControlsWithoutAnError() async throws {
        let page = LoginPageDouble()
        page.inspectionResults = [
            ["kind": "web", "reason": "max_form_changed", "error": "Изменилась форма подтверждения MAX."],
            ["kind": "web", "reason": "code_form_missing"],
            ["kind": "code"]
        ]
        let controller = makeController(page, inspectionAttempts: 4); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        XCTAssertEqual(page.reads, 3)
        XCTAssertEqual(controller.form, .oneTimeCode)
        XCTAssertNil(controller.error)
        XCTAssertEqual(page.verifications, 0)
        XCTAssertTrue(page.submissions.isEmpty)
    }
    @MainActor
    func testMAXProcessingWaitsForRealSuccessAndCannotSubmitTwice() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "code"]
        page.verify = { true }
        let controller = makeController(page); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        var continuation: CheckedContinuation<[String: Any], Never>?
        page.suspendedRead = { await withCheckedContinuation { continuation = $0 } }
        _ = await controller.submit(code: "123456")
        try await waitUntil { continuation != nil }
        XCTAssertTrue(controller.isCheckingCode)
        XCTAssertNil(controller.error)
        XCTAssertFalse(controller.completed)
        let duplicate = await controller.submit(code: "123456")
        XCTAssertFalse(duplicate)
        continuation?.resume(returning: ["kind": "authenticated"])
        try await waitUntil { controller.completed }
        XCTAssertEqual(page.submissions, ["code"])
        XCTAssertEqual(page.verifications, 1)
        XCTAssertFalse(controller.isCheckingCode)
    }
    @MainActor
    func testNewDocumentWithUnchangedMAXFormDoesNotFinishPendingCode() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "code"]
        var continuation: CheckedContinuation<[String: Any], Never>?
        page.suspendedSubmission = { await withCheckedContinuation { continuation = $0 } }
        let controller = makeController(page); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        let sending = Task { await controller.submit(code: "123456") }
        try await waitUntil { continuation != nil }
        controller.webView(controller.webView, didStartProvisionalNavigation: nil)
        controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { !controller.busy }
        continuation?.resume(returning: ["kind": "code", "submitted": true]); _ = await sending.value
        XCTAssertTrue(controller.isAwaitingResult)
        XCTAssertFalse(controller.formReady)
        XCTAssertFalse(controller.completed)
        XCTAssertEqual(page.submissions, ["code"])
        XCTAssertEqual(page.requests.count, 1)
    }
    @MainActor
    func testPendingFlagSuppressesAnIntermediateMAXMessageUntilResponseArrives() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "code"]
        let controller = makeController(page); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        page.inspectionResults = [
            ["kind": "code", "pending": true, "error": "Проверяем", "responseRevision": 1],
            ["kind": "code", "pending": false, "error": "Неверный код", "responseRevision": 2]
        ]
        _ = await controller.submit(code: "123456")
        try await waitUntil { controller.formReady }
        XCTAssertEqual(controller.error, "Неверный код")
        XCTAssertFalse(controller.isAwaitingResult)
        XCTAssertEqual(page.submissions, ["code"])
    }
    @MainActor
    func testSessionSettlingRetriesOnlyProtectedReadAndCompletes() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "authenticated"]
        page.retryVerification = true
        page.verify = { page.verifications == 2 }
        let controller = makeController(page); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.completed }
        XCTAssertEqual(page.verifications, 2)
        XCTAssertNil(controller.error)
        XCTAssertEqual(page.requests.count, 1)
        XCTAssertTrue(page.submissions.isEmpty)
    }
    @MainActor
    func testFailedVerificationIsBoundedAndFatalFailureDoesNotRetry() async throws {
        for retry in [false, true] {
            let page = LoginPageDouble(); page.result = ["kind": "authenticated"]
            page.retryVerification = retry
            let controller = makeController(page)
            await controller.start(); controller.webView(controller.webView, didCommit: nil)
            try await waitUntil { !controller.busy }
            XCTAssertEqual(page.verifications, retry ? 2 : 1)
            XCTAssertFalse(controller.completed)
            XCTAssertTrue(controller.isAwaitingResult)
            XCTAssertTrue(page.submissions.isEmpty)
            controller.close()
        }
    }
    @MainActor
    func testTransientRedirectFailureCanReadAlreadyRenderedMAXWithoutNewGET() async throws {
        let page = LoginPageDouble(); page.result = ["kind": "credentials"]
        var continuation: CheckedContinuation<[String: Any], Never>?
        page.suspendedSubmission = { await withCheckedContinuation { continuation = $0 } }
        let controller = makeController(page); defer { controller.close() }
        await controller.start(); controller.webView(controller.webView, didCommit: nil)
        try await waitUntil { controller.formReady }
        let sending = Task { await controller.submit(username: "test", password: "synthetic") }
        try await waitUntil { continuation != nil }
        controller.webView(controller.webView, didStartProvisionalNavigation: nil)
        controller.webView(controller.webView, didFailProvisionalNavigation: nil, withError: URLError(.networkConnectionLost))
        try await waitUntil { controller.formReady }
        continuation?.resume(returning: ["kind": "credentials", "submitted": true]); _ = await sending.value
        XCTAssertEqual(controller.form, .oneTimeCode)
        XCTAssertNil(controller.error)
        XCTAssertEqual(page.requests.count, 1)
        XCTAssertEqual(page.submissions, ["credentials"])
    }
    @MainActor
    func testTLSFailureHasFriendlyLoginCopyWithoutClaimingSavedData() async throws {
        let page = LoginPageDouble()
        let controller = makeController(page); defer { controller.close() }
        await controller.start()
        controller.webView(controller.webView, didFailProvisionalNavigation: nil, withError: URLError(.secureConnectionFailed))
        XCTAssertEqual(controller.error, "Не удаётся подключиться к ЭИОС. Попробуйте ещё раз.")
        XCTAssertTrue(controller.diagnosticText.contains("navigation_error_-1200"))
        XCTAssertFalse(controller.completed)
        XCTAssertFalse(controller.busy)
    }
    func testPendingFlagMustBeBoolean() {
        XCTAssertEqual(PortalLoginController.decodeBridgeResult("{\"kind\":\"code\",\"pending\":\"true\"}")["reason"] as? String,
                       "invalid_bridge_payload")
    }
}

@MainActor
private final class LoginPageDouble {
    var requests: [URLRequest] = []
    var submissions: [String] = []
    var reads = 0
    var verifications = 0
    var finishes = 0
    var dialogs: [UIAlertController] = []
    var result: [String: Any] = ["kind": "web", "reason": "login_form_missing"]
    var inspectionResults: [[String: Any]] = []
    var retryVerification = false
    var rawResult: Any?
    var nextResult: [String: Any] = ["kind": "code"]
    var submissionReply: [String: Any]?
    var onLoad: (@MainActor () -> Void)?
    var suspendedRead: (@MainActor () async -> [String: Any])?
    var suspendedSubmission: (@MainActor () async -> [String: Any])?
    var verify: @MainActor () async -> Bool = { false }
    var prepare: @MainActor () async -> Void = {}
}
