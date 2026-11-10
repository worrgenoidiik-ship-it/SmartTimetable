import SwiftUI
import WebKit
import UIKit

@MainActor
struct NativeLoginScreen: View {
    let isChristmas: Bool
    var allowsClose = false
    @StateObject private var login = PortalLoginController()
    @ObservedObject private var auth = AppAuthManager.shared
    @ObservedObject private var network = NetworkManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var showsPassword = false
    @State private var copiedDiagnostic = false
    @State private var rememberLogin = CredentialVault.isEnabled
    // Saved login is filled in and submitted once per appearance; a changed password
    // therefore stops at the error instead of retrying in a loop.
    @State private var autoSubmitPending = false
    @State private var sentCredentials: CredentialVault.Credentials?
    @State private var showWebLogin = false
    @FocusState private var focused: Field?
    private enum Field: Hashable { case username, password, code }
    private var accent: Color { Color.themeAccent(isChristmas: isChristmas) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                LoginWebSurface(controller: login)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                // Keep the real page behind the native fields for its own scripts.
                nativeForm.background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if allowsClose {
                    ToolbarItem(placement: .navigationBarTrailing) { Button("Закрыть") { dismiss() } }
                }
                // The code keyboard has no return key and covers «Подтвердить».
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") { focused = nil }.font(.body.weight(.semibold))
                }
            }
        }
        .tint(accent)
        .overlay { if allowsClose { LockOverlay() } }
        .task {
            if let saved = CredentialVault.load() {
                username = saved.username; password = saved.password
                // One automatic attempt per 15 minutes for the whole app: every attempt makes the
                // portal send a new MAX code and invalidates the previous one.
                autoSubmitPending = CredentialVault.claimAutoSubmit()
            }
            await login.start()
        }
        .onChange(of: canSubmit) { _, ready in
            guard ready, autoSubmitPending, login.form == .credentials else { return }
            autoSubmitPending = false
            submit()
        }
        .onDisappear { password = ""; code = ""; login.close() }
        .onChange(of: login.form) { _, form in
            if form != .credentials { password = "" }
            code = ""
            if form == .oneTimeCode { focused = .code }
        }
        .sheet(isPresented: $showWebLogin, onDismiss: {
            if NetworkManager.shared.canOpenApp && allowsClose { dismiss() }
        }) {
            PortalBrowserScreen(title: "Вход в ЭИОС", url: PortalConfiguration.loginURL, isLogin: true)
        }
        .onChange(of: login.completed) { _, done in
            guard done else { return }
            // Saved only after the portal confirmed the account.
            if rememberLogin, let sent = sentCredentials {
                CredentialVault.save(sent)
                // A long-lived token from the same login: the next idle timeout no longer
                // ends in the login screen and a MAX code.
                Task { await NetworkManager.shared.obtainMobileToken(username: sent.username, password: sent.password) }
            }
            sentCredentials = nil
            if allowsClose { dismiss() }
        }
    }

    private var nativeForm: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 28).fill(accent.opacity(0.12)).frame(width: 100, height: 100)
                        Image(systemName: login.form == .oneTimeCode ? "lock.shield.fill" : "calendar.badge.clock")
                            .font(.system(size: 43, weight: .semibold)).foregroundColor(accent)
                    }
                    Text("SmartTimetable").font(.system(size: 36, weight: .black, design: .rounded))
                    Text(login.form == .oneTimeCode ? "Подтвердите вход" : "Вся учёба — под рукой")
                        .font(.title3.weight(.medium)).foregroundColor(.secondary)
                }.padding(.top, 24)
                VStack(alignment: .leading, spacing: 18) {
                    if login.form == .oneTimeCode {
                        Text("Код из MAX").font(.headline)
                        Text(login.isCheckingCode
                             ? "Проверяем код. Обычно это занимает 3–5 секунд. Дождитесь ответа ЭИОС."
                             : "Введите шесть цифр из сообщения университета.")
                            .font(.subheadline).foregroundColor(.secondary)
                        TextField("000000", text: $code)
                            .font(.system(size: 32, weight: .semibold, design: .monospaced))
                            .tracking(8).multilineTextAlignment(.center)
                            .keyboardType(.numberPad).textContentType(.oneTimeCode)
                            .focused($focused, equals: .code)
                            .padding(18).background(fieldBackground, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("Шестизначный код подтверждения")
                            .disabled(login.busy)
                            .onChange(of: code) { _, value in code = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6)) }
                    } else {
                        Text("Вход в аккаунт").font(.title2.bold())
                        Text("Используйте логин и пароль ЭИОС.").font(.subheadline).foregroundColor(.secondary)
                        HStack(spacing: 12) {
                            Image(systemName: "person").foregroundColor(.secondary)
                            TextField("Логин", text: $username)
                                .textContentType(.username).textInputAutocapitalization(.never)
                                .autocorrectionDisabled().focused($focused, equals: .username)
                                .accessibilityIdentifier("login.username")
                                .submitLabel(.next).onSubmit { focused = .password }
                        }.padding(16).background(fieldBackground, in: RoundedRectangle(cornerRadius: 14))
                        HStack(spacing: 12) {
                            Image(systemName: "lock").foregroundColor(.secondary)
                            Group {
                                if showsPassword { TextField("Пароль", text: $password) }
                                else { SecureField("Пароль", text: $password) }
                            }.textContentType(.password).textInputAutocapitalization(.never)
                                .autocorrectionDisabled().focused($focused, equals: .password)
                                .submitLabel(.go).onSubmit { submit() }
                            Button { showsPassword.toggle() } label: {
                                Image(systemName: showsPassword ? "eye.slash" : "eye").foregroundColor(.secondary)
                            }.accessibilityLabel(showsPassword ? "Скрыть пароль" : "Показать пароль")
                        }.padding(16).background(fieldBackground, in: RoundedRectangle(cornerRadius: 14))
                        Toggle(isOn: $rememberLogin) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Входить автоматически").font(.subheadline.weight(.medium))
                                Text("Когда ЭИОС завершит сессию, приложение войдёт само. Код MAX не сохраняется.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .onChange(of: rememberLogin) { _, value in CredentialVault.isEnabled = value }
                    }
                    if let error = login.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 12) {
                            Button(login.isAwaitingResult ? "Проверить результат" :
                                   (login.form == .oneTimeCode ? "Проверить форму MAX" : "Обновить форму")) {
                                copiedDiagnostic = false
                                login.retryConnection()
                            }.disabled(login.busy)
                            if login.form == .oneTimeCode || login.isAwaitingResult {
                                Button("Начать вход заново", role: .destructive) {
                                    password = ""; code = ""; copiedDiagnostic = false
                                    login.restartLogin()
                                }.disabled(login.busy)
                            }
                            Button(copiedDiagnostic ? "Диагностика скопирована" : "Скопировать диагностику") {
                                UIPasteboard.general.string = login.diagnosticText
                                copiedDiagnostic = true
                            }
                        }.font(.footnote.weight(.medium))
                    }
                    Button { submit() } label: {
                        HStack(spacing: 10) {
                            if login.busy { ProgressView().tint(.white) }
                            Text(buttonTitle).font(.headline)
                            if !login.busy { Image(systemName: "arrow.right") }
                        }.frame(maxWidth: .infinity).padding(.vertical, 17)
                    }.buttonStyle(.plain).foregroundColor(.white)
                        .background(accent, in: RoundedRectangle(cornerRadius: 16))
                        .disabled(!canSubmit).opacity(canSubmit ? 1 : 0.55)
                }.padding(24).background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(accent.opacity(0.12), lineWidth: 1))
                if allowsClose && network.canOpenApp { savedDataButton }
                Button { showWebLogin = true } label: {
                    Label("Войти через страницу ЭИОС", systemImage: "globe")
                }
                .font(.subheadline.weight(.medium))
                Text("Запасной путь: настоящая страница входа сайта внутри приложения. Код MAX вводится прямо в окне ЭИОС.")
                    .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                Label(rememberLogin ? "Логин и пароль — только в Keychain этого iPhone. Код MAX не сохраняется."
                                    : "Пароль и код не сохраняются", systemImage: "lock.shield")
                    .multilineTextAlignment(.center)
                    .font(.footnote).foregroundColor(.secondary)
                Text("Расписание и оценки остаются доступны без интернета после загрузки.")
                    .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: 440).padding(24).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively)
    }
    /// The sheet over the app: the last downloaded data stays readable without signing in.
    private var savedDataButton: some View {
        Button { focused = nil; dismiss() } label: {
            HStack(spacing: 12) {
                Image(systemName: "tray.full").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Посмотреть сохранённые данные").font(.subheadline.weight(.semibold))
                    Text(network.lastServerContact.map { "Последнее обновление: " + CampusDate.formatter("d MMM, HH:mm").string(from: $0) }
                         ?? "Расписание, оценки и курсы, загруженные раньше")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundColor(.secondary)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain).foregroundColor(accent)
        .accessibilityHint("Закрывает вход. Войти можно позже в Настройках.")
        .accessibilityIdentifier("login.savedData")
    }
    private var fieldBackground: Color { colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04) }
    private var canSubmit: Bool {
        guard !login.busy, !login.completed else { return false }
        if login.form == .oneTimeCode && code.count == 6 { return true } // a new code after a rejected one
        if login.isAwaitingResult { return true }
        switch login.form {
        case .credentials: return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
        case .oneTimeCode: return code.count == 6
        }
    }
    private var buttonTitle: String {
        if login.isCheckingCode { return "Проверяем код…" }
        if login.busy { return login.form == .oneTimeCode ? "Загружаем форму MAX…" : "Подключаемся…" }
        if login.isAwaitingResult && !(login.form == .oneTimeCode && code.count == 6) { return "Проверить результат" }
        switch login.form {
        case .credentials: return "Войти"
        case .oneTimeCode: return "Подтвердить"
        }
    }
    private func submit() {
        guard canSubmit else { return }
        if login.isAwaitingResult && login.form == .oneTimeCode && code.count == 6 {
            let confirmation = code
            focused = nil
            Task { if await login.retryCode(confirmation), code == confirmation { code = "" } }
            return
        }
        if login.isAwaitingResult { focused = nil; login.retryConnection(); return }
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password, confirmation = code
        if login.form == .credentials { sentCredentials = .init(username: name, password: secret) }
        focused = nil
        Task {
            let sent = await login.submit(username: name, password: secret, code: confirmation)
            if sent {
                if password == secret { password = "" }
                if code == confirmation { code = "" }
            }
        }
    }
}

@MainActor
private struct LoginWebSurface: UIViewRepresentable {
    let controller: PortalLoginController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
