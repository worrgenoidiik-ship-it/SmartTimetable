import SwiftUI
import UniformTypeIdentifiers

// ==========================================
// НАСТРОЙКИ
// ==========================================
@MainActor
struct SettingsView: View {
    let logoutAction: () -> Void
    @AppStorage("isFaceIDEnabled") private var isFaceIDEnabled = false
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage(AppNotificationManager.scheduleChangesKey) private var scheduleChanges = true
    @AppStorage(AppNotificationManager.portalNewsKey) private var portalNews = true
    @AppStorage(AppNotificationManager.deadlineRemindersKey) private var deadlineReminders = true
    @AppStorage(PortalConfiguration.autoRefreshKey) private var autoRefresh = true
    @AppStorage(PortalConfiguration.scheduleSourceKey) private var scheduleSource = PortalConfiguration.scheduleMode.rawValue
    @State private var importingPlan = false
    @State private var planMessage: String?
    @State private var planFile: URL?
    @State private var report: String?
    @Binding var isDarkMode: Bool
    @Binding var isChristmasMode: Bool
    @ObservedObject private var network = NetworkManager.shared
    @State private var authError = false
    @State private var confirmLogout = false
    @AppStorage(AppTheme.appliedNoticeKey) private var themeApplied = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Безопасность")) {
                    Toggle("Face ID / код устройства", isOn: Binding(get: { isFaceIDEnabled }, set: { enabled in
                        if enabled && !AppAuthManager.canAuthenticate { authError = true }
                        else { isFaceIDEnabled = enabled }
                    }))
                }
                Section(header: Text("Расписание"),
                        footer: Text("«Авто»: пока идёт план группы — он, после его окончания — расписание из ЭИОС. Новый семестр не требует переустановки: загрузите файл плана (тот же формат, что manual_schedule.json в Android) или просто оставьте «Авто».")) {
                    Picker("Источник", selection: $scheduleSource) {
                        ForEach(ScheduleMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    .onChange(of: scheduleSource) { _, value in
                        AppNotificationManager.shared.updateFromSnapshot()
                        if value != ScheduleMode.manual.rawValue { Task { _ = await network.refresh(force: true) } }
                    }
                    LabeledContent("Ваша группа", value: network.studentGroup ?? "не определена")
                    LabeledContent("План группы", value: "\(ManualSchedule.group) · до \(Self.shortDate(ManualSchedule.lastDay))")
                    if !StudentGroup.planApplies(to: network.snapshot) {
                        Text("Этот план составлен для другой группы, поэтому в режиме «Авто» показывается расписание из ЭИОС. Староста может один раз составить план вашей группы (файл JSON) и поделиться им: «Загрузить план нового семестра…».")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Button("Загрузить план нового семестра…") { importingPlan = true }
                    if let planFile = planFile {
                        ShareLink("Поделиться текущим планом (шаблон)", item: planFile)
                    }
                    if ManualSchedule.isImported {
                        Button("Вернуть встроенный план", role: .destructive) {
                            ManualPlanStore.reset()
                            network.reloadManualPlan()
                            planMessage = "Встроенный план восстановлен."
                            preparePlanFile()
                        }
                    }
                    if let planMessage = planMessage { Text(planMessage).font(.caption).foregroundColor(.secondary) }
                }
                Section(header: Text("Обновления"),
                        footer: Text("При открытом приложении: каждые 30–60 минут. В фоне время запуска выбирает iOS.")) {
                    Toggle("Автоматическое обновление", isOn: $autoRefresh)
                        .onChange(of: autoRefresh) { _, enabled in
                            if enabled { RefreshScheduler.shared.scheduleBackground() }
                            else { RefreshScheduler.shared.cancelBackground() }
                        }
                    Button("Обновить сейчас") { Task { _ = await network.refresh(force: true) } }.disabled(network.isLoading)
                    Button("Войти в аккаунт") { network.showLogin = true }
                    SessionInfoView()
                    NavigationLink { SessionJournalScreen() } label: {
                        Label("Журнал сессии", systemImage: "list.bullet.clipboard")
                    }
                    NavigationLink { KeeperScreen() } label: {
                        Label("Сервер-пингер (VPS)", systemImage: "server.rack")
                    }
                    SyncStatusView()
                }
                Section(header: Text("Уведомления"),
                        footer: Text("Изменения расписания проверяются, когда включено «Расписание из ЭИОС». На экране блокировки не показываются названия предметов и тексты сообщений.")) {
                    Toggle("Напоминание за 5 минут до пары", isOn: $notificationsEnabled)
                        .onChange(of: notificationsEnabled) { _, _ in AppNotificationManager.shared.updateFromSnapshot() }
                    Toggle("Дедлайны тестов и заданий", isOn: $deadlineReminders)
                        .onChange(of: deadlineReminders) { _, enabled in
                            if enabled { AppNotificationManager.shared.requestPermission() }
                            AppNotificationManager.shared.scheduleDeadlineReminders(network.deadlines)
                        }
                    Toggle("Изменения расписания ЭИОС", isOn: $scheduleChanges)
                        .onChange(of: scheduleChanges) { _, enabled in if enabled { AppNotificationManager.shared.requestPermission() } }
                    Toggle("Новые уведомления ЭИОС", isOn: $portalNews)
                        .onChange(of: portalNews) { _, enabled in if enabled { AppNotificationManager.shared.requestPermission() } }
                    Button("Проверить уведомления") { AppNotificationManager.shared.sendTestNotification() }
                }
                Section(header: Text("Вид")) {
                    Toggle("Тёмная тема", isOn: $isDarkMode)
                    NavigationLink {
                        ThemeSettingsScreen()
                    } label: {
                        Label("Оформление и новогодний режим", systemImage: "paintpalette")
                    }
                }
                Section {
                    NavigationLink { NotesScreen() } label: { Label("Личные заметки", systemImage: "pencil.and.scribble") }
                }
                Section(header: Text("Помощь"),
                        footer: Text("Отчёт вы отправляете сами, куда захотите (например, автору в Telegram). В нём версия, модель телефона, группа, ошибки загрузки и журнал сессии. ФИО, пароля, оценок и сообщений в нём нет.")) {
                    if let report {
                        ShareLink(item: report) { Label("Сообщить о проблеме", systemImage: "exclamationmark.bubble") }
                    }
                    Link(destination: ProblemReport.projectURL) { Label("Страница проекта на GitHub", systemImage: "link") }
                }
                Section(footer: Text("SmartTimetable \(Self.version)")) {
                    Button("Выйти и удалить данные с телефона", role: .destructive) { confirmLogout = true }
                        .disabled(network.isSigningOut)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .tint(Color.themeAccent(isChristmas: isChristmasMode))
            .navigationTitle("Настройки")
            .onAppear { preparePlanFile(); prepareReport() }
            .fileImporter(isPresented: $importingPlan, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let plan = try ManualPlanStore.importPlan(Data(contentsOf: url))
                    network.reloadManualPlan()
                    planMessage = "Загружен план \(plan.group): \(Self.shortDate(plan.firstDay)) — \(Self.shortDate(plan.lastDay))."
                    preparePlanFile()
                } catch {
                    planMessage = "Файл не принят: \(error.localizedDescription) Текущий план не изменён."
                }
            }
        }
        .alert("Оформление применено", isPresented: $themeApplied) {
            Button("Отлично", role: .cancel) {}
        } message: { Text("Новые цвета уже на всех экранах.") }
        .alert("Нужен код блокировки устройства", isPresented: $authError) {
            Button("ОК", role: .cancel) {}
        } message: { Text("Сначала включите защиту устройства в настройках iPhone.") }
        // Выход стирает зачётку, заметки и фото — раньше это происходило с одного случайного нажатия.
        .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Выйти и удалить данные", role: .destructive) { logoutAction() }
            Button("Отмена", role: .cancel) {}
        } message: { Text("С телефона будут удалены сохранённые оценки, расписание, заметки и фото профиля.") }
    }

    private func preparePlanFile() { planFile = try? ManualPlanStore.exportCurrent() }

    private func prepareReport() {
        report = ProblemReport.text(
            version: Self.version, system: "iOS \(UIDevice.current.systemVersion)", device: Self.deviceModel,
            group: network.studentGroup, errors: network.errors, journal: SessionJournal.text(), crash: CrashReports.last)
    }

    /// «iPhone14,5»: the exact model, which the system does not give in words.
    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func shortDate(_ key: String) -> String {
        guard let date = CampusDate.formatter("yyyy-MM-dd").date(from: key) else { return key }
        return CampusDate.formatter("d MMMM yyyy").string(from: date)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}

