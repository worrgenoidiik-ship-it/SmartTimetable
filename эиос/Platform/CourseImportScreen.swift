import SwiftUI
import WebKit
import Combine

enum PortalImportKind: Equatable {
    case courses, notifications
    var url: URL { self == .courses ? PortalConfiguration.coursesURL : PortalConfiguration.notificationsURL }
    var title: String { self == .courses ? "Мои курсы" : "Уведомления" }
    var symbol: String { self == .courses ? "books.vertical.fill" : "bell.badge.fill" }
}

/// Reads rendered content with the existing session. Never submits forms or opens a quiz.
@MainActor
struct CourseImportScreen: View {
    @StateObject private var importer: PortalCourseImporter
    private let kind: PortalImportKind
    init(kind: PortalImportKind = .courses) {
        self.kind = kind
        _importer = StateObject(wrappedValue: PortalCourseImporter(kind: kind))
    }
    @ObservedObject private var auth = AppAuthManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                CourseImportSurface(importer: importer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false).accessibilityHidden(true)
                VStack(spacing: 20) {
                    Image(systemName: kind.symbol).font(.system(size: 44)).foregroundColor(.accentColor)
                    Text(kind.title).font(.title.bold())
                    if importer.busy {
                        ProgressView("Загружаем данные ЭИОС…")
                    } else if let error = importer.error {
                        Text(error).multilineTextAlignment(.center).foregroundColor(.secondary)
                        Button("Повторить") { importer.retry() }.buttonStyle(.borderedProminent)
                    }
                    Text("Сохранённые данные останутся доступны без интернета.")
                        .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.appBackground.ignoresSafeArea())
            }
            .navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Закрыть") { dismiss() } } }
        }
        .overlay { if auth.isLocked { AppLockScreen() } }
        .task { await importer.start() }
        .onChange(of: importer.completed) { _, completed in if completed { dismiss() } }
        .onDisappear { importer.close() }
    }
}

@MainActor
private struct CourseImportSurface: UIViewRepresentable {
    let importer: PortalCourseImporter
    func makeUIView(context: Context) -> WKWebView { importer.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
private final class PortalCourseImporter: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var busy = true
    @Published private(set) var completed = false
    @Published private(set) var error: String?
    let webView: WKWebView
    private let kind: PortalImportKind
    private var account: String?
    private var sessionGeneration = 0
    private var entered = false
    private var closed = false
    private var generation = 0
    private var inspection: Task<Void, Never>?
    private var timeout: Task<Void, Never>?

    init(kind: PortalImportKind) {
        self.kind = kind
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = SessionStore.shared.websiteDataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func start() async {
        guard !entered, !closed else { return }
        entered = true
        account = NetworkManager.shared.snapshot.profile?.accountKey
        sessionGeneration = NetworkManager.shared.sessionGeneration
        await NetworkManager.shared.browserWillOpen()
        guard !closed, !Task.isCancelled else { return }
        retry()
    }

    func retry() {
        guard entered, !closed, !completed else { return }
        generation += 1
        inspection?.cancel(); timeout?.cancel(); webView.stopLoading()
        guard account != nil, sessionGeneration == NetworkManager.shared.sessionGeneration else {
            fail(PortalFailure.loginRequired); return
        }
        busy = true; error = nil
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
            self?.fail(URLError(.timedOut))
        }
        webView.load(URLRequest(url: kind.url, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    func close() {
        guard !closed else { return }
        closed = true; generation += 1
        inspection?.cancel(); timeout?.cancel(); webView.stopLoading()
        webView.navigationDelegate = nil
        if entered { Task { await NetworkManager.shared.browserDidClose(refreshAfterClose: false) } }
    }

    private func fail(_ failure: Error) {
        guard !closed else { return }
        inspection?.cancel(); timeout?.cancel(); webView.stopLoading()
        busy = false
        error = NetworkManager.shared.message(for: failure, section: kind == .courses ? "courses" : "notifications")
        switch kind {
        case .courses: NetworkManager.shared.recordCourseImportFailure(failure, account: account, generation: sessionGeneration)
        case .notifications: NetworkManager.shared.recordNotificationImportFailure(failure, account: account, generation: sessionGeneration)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.cancel); return
        }
        guard let url = navigationAction.request.url, PortalConfiguration.allowsDataURL(url),
              !PortalConfiguration.isAuthenticationURL(url) else {
            decisionHandler(.cancel); fail(PortalFailure.loginRequired); return
        }
        // Only the selected content page, without hidden SSO or confirmation forms.
        guard url.path == kind.url.path,
              navigationAction.request.httpMethod == "GET" else {
            decisionHandler(.cancel); fail(PortalFailure.invalidURL); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        generation += 1; inspection?.cancel()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed, busy, let account = account, let source = webView.url else { return }
        let token = generation
        inspection?.cancel()
        inspection = Task { [weak self] in
            guard let self = self else { return }
            var lastError: Error = PortalFailure.unrecognized("данные после загрузки страницы")
            // Read repeatedly while Moodle inserts cards. Do not click pagination or
            // mistake a temporarily empty container for an authoritative empty list.
            for attempt in 0..<20 {
                guard !Task.isCancelled, !self.closed, token == self.generation else { return }
                do {
                    let value = try await self.webView.callAsyncJavaScript(
                        "if (location.href !== expectedURL) return ''; const html = document.documentElement.outerHTML; return html.length < 8000000 ? html : '';",
                        arguments: ["expectedURL": source.absoluteString], in: nil, contentWorld: .page)
                    guard !Task.isCancelled, !self.closed, token == self.generation else { return }
                    guard let html = value as? String, !html.isEmpty, html.utf8.count < 8_000_000 else {
                        throw PortalFailure.invalidResponse
                    }
                    switch self.kind {
                    case .courses:
                        try NetworkManager.shared.importRenderedCourses(html: html, source: source, account: account, generation: self.sessionGeneration)
                    case .notifications:
                        try NetworkManager.shared.importRenderedNotifications(html: html, source: source, account: account, generation: self.sessionGeneration)
                    }
                    self.timeout?.cancel(); self.busy = false; self.completed = true
                    return
                } catch {
                    lastError = error
                    if error is CancellationError { break }
                    if let failure = error as? PortalFailure, case .loginRequired = failure { break }
                }
                if attempt < 19 {
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                }
            }
            guard !Task.isCancelled, !self.closed, token == self.generation else { return }
            self.fail(lastError)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadFailed(error) }
    private func loadFailed(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { fail(error) }
    }
}
