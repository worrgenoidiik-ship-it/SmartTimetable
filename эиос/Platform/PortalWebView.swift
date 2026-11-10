import SwiftUI
import WebKit
import UIKit
import Combine

struct PortalDestination: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
}

@MainActor
final class PortalWebState: ObservableObject {
    @Published var loading = true
    @Published var error: String?
    @Published var canGoBack = false
    weak var webView: WKWebView?
    var lastLoginCheck = Date.distantPast
    var closed = false

    /// The rendered page (after the site's JavaScript ran) as an .html file, offered through
    /// the share sheet: this is how the page source can be sent from an iPhone.
    func exportHTML() {
        guard let webView = webView else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] value, _ in
            Task { @MainActor in
                guard let self = self, let html = value as? String, let webView = self.webView else { return }
                let name = (webView.url?.path ?? "page").split(separator: "/").suffix(2).joined(separator: "_")
                    .replacingOccurrences(of: ".php", with: "")
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent((name.isEmpty ? "page" : name) + ".html")
                do { try Data(html.utf8).write(to: file, options: .atomic) }
                catch { self.error = "Не удалось сохранить страницу."; return }
                var presenter = webView.window?.rootViewController
                while let next = presenter?.presentedViewController { presenter = next }
                let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                share.popoverPresentationController?.sourceView = webView
                presenter?.present(share, animated: true)
            }
        }
    }
}

