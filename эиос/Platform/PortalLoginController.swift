import Foundation
import SwiftUI
import WebKit
import UIKit
import Combine

enum PortalLoginForm: Equatable { case credentials, oneTimeCode }

@MainActor
struct PortalLoginDependencies {
    var prepare: @MainActor () async -> Void = { await NetworkManager.shared.browserWillOpen() }
    var verify: @MainActor () async -> Bool = { await NetworkManager.shared.checkBrowserLogin() }
    var canRetryVerification: @MainActor () -> Bool = { NetworkManager.shared.loginVerificationCanRetry }
    var finish: @MainActor () async -> Void = { await NetworkManager.shared.browserDidClose() }
    var loginError: @MainActor () -> String? = { NetworkManager.shared.errors["login"] }
    // Tests cross the SAME String -> JSON boundary as WebKit, not a dictionary shortcut.
    var evaluate: (@MainActor (String, [String: Any]) async throws -> Any?)?
    var load: (@MainActor (URLRequest) -> Void)?
    var websiteDataStore: WKWebsiteDataStore?
    var presentDialog: (@MainActor (UIAlertController) -> Void)?
    var inspectionAttempts = 40
    var inspectionInterval: UInt64 = 500_000_000
    var timeoutInterval: UInt64 = 25_000_000_000
    var verificationTimeoutInterval: UInt64 = 75_000_000_000
    var verificationRetryInterval: UInt64 = 2_000_000_000
}