/// Shows whether the keep-alive works: last confirmed contact and the server's idle timeout.
@MainActor
private struct SessionInfoView: View {
    @ObservedObject private var network = NetworkManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(network.sessionState == .needsLogin ? "Сессия ЭИОС: нужен вход"
                 : (network.sessionState == .offline ? "Сессия ЭИОС: нет связи" : "Сессия ЭИОС: поддерживается"))
                .font(.subheadline)
            if let last = network.lastServerContact {
                Text("Последний контакт: " + CampusDate.formatter("d MMM, HH:mm").string(from: last))
                    .font(.caption).foregroundColor(.secondary)
            }
            if let timeout = network.serverSessionTimeout {
                Text("ЭИОС держит сессию без активности ≈ \(Self.duration(timeout)); приложение отмечается каждые \(Self.duration(network.keepAliveInterval)), пока iOS позволяет ему работать.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Text(MobileTokenVault.load() != nil
                 ? "Токен мобильного приложения есть: когда сессия истечёт, приложение откроет новую само, без MAX."
                 : (MobileTokenBackoff.isPaused()
                    ? "ЭИОС не выдаёт токен мобильного приложения (сервис выключен). Сессию держат отметки приложения."
                    : "Токена мобильного приложения пока нет (подробности — в журнале сессии)."))
                .font(.caption).foregroundColor(.secondary)
            Text("После переустановки сессия восстанавливается из Keychain, если ещё жива.")
                .font(.caption).foregroundColor(.secondary)
            Text(CredentialVault.hasCredentials ? "Автовход включён: при завершении сессии вход выполнится сам."
                 : "Автовход выключен: включите «Входить автоматически» на экране входа.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 2 * 1_440 { return "\(minutes / 1_440) дн." }
        if minutes >= 120 { return "\(minutes / 60) ч" }
        return "\(minutes) мин"
    }
}

/// What happened to the portal session, newest first. Copy it and send it when the session drops.
private struct SessionJournalScreen: View {
    @State private var entries = SessionJournal.entries().reversed() as [SessionJournal.Entry]
    @State private var copied = false
    @State private var confirmClear = false