@MainActor
struct PortalBrowserScreen: View {
    let title: String
    let url: URL
    var isLogin = false
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var network = NetworkManager.shared
    @StateObject private var web = PortalWebState()
    @ObservedObject private var auth = AppAuthManager.shared
    @State private var ready = false
    @State private var entered = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if web.loading { ProgressView().padding(6) }
                if let error = web.error {
                    Text(error).font(.caption).foregroundColor(.red).padding(8)
                }
                if isLogin, let error = network.errors["login"] {
                    Text(error).font(.caption).foregroundColor(.secondary).padding(8)
                }
                if ready { PortalWebView(url: url, isLogin: isLogin, state: web) }
                else { Spacer(); ProgressView("Подготовка сессии…"); Spacer() }
                if isLogin {
                    Button(network.isCheckingLogin ? "Проверяем вход…" : "Я вошёл — продолжить") {
                        Task { if await network.checkBrowserLogin() { dismiss() } }
                    }.buttonStyle(.borderedProminent).disabled(network.isCheckingLogin || !ready).padding()
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { web.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!web.canGoBack).accessibilityLabel("Назад на сайте")
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !isLogin {
                        Menu {
                            Button { web.webView?.reload() } label: { Label("Обновить страницу", systemImage: "arrow.clockwise") }
                            Button {
                                // Safari has its own cookies: the user may need to sign in there again.
                                if let current = web.webView?.url ?? Optional(url) { UIApplication.shared.open(current) }
                            } label: { Label("Открыть в Safari", systemImage: "safari") }
                            Button { web.exportHTML() } label: {
                                Label("Сохранить код страницы (HTML)", systemImage: "doc.text")
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .accessibilityLabel("Действия со страницей")
                    }
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        // A swipe down must not close a quiz or an unsent message by accident.
        .interactiveDismissDisabled(!isLogin)
        .overlay { LockOverlay() }
        .task {
            guard !entered else { return }
            entered = true
            await network.browserWillOpen()
            if !Task.isCancelled { ready = true }
        }
        .onDisappear {
            web.closed = true
            if entered { Task { await network.browserDidClose() } }
        }
    }
}

@MainActor
private struct PortalWebView: UIViewRepresentable {
    let url: URL
    let isLogin: Bool
    @ObservedObject var state: PortalWebState

    func makeCoordinator() -> Coordinator { Coordinator(state: state, isLogin: isLogin) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = SessionStore.shared.websiteDataStore
        if !isLogin {
            // Course activities (tests, assignments, files, forums) look like part of the app:
            // the site's header, side drawer, blocks and footer are hidden; the content and all
            // of its controls stay, so tests are still taken and saved by ЭИОС itself.
            let css = """
            nav.navbar, .navbar.fixed-top, #nav-drawer, [data-region="drawer"], #page-header .breadcrumbs, #page-footer,
            footer, #block-region-side-pre, #block-region-side-post, [data-region="blocks-column"], .block-region,
            .message-drawer, [data-region="message-drawer"], #customAlert, .customAlert, .btn-footer-popover,
            #goto-top-link, .drawer-toggle, .skip-block { display: none !important; }
            body, #page, #page-wrapper { padding-top: 0 !important; margin-top: 0 !important; margin-left: 0 !important; }
            #region-main, #region-main-box { padding: 10px !important; border: none !important; box-shadow: none !important; }
            #page-header .page-title h1, .page-header-headings h1 { font-size: 1.3rem !important; }
            """
            let script = "var s=document.createElement('style');s.textContent=`\(css)`;document.documentElement.appendChild(s);"
            configuration.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        state.webView = view
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Never reload a quiz due to a SwiftUI redraw or a keep-alive tick.
    }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading(); uiView.navigationDelegate = nil; uiView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let state: PortalWebState
        let isLogin: Bool
        private var downloads: [ObjectIdentifier: URL] = [:]
        init(state: PortalWebState, isLogin: Bool) { self.state = state; self.isLogin = isLogin }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if url.absoluteString == "about:blank" || PortalConfiguration.allowsBrowserURL(url) {
                decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow); return
            }
            if navigationAction.navigationType == .linkActivated,
               ["https", "mailto", "tel", "max", "tg"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            } else if navigationAction.targetFrame?.isMainFrame != false {
                state.error = "Переход вне сайта университета остановлен. Откройте внешнюю ссылку нажатием."
            }
            decisionHandler(.cancel)
        }
        // Course files sent as attachments (pluginfile.php?forcedownload=1, archives, documents)
        // cannot be shown by WebKit: download them and offer the system share sheet.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let disposition = (navigationResponse.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            let attachment = navigationResponse.isForMainFrame && disposition.hasPrefix("attachment")
            decisionHandler(navigationResponse.canShowMIMEType && !attachment ? .allow : .download)
        }
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }
        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                      completionHandler: @escaping (URL?) -> Void) {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = (suggestedFilename as NSString).lastPathComponent
            let target = folder.appendingPathComponent(name.isEmpty ? "file" : name)
            try? FileManager.default.removeItem(at: target)
            downloads[ObjectIdentifier(download)] = target
            state.loading = true
            completionHandler(target)
        }
        func downloadDidFinish(_ download: WKDownload) {
            state.loading = false
            guard let file = downloads.removeValue(forKey: ObjectIdentifier(download)),
                  let webView = state.webView, let presenter = presenter(webView) else { return }
            let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = webView
            presenter.present(share, animated: true)
        }
        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            downloads.removeValue(forKey: ObjectIdentifier(download))
            state.loading = false
            state.error = "Не удалось скачать файл. " + PortalErrorMessage.message(for: error)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.loading = true; state.error = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !state.closed else { return }
            state.loading = false; state.canGoBack = webView.canGoBack
            if isLogin, let url = webView.url, PortalConfiguration.allowsDataURL(url),
               !PortalConfiguration.isAuthenticationURL(url), Date().timeIntervalSince(state.lastLoginCheck) > 3 {
                state.lastLoginCheck = Date()
                Task { _ = await NetworkManager.shared.checkBrowserLogin() }
            } else if let url = webView.url, PortalConfiguration.isAuthenticationURL(url) {
                // A sign-in page carries an anonymous session: copying it would replace
                // the app's working cookies with ones that are not logged in.
                if !isLogin { SessionJournal.add("Встроенный браузер попал на страницу входа: \(SessionJournal.place(url))") }
            } else {
                Task {
                    do { try await SessionStore.shared.captureWebSession() }
                    catch { if !state.closed { state.error = PortalErrorMessage.message(for: error) } }
                }
                // Pages the app shows natively are read from the rendered DOM as well: this works
                // even when the plain HTTP answer lacks data the site's JavaScript adds.
                if let url = webView.url, NetworkManager.shared.isNativelyShown(url) {
                    webView.evaluateJavaScript("document.documentElement.outerHTML") { value, _ in
                        guard let html = value as? String else { return }
                        Task { @MainActor in NetworkManager.shared.importRenderedPortalPage(html: html, url: url) }
                    }
                }
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
        private func fail(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            state.loading = false; state.error = PortalErrorMessage.message(for: error)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
               PortalConfiguration.allowsBrowserURL(url) { webView.load(navigationAction.request) }
            return nil
        }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            guard let presenter = presenter(webView) else { completionHandler(); return }
            let alert = UIAlertController(title: "ЭИОС", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "ОК", style: .default) { _ in completionHandler() })
            presenter.present(alert, animated: true)
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            guard let presenter = presenter(webView) else { completionHandler(false); return }
            let alert = UIAlertController(title: "ЭИОС", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "Продолжить", style: .default) { _ in completionHandler(true) })
            presenter.present(alert, animated: true)
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            guard let presenter = presenter(webView) else { completionHandler(nil); return }
            let alert = UIAlertController(title: "ЭИОС", message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "ОК", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
            presenter.present(alert, animated: true)
        }
        private func presenter(_ webView: WKWebView) -> UIViewController? {
            var result = webView.window?.rootViewController
            while let next = result?.presentedViewController { result = next }
            return result
        }
    }
}