@MainActor
final class PortalLoginController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var form: PortalLoginForm = .credentials
    @Published private(set) var formReady = false
    @Published private(set) var busy = true
    @Published private(set) var error: String?
    @Published private(set) var completed = false
    @Published private(set) var isAwaitingResult = false
    @Published private(set) var diagnosticText = "SmartTimetable login 2026-10-04 MAX v4\nЭтап: запуск"
    var isCheckingCode: Bool { busy && isAwaitingResult && pendingSubmission?.mode == "code" }
    let webView: WKWebView
    private let dependencies: PortalLoginDependencies
    private enum Phase { case preparation, document, submission, observation, verification }
    private struct Submission {
        let mode: String
        let document: Int
        let previousError: String?
        var responseRevision: Int
    }
    private var entered = false
    private var closed = false
    private var preparationFinished = false
    private var preparation: Task<Void, Never>?
    private var navigationGeneration = 0
    private var documentGeneration = 0
    private var timeout: Task<Void, Never>?
    private var inspection: Task<Void, Never>?
    private var inspectionID: UUID?
    private var verificationID: UUID?
    private var verifications: [UUID: Task<Void, Never>] = [:]
    private var pendingSubmission: Submission?
    private var responseRevision = 0
    private var submitting = false
    private var requestedURL: URL?
    private var httpStatus: Int?
    private var lastReason = "not_inspected"
    private var lastBridgeType = "not_received"
    private var policyCancellations = 0
    private var navigationFailure: Error?
    private var dialogs: [UUID: () -> Void] = [:]

    override convenience init() { self.init(dependencies: PortalLoginDependencies()) }
    init(dependencies: PortalLoginDependencies) {
        self.dependencies = dependencies
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dependencies.websiteDataStore ?? SessionStore.shared.websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }
    func start() async {
        guard !entered, !closed else { return }
        entered = true
        let prepare = dependencies.prepare
        preparation = Task { await prepare() }
        updateDiagnostic("Подготовка сессии")
        armTimeout(.preparation)
        await finishPreparation(token: navigationGeneration)
    }
    private func finishPreparation(token: Int) async {
        await preparation?.value
        preparationFinished = true
        guard !closed, !Task.isCancelled, token == navigationGeneration else { return }
        loadLoginPage()
    }
    func close() {
        guard !closed else { return }
        closed = true
        navigationGeneration += 1
        timeout?.cancel(); stopInspection(); stopVerification()
        let outstandingChecks = Array(verifications.values)
        outstandingChecks.forEach { $0.cancel() }
        // WebKit requires EVERY JS dialog completion, including when its view closes.
        let cancellations = Array(dialogs.values)
        dialogs.removeAll()
        cancellations.forEach { $0() }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        busy = false; formReady = false
        if entered {
            let prepare = preparation, finish = dependencies.finish
            Task {
                // No cookie capture while browserWillOpen / verification still writes cookies.
                await prepare?.value
                for check in outstandingChecks { await check.value }
                await finish()
            }
        }
    }
    func submit(username: String = "", password: String = "", code: String = "") async -> Bool {
        guard !closed, !busy, !completed else { return false }
        if isAwaitingResult { retryConnection(); return false }
        let current = form
        if !formReady {
            retryConnection()
            let deadline = Date().addingTimeInterval(Double(dependencies.timeoutInterval) / 1_000_000_000 + 1)
            while busy && Date() < deadline {
                if closed || Task.isCancelled { return false }
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return false }
            }
            guard !closed, !busy, formReady, form == current, !isAwaitingResult else { return false }
        }
        let mode = current == .credentials ? "credentials" : "code"
        pendingSubmission = Submission(mode: mode, document: documentGeneration,
                                       previousError: error, responseRevision: responseRevision)
        isAwaitingResult = true
        stopInspection()
        busy = true; error = nil; formReady = false; submitting = true; navigationFailure = nil
        let token = navigationGeneration
        lastReason = "submission_pending"
        updateDiagnostic(current == .credentials ? "Отправка логина" : "Отправка MAX")
        armTimeout(.submission)
        do {
            let result = try await runBridge(mode: mode, username: username, password: password, code: code)
            // A navigation can win the race with this reply. Its inspection owns the result.
            guard !closed, token == navigationGeneration else { return true }
            submitting = false
            if result["submitted"] as? Bool == true {
                if let revision = result["responseRevision"] as? Int { pendingSubmission?.responseRevision = revision }
                beginObservation()
                return true
            }
            if isBridgeFailure(result) {
                // The JS side might already have sent. Never infer 'not submitted'
                // from a broken transport reply and never replay the POST.
                lastReason = "submission_result_pending"
                beginObservation()
                return true
            }
            pendingSubmission = nil; isAwaitingResult = false
            apply(result)
            return false
        } catch {
            guard !closed, token == navigationGeneration else { return true }
            submitting = false
            lastReason = "submission_result_pending"
            beginObservation()
            return true
        }
    }
    /// A new MAX code after a rejected one. Allowed only while the site itself still shows the
    /// MAX code form (checked right now): then the previous code was not accepted and entering
    /// another one is exactly what the site expects. Credentials are never re-sent here.
    func retryCode(_ code: String) async -> Bool {
        guard !closed, !busy, !completed, form == .oneTimeCode, isAwaitingResult else { return false }
        guard let result = try? await runBridge(mode: "inspect"), !closed,
              result["kind"] as? String == "code", result["pending"] as? Bool != true else {
            retryConnection()
            return false
        }
        pendingSubmission = nil; isAwaitingResult = false; formReady = true
        responseRevision = (result["responseRevision"] as? Int) ?? responseRevision
        return await submit(code: code)
    }

    func retryConnection() {
        guard !closed, !busy, !completed else { return }
        if !preparationFinished {
            busy = true; error = nil
            let token = navigationGeneration
            armTimeout(.preparation)
            Task { await finishPreparation(token: token) }
        } else if isAwaitingResult || form == .oneTimeCode {
            // Includes a credentials POST with an unknown result: no new GET / MAX request.
            beginObservation()
        } else { loadLoginPage() }
    }
    func restartLogin() {
        guard !closed, !busy, !completed else { return }
        pendingSubmission = nil; isAwaitingResult = false; form = .credentials
        retryConnection() // Explicit user action; this is the only MAX-reset path.
    }
    private func loadLoginPage() {
        navigationGeneration += 1; documentGeneration += 1
        stopInspection(); stopVerification()
        webView.stopLoading()
        pendingSubmission = nil; isAwaitingResult = false; submitting = false; navigationFailure = nil
        busy = true; error = nil; formReady = false
        httpStatus = nil; lastReason = "not_inspected"; responseRevision = 0; lastBridgeType = "not_received"
        requestedURL = PortalConfiguration.loginURL
        var request = URLRequest(url: PortalConfiguration.loginURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = "GET"
        updateDiagnostic("Загрузка формы")
        armTimeout(.document)
        if let load = dependencies.load { load(request) }
        else { webView.load(request) }
    }
    private func runBridge(mode: String, username: String = "", password: String = "", code: String = "") async throws -> [String: Any] {
        let arguments: [String: Any] = ["mode": mode, "username": username, "password": password, "code": code]
        let result: Any?
        if let evaluate = dependencies.evaluate { result = try await evaluate(mode, arguments) }
        else {
            guard let url = webView.url, PortalConfiguration.allowsDataURL(url) else {
                return ["kind": "web", "reason": "unsupported_origin"]
            }
            // `in: .page` selects the callback API, whose immediate return is Void.
            // The async overload is spelled `contentWorld:`. Await that result.
            result = try await webView.callAsyncJavaScript(PortalLoginBridge.script, arguments: arguments, in: nil, contentWorld: .page)
        }
        return Self.decodeBridgeResult(result)
    }
    nonisolated static func decodeBridgeResult(_ result: Any?) -> [String: Any] {
        let wireType = bridgeValueKind(result)
        guard let string = result as? String, string.utf8.count <= 16_384,
              let data = string.data(using: .utf8) else {
            return ["kind": "web", "reason": "invalid_bridge_result", "wireType": wireType]
        }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: []),
              var dictionary = value as? [String: Any] else {
            return ["kind": "web", "reason": "invalid_bridge_json", "wireType": wireType]
        }
        guard let kind = dictionary["kind"] as? String,
              ["credentials", "code", "authenticated", "web"].contains(kind),
              dictionary["error"] == nil || dictionary["error"] is String,
              dictionary["pending"] == nil || dictionary["pending"] is Bool,
              dictionary["submitted"] == nil || dictionary["submitted"] is Bool else {
            return ["kind": "web", "reason": "invalid_bridge_payload", "wireType": wireType]
        }
        dictionary["wireType"] = wireType // Native-only type category, never a value/HTML dump.
        return dictionary
    }
    nonisolated private static func bridgeValueKind(_ value: Any?) -> String {
        guard let value = value else { return "nil" }
        if value is Void { return "void" }
        if value is NSNull { return "null" }
        if value is String { return "string" }
        if value is NSNumber { return "number" }
        if value is [String: Any] { return "object" }
        if value is [Any] { return "array" }
        return "other"
    }
    private func isBridgeFailure(_ result: [String: Any]) -> Bool {
        ["invalid_bridge_result", "invalid_bridge_json", "invalid_bridge_payload"].contains(result["reason"] as? String ?? "")
    }
    private func stopInspection() {
        inspection?.cancel(); inspection = nil; inspectionID = nil
    }
    private func stopVerification() {
        if let id = verificationID { verifications[id]?.cancel() }
        verificationID = nil
    }
    private func beginObservation() {
        guard !closed, !completed else { return }
        busy = true; error = nil; formReady = false; submitting = false
        updateDiagnostic("Проверка результата")
        armTimeout(.observation)
        beginInspection()
    }
    private func beginInspection() {
        guard !closed, busy, !completed, !submitting, verificationID == nil else { return }
        stopInspection()
        let token = navigationGeneration, id = UUID()
        inspectionID = id
        inspection = Task { [weak self] in
            guard let self = self else { return }
            defer { if self.inspectionID == id { self.inspection = nil; self.inspectionID = nil } }
            await self.inspect(token: token)
        }
    }
    private func inspect(token: Int) async {
        var lastMessage = ""
        for attempt in 0..<dependencies.inspectionAttempts {
            guard !closed, !Task.isCancelled, token == navigationGeneration else { return }
            do {
                let result = try await runBridge(mode: "inspect")
                guard !closed, !Task.isCancelled, token == navigationGeneration else { return }
                recordReason(result)
                let kind = result["kind"] as? String
                let message = (result["error"] as? String) ?? ""
                if !message.isEmpty { lastMessage = message }
                updateDiagnostic("Проверка формы")
                if kind == "authenticated" { beginVerification(); return }
                if isBridgeFailure(result) { pause(formPreparationError()); return }
                if lastReason == "max_form_changed" || lastReason == "code_form_changed" || lastReason == "code_form_missing" {
                    form = .oneTimeCode
                    // MAX replaces/disables its controls while mounting and checking.
                    // Inspect again within the bounded observation budget. Submission
                    // still requires the complete, validated form in the JS adapter.
                }
                if kind == "credentials" || kind == "code" {
                    var observedResponse = result["pending"] as? Bool != true
                    if let pending = pendingSubmission {
                        observedResponse = observedResponse && (kind != pending.mode ||
                            (!message.isEmpty && (message != pending.previousError || documentGeneration != pending.document)) ||
                            ((result["responseRevision"] as? Int) ?? 0) > pending.responseRevision)
                    }
                    if observedResponse { apply(result); return }
                }
            } catch {
                if Task.isCancelled || closed || token != navigationGeneration { return }
                lastReason = "javascript_read_failed"
                updateDiagnostic("Ожидание документа")
            }
            if attempt + 1 < dependencies.inspectionAttempts {
                do { try await Task.sleep(nanoseconds: dependencies.inspectionInterval) } catch { return }
            }
        }
        guard !closed, !Task.isCancelled, token == navigationGeneration else { return }
        if let failure = navigationFailure {
            pause(PortalErrorMessage.message(for: failure))
        } else if pendingSubmission != nil {
            lastReason = "submission_result_pending"
            pause("Результат отправки пока неизвестен. Нажмите «Проверить результат»; пароль или код повторно не отправятся.")
        } else { pause(lastMessage.isEmpty ? formPreparationError() : lastMessage) }
    }
    private func beginVerification() {
        stopInspection(); stopVerification()
        isAwaitingResult = true
        let token = navigationGeneration, id = UUID()
        verificationID = id
        lastReason = "verification_pending"
        updateDiagnostic("Проверка аккаунта")
        armTimeout(.verification) // Separate budget: form/POST time is not charged here.
        verifications[id] = Task { [weak self] in
            guard let self = self else { return }
            defer { self.verifications.removeValue(forKey: id) }
            var success = false
            // A redirect can finish just before the account endpoint sees the updated
            // session. Retry only this read-only check, at most once, never either POST.
            for attempt in 0..<2 {
                success = await self.dependencies.verify()
                guard !self.closed, !Task.isCancelled, token == self.navigationGeneration, self.verificationID == id else { return }
                if success || attempt == 1 || !self.dependencies.canRetryVerification() { break }
                self.lastReason = "verification_settling"
                self.updateDiagnostic("Ожидание подтверждения сессии")
                do { try await Task.sleep(nanoseconds: self.dependencies.verificationRetryInterval) } catch { return }
            }
            guard !self.closed, !Task.isCancelled, token == self.navigationGeneration, self.verificationID == id else { return }
            self.verificationID = nil
            if success {
                self.timeout?.cancel(); self.completed = true; self.busy = false
                self.pendingSubmission = nil; self.isAwaitingResult = false
                self.error = nil; self.navigationFailure = nil
                self.lastReason = "authenticated"
                self.updateDiagnostic("Вход подтверждён")
            } else {
                self.lastReason = "verification_failed"
                self.pause(self.dependencies.loginError() ?? "Не удалось подтвердить сессию. Нажмите «Проверить результат».")
            }
        }
    }
    private func apply(_ result: [String: Any]) {
        timeout?.cancel(); busy = false; submitting = false
        pendingSubmission = nil; isAwaitingResult = false; navigationFailure = nil
        responseRevision = (result["responseRevision"] as? Int) ?? 0
        recordReason(result)
        error = (result["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch result["kind"] as? String {
        case "credentials": form = .credentials; formReady = true
        case "code": form = .oneTimeCode; formReady = true
        default:
            formReady = false
            if error == nil { error = formPreparationError() }
        }
        updateDiagnostic(formReady ? "Форма готова" : "Форма не распознана")
    }
    private func recordReason(_ result: [String: Any]) {
        let types: Set<String> = ["nil", "void", "null", "string", "number", "object", "array", "other"]
        if let type = result["wireType"] as? String, types.contains(type) { lastBridgeType = type }
        let known: Set<String> = ["unsupported_origin", "login_form_missing", "login_fields_changed",
            "login_token_missing", "login_button_unavailable", "login_fields_unavailable",
            "additional_login_fields", "interactive_challenge", "login_action_changed",
            "code_form_missing", "code_form_changed", "max_form_changed", "unsafe_form_action",
            "unsupported_page", "invalid_bridge_result", "invalid_bridge_json", "invalid_bridge_payload"]
        if let reason = result["reason"] as? String, known.contains(reason) { lastReason = reason }
        else if let kind = result["kind"] as? String, ["credentials", "code", "authenticated"].contains(kind) { lastReason = kind }
        else { lastReason = "unknown_form" }
    }
    private func formPreparationError() -> String {
        switch lastReason {
        case "invalid_bridge_result", "invalid_bridge_json", "invalid_bridge_payload":
            return "Не удалось прочитать ответ формы входа. Скопируйте диагностику."
        case "unsupported_origin", "unsupported_page":
            return "ЭИОС открыла другую страницу входа. Скопируйте диагностику."
        case "max_form_changed", "code_form_missing", "code_form_changed":
            return "Форма MAX не распознана. Нажмите «Проверить форму MAX»; повторять пароль не нужно."
        case "interactive_challenge", "additional_login_fields":
            return "ЭИОС требует дополнительное поле или проверку. Скопируйте диагностику."
        case "unsafe_form_action", "login_action_changed":
            return "Изменился адрес отправки формы. Данные не отправлены. Скопируйте диагностику."
        default:
            return "Форма входа не готова. Можно повторить проверку или скопировать диагностику."
        }
    }
    private func pause(_ message: String) {
        navigationGeneration += 1
        timeout?.cancel(); stopInspection(); stopVerification()
        busy = false; formReady = false; submitting = false; error = message
        updateDiagnostic("Остановлено")
    }
    private func armTimeout(_ phase: Phase) {
        timeout?.cancel()
        let interval = phase == .verification ? dependencies.verificationTimeoutInterval : dependencies.timeoutInterval
        let token = navigationGeneration
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: interval) } catch { return }
            guard let self = self, !self.closed, self.busy, token == self.navigationGeneration else { return }
            switch phase {
            case .submission:
                // JS may have sent a POST before losing its callback. Read the current
                // document FIRST and keep the MAX challenge, including late transitions.
                self.navigationGeneration += 1
                self.submitting = false
                self.lastReason = "submission_timeout"
                self.beginObservation()
            case .verification:
                self.lastReason = "verification_timeout"
                self.pause("Проверка аккаунта задерживается. Нажмите «Проверить результат» без повторной отправки данных.")
            case .observation where self.isAwaitingResult:
                self.lastReason = "submission_result_pending"
                self.pause(self.navigationFailure.map { PortalErrorMessage.message(for: $0) }
                           ?? "Результат отправки пока неизвестен. Нажмите «Проверить результат».")
            case .preparation:
                self.lastReason = "session_preparation_timeout"
                self.pause("Подготовка сессии задерживается. Повторите проверку.")
            default:
                self.lastReason = "document_timeout"
                self.pause("Ответ ЭИОС задерживается. Повторите проверку формы.")
            }
        }
    }
    private func updateDiagnostic(_ phase: String) {
        let url = webView.url ?? requestedURL
        let knownPaths = ["/login/index.php", "/local/loginwait/wait.php", "/wait.php", "/my/", "/", "/blocks/buttons/academic_progress.php"]
        let host = url.flatMap { PortalConfiguration.allowsBrowserURL($0) ? $0.host : nil } ?? "[неизвестно]"
        let path = url.flatMap { knownPaths.contains($0.path) ? $0.path : nil } ?? "/[другой путь]"
        diagnosticText = "SmartTimetable login 2026-10-04 MAX v4\nЭтап: \(phase)\nСтраница: \(host)\(path)\nHTTP: \(httpStatus.map(String.init) ?? "—")\nПричина: \(lastReason)\nОтвет JS: \(lastBridgeType)"
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !closed, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" || PortalConfiguration.allowsBrowserURL(url) { decisionHandler(.allow); return }
        if navigationAction.targetFrame?.isMainFrame != false {
            policyCancellations += 1
            lastReason = "unsupported_origin"
            pause("ЭИОС запросила неподдерживаемый адрес входа. Данные не отправлены.")
        }
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard !closed else { decisionHandler(.cancel); return }
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
           !acceptHTTPStatus(response.statusCode) { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    // Shared by the delegate and controller tests (WKNavigationResponse has no public factory).
    func acceptHTTPStatus(_ status: Int) -> Bool {
        guard !closed, busy else { return false }
        httpStatus = status
        if status >= 400 {
            policyCancellations += 1
            lastReason = "http_error"
            pause("Сервер ЭИОС вернул ошибку HTTP \(status). Повторите проверку позже.")
            return false
        }
        updateDiagnostic("Получен ответ")
        return true
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !closed, !completed else { return }
        navigationGeneration += 1; documentGeneration += 1
        stopInspection(); stopVerification()
        submitting = false; busy = true; error = nil; formReady = false; navigationFailure = nil
        httpStatus = nil; lastReason = pendingSubmission == nil ? "not_inspected" : "submission_pending"
        updateDiagnostic("Переход")
        armTimeout(pendingSubmission == nil ? .document : .observation)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if busy && !formReady && inspection == nil { beginInspection() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if busy && !formReady && inspection == nil { beginInspection() }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    private func fail(_ error: Error) {
        let failure = error as NSError
        if failure.domain == "WebKitErrorDomain", failure.code == 102, policyCancellations > 0 {
            policyCancellations -= 1
            return // Preserve the actual HTTP/policy diagnosis, even after a retry began.
        }
        guard !closed, busy, !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return }
        lastReason = "navigation_error_\(failure.code)"
        if navigationFailure == nil, RefreshPolicy.isTransient(error),
           pendingSubmission != nil || form == .oneTimeCode {
            navigationFailure = error
            // The challenge may already have rendered before a redirect failed.
            // Read that document once within the normal budget; do not reload it.
            beginObservation()
        } else { pause(PortalErrorMessage.message(for: error)) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !closed else { return }
        lastReason = "web_process_terminated"
        pause("Процесс формы остановился. Если повторная проверка не поможет, нажмите «Начать вход заново».")
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if !closed, navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           PortalConfiguration.allowsBrowserURL(url) { webView.load(navigationAction.request) }
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        showAlert(message: message, completion: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        showConfirm(message: message, completion: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        showPrompt(message: prompt, defaultText: defaultText, completion: completionHandler)
    }
    func showAlert(message: String, completion: @escaping () -> Void) {
        let reply = LoginDialogReply<Bool> { _ in completion() }, id = UUID()
        let alert = UIAlertController(title: "ЭИОС", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "ОК", style: .default) { [weak self] _ in
            self?.dialogs.removeValue(forKey: id); reply.resolve(true)
        })
        present(alert, id: id) { reply.resolve(true) }
    }
    func showConfirm(message: String, completion: @escaping (Bool) -> Void) {
        let reply = LoginDialogReply(completion), id = UUID()
        let alert = UIAlertController(title: "ЭИОС", message: message, preferredStyle: .alert)
        for (title, value) in [("Отмена", false), ("ОК", true)] {
            alert.addAction(UIAlertAction(title: title, style: value ? .default : .cancel) { [weak self] _ in
                self?.dialogs.removeValue(forKey: id); reply.resolve(value)
            })
        }
        present(alert, id: id) { reply.resolve(false) }
    }
    func showPrompt(message: String, defaultText: String?, completion: @escaping (String?) -> Void) {
        let reply = LoginDialogReply(completion), id = UUID()
        let alert = UIAlertController(title: "ЭИОС", message: message, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { [weak self] _ in
            self?.dialogs.removeValue(forKey: id); reply.resolve(nil)
        })
        alert.addAction(UIAlertAction(title: "ОК", style: .default) { [weak self, weak alert] _ in
            self?.dialogs.removeValue(forKey: id); reply.resolve(alert?.textFields?.first?.text)
        })
        present(alert, id: id) { reply.resolve(nil) }
    }
    private func present(_ alert: UIAlertController, id: UUID, cancel: @escaping () -> Void) {
        guard !closed else { cancel(); return }
        let display: (UIAlertController) -> Void
        if let injected = dependencies.presentDialog { display = injected }
        else if let presenter = presenter() { display = { presenter.present($0, animated: true) } }
        else { cancel(); return }
        dialogs[id] = { [weak alert] in cancel(); alert?.dismiss(animated: false) }
        display(alert)
    }
    private func presenter() -> UIViewController? {
        var controller = webView.window?.rootViewController
        while let next = controller?.presentedViewController { controller = next }
        return controller
    }
}

@MainActor
final class LoginDialogReply<Value> {
    private var completion: ((Value) -> Void)?
    init(_ completion: @escaping (Value) -> Void) { self.completion = completion }
    func resolve(_ value: Value) {
        let handler = completion
        completion = nil
        handler?(value)
    }
}