    var body: some View {
        List {
            Section(footer: Text("Здесь видно, когда приложение продлевало сессию, когда iOS будила его в фоне и почему ЭИОС попросила войти снова. Пароли, куки и коды сюда не попадают.")) {
                Button(copied ? "Скопировано" : "Скопировать журнал") {
                    UIPasteboard.general.string = "SmartTimetable \(Self.version)\n" + SessionJournal.text()
                    copied = true
                }.disabled(entries.isEmpty)
            }
            Section {
                if entries.isEmpty {
                    Text("Пока пусто").foregroundColor(.secondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(CampusDate.formatter("d MMM, HH:mm:ss").string(from: entry.date))
                            .font(.caption).foregroundColor(.secondary)
                        Text(entry.text).font(.subheadline)
                    }
                }
            }
            if !entries.isEmpty {
                Section {
                    Button("Очистить журнал", role: .destructive) { confirmClear = true }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("Журнал сессии")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { entries = SessionJournal.entries().reversed() }
        .confirmationDialog("Очистить журнал сессии?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) { SessionJournal.clear(); entries = [] }
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

/// Settings of the user's own keeper server (Server/keeper): address, key, live status.
private struct KeeperScreen: View {
    @ObservedObject private var network = NetworkManager.shared
    @State private var address = Keeper.address
    @State private var secret = ""
    @State private var hasSecret = KeeperSecret.load() != nil
    @State private var status: KeeperStatus?
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section(footer: Text("Телефон не может отмечаться на портале, пока спит. Сервер делает это за него каждые 30–60 минут, поэтому сессия не истекает. На сервер уходят только куки ЭИОС, пароль и код MAX остаются на телефоне. При выходе из аккаунта сервер их забывает.")) {
                TextField("https://адрес:порт", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if hasSecret {
                    HStack {
                        Label("Ключ сохранён", systemImage: "key.fill")
                        Spacer()
                        Button("Сменить", role: .destructive) { KeeperSecret.save(""); hasSecret = false; status = nil }
                    }
                } else {
                    SecureField("Ключ сервера", text: $secret)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Вставить ключ из буфера") { secret = UIPasteboard.general.string ?? "" }
                }
                Button(busy ? "Подключаемся…" : "Подключить и передать сессию") { Task { await connect() } }
                    .disabled(busy || (!hasSecret && secret.isEmpty) || Keeper.baseURL(address) == nil)
            }
            if let message { Section { Text(message).font(.subheadline) } }
            if let status {
                Section(header: Text("Сервер сейчас")) {
                    Text(!status.hasSession ? "Сессии на сервере нет"
                         : (status.alive ? "Держит сессию ✅" : "Сессия на сервере истекла"))
                    if let last = status.lastOK {
                        Text("Последняя удачная отметка: " + Self.time(last)).font(.caption).foregroundColor(.secondary)
                    }
                    if let next = status.nextIn, status.alive {
                        Text("Следующая отметка через \(max(1, next / 60)) мин").font(.caption).foregroundColor(.secondary)
                    }
                    if let timeout = status.timeout {
                        Text("ЭИОС ждёт без активности ≈ \(timeout / 60) мин").font(.caption).foregroundColor(.secondary)
                    }
                    if let pings = status.pings { Text("Отметок с последнего входа: \(pings)").font(.caption).foregroundColor(.secondary) }
                    if let error = status.error { Text(error).font(.caption).foregroundColor(.red) }
                }
            }
        }
        .navigationTitle("Сервер-пингер")
        .task { if hasSecret { await refreshStatus() } }
        .refreshable { await refreshStatus() }
    }

    private func connect() async {
        busy = true; defer { busy = false }
        guard Keeper.baseURL(address) != nil else { message = KeeperError.invalidAddress.errorDescription; return }
        Keeper.address = address
        if !hasSecret {
            KeeperSecret.save(secret)
            secret = ""
            hasSecret = KeeperSecret.load() != nil
        }
        switch await network.syncKeeper(force: true) {
        case .success(let value?):
            status = value
            message = value.alive ? "Готово: сервер принял сессию и держит её." : "Сервер получил сессию, но ЭИОС её не приняла. Войдите в аккаунт заново и повторите."
        case .success(nil):
            message = "Сначала войдите в ЭИОС: передавать пока нечего."
            await refreshStatus()
        case .failure(let error):
            message = error.localizedDescription
            if (error as? KeeperError) == .badKey { KeeperSecret.save(""); hasSecret = false }
        }
    }

    private func refreshStatus() async {
        do { status = try await Keeper.status() }
        catch { message = error.localizedDescription }
    }

    private static func time(_ seconds: Int) -> String {
        CampusDate.formatter("d MMM, HH:mm").string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}
