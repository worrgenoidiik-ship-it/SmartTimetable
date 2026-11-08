import Foundation
import Combine
import UIKit

@MainActor
final class NetworkManager: ObservableObject {
    static let shared = NetworkManager()
    @Published private(set) var snapshot = PortalSnapshot()
    @Published private(set) var isLoading = false
    @Published private(set) var isCheckingLogin = false
    @Published private(set) var isSigningOut = false
    @Published private(set) var sessionState: SessionState = .unchecked
    @Published private(set) var errors: [String: String] = [:]
    @Published var showLogin = false
    @Published private(set) var browserCount = 0
    @Published private(set) var loadingKeys: Set<String> = []
    @Published private(set) var isRestoringSession = false
    /// False until launch checked the cache and any saved session; the login screen waits for it
    /// so that it is not created twice (each auto-login makes the portal send a new MAX code).
    @Published private(set) var startupResolved = false
    private let cache = CacheStore()
    private let client = PortalClient()
    private var bootstrapped = false
    private var bootstrapTask: Task<Void, Never>?
    private var generation = 0
    private var refreshTask: Task<Bool, Never>?
    private var refreshID: UUID?
    private var loginTask: Task<Bool, Never>?
    private var retryNotBefore: Date?
    private var transientFailures = 0
    private(set) var loginVerificationCanRetry = false

    // DOM imports must belong to the same login lifecycle, even if the user
    // signs out and then signs into the same account while WebKit is awaiting JS.
    var sessionGeneration: Int { generation }

    var news: [NewsItem] { snapshot.news?.value ?? [] }
    var deadlines: [DeadlineItem] { snapshot.deadlines?.value ?? [] }
    var upcomingDeadlines: [DeadlineItem] { deadlines.filter { ($0.due ?? .distantFuture) > Date() } }
    /// Newest first: what was due most recently is usually the most urgent to catch up on.
    var overdue: [DeadlineItem] { (snapshot.overdue?.value ?? []).sorted { ($0.due ?? .distantPast) > ($1.due ?? .distantPast) } }
    var grades: [GradeItem] { snapshot.grades?.value ?? [] }
    var attestations: [GradeItem] { snapshot.attestations?.value ?? [] }
    var courses: [Course] { snapshot.courses?.value ?? [] }
    var notifications: [PortalNotification] { snapshot.notifications?.value ?? [] }
    var unreadNotificationCount: Int { notifications.filter(\.isUnread).count }
    var userNameFromSite: String { snapshot.profile?.name ?? "" }
    var canOpenApp: Bool { snapshot.profile != nil }
    var nextRefreshAt: Date? { retryNotBefore ?? snapshot.nextRefreshAt }
    /// What the schedule tab and lesson reminders use: the manual plan or the portal history.
    var displayedSchedule: CachedSection<ScheduleWindow>? {
        scheduleDisplay(PortalConfiguration.scheduleMode).section
    }

    /// The merged schedule with per-day lookups, rebuilt only when the data or the mode change.
    /// Screens read it many times per render; rebuilding it each time made scrolling stutter.
    struct ScheduleDisplay {
        let section: CachedSection<ScheduleWindow>?
        let itemsByDay: [String: [ScheduleItem]]
        let days: Set<String>
        let plannedDays: Set<String>
    }
    private var scheduleCache: (key: String, value: ScheduleDisplay)?

    func scheduleDisplay(_ mode: ScheduleMode) -> ScheduleDisplay {
        let manual = snapshot.schedule, portal = snapshot.portalSchedule
        let key = [mode.rawValue,
                   "\(manual?.fetchedAt.timeIntervalSince1970 ?? 0)", "\(manual?.value.items.count ?? -1)",
                   "\(portal?.fetchedAt.timeIntervalSince1970 ?? 0)", "\(portal?.value.items.count ?? -1)",
                   "\(snapshot.courses?.fetchedAt.timeIntervalSince1970 ?? 0)"].joined(separator: "|")
        if let cache = scheduleCache, cache.key == key { return cache.value }
        let section = ScheduleSource.window(of: snapshot, mode: mode)
        let planned: Set<String> = mode == .manual ? Set(section?.value.days ?? [])
            : (mode == .auto && StudentGroup.planApplies(to: snapshot) ? Set(manual?.value.days ?? []) : [])
        let value = ScheduleDisplay(section: section,
                                    itemsByDay: Dictionary(grouping: section?.value.items ?? [], by: \.day),
                                    days: Set(section?.value.days ?? []), plannedDays: planned)
        scheduleCache = (key, value)
        return value
    }
    var errorMessage: String? { errors.sorted { $0.key < $1.key }.map(\.value).first }
    var autoRefreshEnabled: Bool { (UserDefaults.standard.object(forKey: PortalConfiguration.autoRefreshKey) as? Bool) ?? true }

    func message(for error: Error, section: String? = nil) -> String {
        let hasSavedData: Bool
        switch section {
        case "grades": hasSavedData = snapshot.grades != nil
        case "attestations": hasSavedData = snapshot.attestations != nil
        case "schedule": hasSavedData = snapshot.schedule != nil || snapshot.portalSchedule != nil
        case "courses": hasSavedData = snapshot.courses != nil
        case "notifications": hasSavedData = snapshot.notifications != nil
        default: hasSavedData = snapshot.profile != nil
        }
        return PortalErrorMessage.message(for: error, hasSavedData: hasSavedData)
    }

    init() {
        UserDefaults.standard.removeObject(forKey: "saved_password")
        UserDefaults.standard.removeObject(forKey: "saved_login")
        if !UserDefaults.standard.bool(forKey: "smarttable.didLogout") {
            do { snapshot = try cache.load() ?? PortalSnapshot() }
            catch { errors["cache"] = "Не удалось прочитать сохранённые данные. Файл оставлен для восстановления." }
            migrateLegacyGradesIfNeeded()
            do { try installManualSchedule() }
            catch { errors["cache"] = error.localizedDescription }
        }
    }

    func bootstrap() async {
        if let task = bootstrapTask { await task.value; return }
        guard !bootstrapped, !isSigningOut else { return }
        let token = generation
        let task = Task {
            do {
                if UserDefaults.standard.bool(forKey: "smarttable.didLogout") { try await SessionStore.shared.clear() }
                else { try await SessionStore.shared.prepare() }
                if token == self.generation { self.bootstrapped = true }
            } catch { if token == self.generation { self.errors["session"] = self.message(for: error) } }
        }
        bootstrapTask = task
        await task.value
        if token == generation { bootstrapTask = nil }
    }

    func refresh(force: Bool = false) async -> Bool {
        await bootstrap()
        guard canOpenApp, !isSigningOut, browserCount == 0 else { return false }
        if !force && !autoRefreshEnabled { return false }
        if !force, let next = nextRefreshAt, Date() < next { return true }
        if let task = refreshTask { return await task.value }
        let token = generation
        let id = UUID()
        let task = Task { await self.performRefresh(token: token) }
        refreshTask = task; refreshID = id
        let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if refreshID == id { refreshTask = nil; refreshID = nil }
        return result
    }

    private func performRefresh(token: Int) async -> Bool {
        isLoading = true
        defer { if token == generation { isLoading = false } }
        errors = errors.filter { ["cache", "session"].contains($0.key) }
        var allSucceeded = true
        var transientFailure = false
        do {
            let page = try await probeSession()
            try validate(token)
            try acceptProfile(page.profile)
            sessionState = .active
            guard let account = snapshot.profile?.accountKey else { return false }
            do {
                let values = try await client.academicProgress(from: page)
                try validate(token)
                var next = snapshot
                next.grades = CachedSection(value: values, fetchedAt: Date(), sources: [PortalConfiguration.gradesURL])
                try commit(next)
            } catch { try handleSectionError(error, key: "grades", token: token); allSucceeded = false; transientFailure = transientFailure || RefreshPolicy.isTransient(error) }

            // Fetch all dates returned by one response, including the new fortnight.
            // Keep the observed portal history separate from the user's manual plan.
            do {
                // The protected page above established the account. Browser opening,
                // logout and account changes cancel this refresh before it can commit.
                let days = try await client.ajaxSchedule()
                try validate(token)
                let observed = try PortalParser.mergeSchedule([days])
                let window = PortalParser.preservingScheduleHistory(observed, previous: snapshot.portalSchedule?.value)
                var next = snapshot
                let previous = snapshot.portalSchedule?.value
                // `schedule` always holds the manual plan; the setting only picks which one is shown.
                next.portalSchedule = CachedSection(value: window, fetchedAt: Date(), sources: [PortalConfiguration.scheduleURL])
                try commit(next)
                AppNotificationManager.shared.updateFromSnapshot()
                if PortalConfiguration.scheduleMode != .manual {
                    let changed = PortalEvents.changedScheduleDays(before: previous, after: window)
                    AppNotificationManager.shared.announceScheduleChanges(days: changed.count)
                }
            } catch { try handleSectionError(error, key: "schedule", token: token); allSucceeded = false; transientFailure = transientFailure || RefreshPolicy.isTransient(error) }
            if let url = PortalConfiguration.attestationURL, let table = PortalConfiguration.attestationTable {
                do {
                    let values = try await client.grades(at: url, mapping: table, account: account)
                    try validate(token)
                    var next = snapshot
                    next.attestations = CachedSection(value: values, fetchedAt: Date(), sources: [url])
                    try commit(next)
                } catch { try handleSectionError(error, key: "attestations", token: token); allSucceeded = false; transientFailure = transientFailure || RefreshPolicy.isTransient(error) }
            }
            do {
                let dashboard = try await client.dashboard(account: account)
                try validate(token)
                // News lives on the same page; its failure must not discard the course list.
                if let news = try? PortalParser.news(html: dashboard.html, source: dashboard.url) {
                    var next = snapshot
                    next.news = CachedSection(value: news, fetchedAt: Date(), sources: [dashboard.url])
                    try commit(next)
                }
                let values = try PortalParser.courses(html: dashboard.html, source: dashboard.url)
                var next = snapshot
                next.courses = CachedSection(value: PortalParser.mergingObservedCourses(values, into: courses, seenAt: Date()),
                                             fetchedAt: Date(), sources: [PortalConfiguration.coursesURL])
                try commit(next)
            } catch { try handleSectionError(error, key: "courses", token: token); allSucceeded = false; transientFailure = transientFailure || RefreshPolicy.isTransient(error) }
            for kind in PortalPageKind.allCases where kind.refreshesAutomatically {
                do {
                    let document = try await client.document(kind, account: account)
                    try validate(token)
                    try storePage(document, kind: kind)
                } catch { try handleSectionError(error, key: kind.errorKey, token: token) }
            }
            do {
                let values = try await fetchDeadlines(account: account)
                try validate(token)
                try storeDeadlines(values)
            } catch { try handleSectionError(error, key: "deadlines", token: token) }
            do {
                let values = try await fetchOverdue()
                try validate(token)
                try storeOverdue(values)
            } catch { try handleSectionError(error, key: "overdue", token: token) }
            do {
                let values = try await client.notifications(account: account)
                try validate(token)
                var next = snapshot
                let previous = snapshot.notifications?.value
                next.notifications = CachedSection(value: PortalParser.mergingObservedNotifications(values, into: notifications),
                                                    fetchedAt: Date(), sources: [PortalConfiguration.notificationsURL])
                try commit(next)
                AppNotificationManager.shared.announceNewPortalNotifications(
                    count: PortalEvents.newUnreadNotifications(before: previous, after: values))
            } catch { try handleSectionError(error, key: "notifications", token: token); allSucceeded = false; transientFailure = transientFailure || RefreshPolicy.isTransient(error) }
            errors.removeValue(forKey: "session")
        } catch {
            guard token == generation, !Task.isCancelled else { return false }
            if let failure = error as? PortalFailure, case .loginRequired = failure {
                if await recoverVerifiedSession(token: token) {
                    // The verified session still works: only the cookies tried first were stale.
                    transientFailure = true
                } else {
                    guard token == generation, !Task.isCancelled else { return false }
                    sessionState = .needsLogin
                    noteSessionLost("обновление данных")
                    sessionDidExpire()
                    errors["refresh"] = message(for: error)
                }
            } else {
                if PortalErrorMessage.connectionMessage(for: error, hasSavedData: false) != nil {
                    sessionState = .offline
                    transientFailure = RefreshPolicy.isTransient(error)
                }
                errors["refresh"] = message(for: error)
            }
            guard token == generation, !Task.isCancelled else { return false }
            allSucceeded = false
        }
        guard token == generation, !Task.isCancelled else { return false }
        var next = snapshot
        transientFailures = transientFailure ? transientFailures + 1 : 0
        let delay = transientFailure ? RefreshPolicy.retryDelay(failures: transientFailures) : PortalConfiguration.randomRefreshDelay()
        next.nextRefreshAt = Date().addingTimeInterval(delay)
        retryNotBefore = next.nextRefreshAt
        do { try commit(next) } catch { errors["cache"] = error.localizedDescription; allSucceeded = false }
        await recordContact()
        return allSucceeded
    }

    private func probeSession() async throws -> PortalPage {
        // A legacy cache does not have a numeric account ID yet.
        let expected = snapshot.profile.flatMap { $0.accountKey.hasPrefix("legacy:") ? nil : $0.accountKey }
        do { return try await client.page(at: PortalConfiguration.sessionProbeURL, expectedAccount: expected) }
        catch {
            try Task.checkCancellation()
            guard let failure = error as? PortalFailure, case .loginRequired = failure else { throw error }
            let recovered = try await SessionStore.shared.recoverHTTPFromWeb()
            if recovered {
                return try await client.page(at: PortalConfiguration.sessionProbeURL, expectedAccount: expected)
            }
            throw error
        }
    }

    func checkBrowserLogin() async -> Bool {
        guard !isSigningOut else { return false }
        if let task = loginTask {
            return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        }
        let token = generation
        let task = Task { () -> Bool in
            self.isCheckingLogin = true
            self.loginVerificationCanRetry = false
            defer { if token == self.generation { self.isCheckingLogin = false } }
            do {
                try await SessionStore.shared.captureWebSession()
                let page = try await self.client.page(at: PortalConfiguration.sessionProbeURL)
                try self.validate(token)
                try await SessionStore.shared.persistHTTPToWeb()
                try self.validate(token)
                try self.acceptProfile(page.profile)
                self.sessionState = .active
                SessionJournal.add("Вход выполнен")
                self.errors.removeValue(forKey: "login")
                self.errors.removeValue(forKey: "session")
                self.errors.removeValue(forKey: "refresh")
                self.showLogin = false
                return true
            } catch {
                if token == self.generation && !Task.isCancelled {
                    if let failure = error as? PortalFailure, case .loginRequired = failure {
                        // During MAX completion, a read-only account check may arrive
                        // before the session becomes visible to the protected endpoint.
                        self.loginVerificationCanRetry = true
                        self.errors["login"] = "ЭИОС пока не подтвердила вход. Нажмите «Проверить результат»."
                    } else {
                        self.loginVerificationCanRetry = RefreshPolicy.isTransient(error)
                        self.errors["login"] = PortalErrorMessage.message(for: error)
                    }
                }
                return false
            }
        }
        loginTask = task
        // Task {} is unstructured: closing native login must explicitly cancel
        // the protected account request before it can accept a late profile.
        let result = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if token == generation { loginTask = nil }
        return result
    }

    func importRenderedCourses(html: String, source: URL, account: String, generation token: Int) throws {
        try validate(token)
        guard !isSigningOut, browserCount > 0, snapshot.profile?.accountKey == account,
              PortalConfiguration.allowsDataURL(source), source.path == PortalConfiguration.coursesURL.path else {
            throw PortalFailure.loginRequired
        }
        let profile = try PortalParser.authenticatedProfile(html: html, url: source)
        guard profile.accountKey == account else { throw PortalFailure.loginRequired }
        let observed = try PortalParser.courses(html: html, source: source)
        var next = snapshot
        // A rendered dashboard may show only one page/filter. Do not erase older
        // cards just because they are absent from the currently visible slice.
        let values = PortalParser.mergingObservedCourses(observed, into: courses, seenAt: Date())
        next.courses = CachedSection(value: values, fetchedAt: Date(), sources: [PortalConfiguration.coursesURL])
        try commit(next)
        errors.removeValue(forKey: "courses")
        sessionState = .active
    }

    func recordCourseImportFailure(_ error: Error, account: String?, generation token: Int) {
        guard token == generation, !isSigningOut, let account = account, snapshot.profile?.accountKey == account else { return }
        errors["courses"] = message(for: error, section: "courses")
        if let failure = error as? PortalFailure, case .loginRequired = failure { sessionState = .needsLogin }
    }

    func importRenderedNotifications(html: String, source: URL, account: String, generation token: Int) throws {
        try validate(token)
        guard !isSigningOut, browserCount > 0, snapshot.profile?.accountKey == account,
              PortalConfiguration.allowsDataURL(source), source.path == PortalConfiguration.notificationsURL.path else {
            throw PortalFailure.loginRequired
        }
        let profile = try PortalParser.authenticatedProfile(html: html, url: source)
        guard profile.accountKey == account else { throw PortalFailure.loginRequired }
        let observed = try PortalParser.notifications(html: html, source: source)
        var next = snapshot
        let previous = snapshot.notifications?.value
        next.notifications = CachedSection(value: PortalParser.mergingObservedNotifications(observed, into: notifications),
                                            fetchedAt: Date(), sources: [PortalConfiguration.notificationsURL])
        try commit(next)
        AppNotificationManager.shared.announceNewPortalNotifications(
            count: PortalEvents.newUnreadNotifications(before: previous, after: observed))
        errors.removeValue(forKey: "notifications")
        sessionState = .active
    }

    func recordNotificationImportFailure(_ error: Error, account: String?, generation token: Int) {
        guard token == generation, !isSigningOut, let account = account, snapshot.profile?.accountKey == account else { return }
        errors["notifications"] = message(for: error, section: "notifications")
        if let failure = error as? PortalFailure, case .loginRequired = failure { sessionState = .needsLogin }
    }

    func browserWillOpen() async {
        browserCount += 1
        let id = refreshID
        refreshTask?.cancel()
        if let task = refreshTask { _ = await task.value }
        if refreshID == id { refreshTask = nil; refreshID = nil }
        await bootstrap()
        if browserCount == 1 && !isSigningOut {
            // A cancelled refresh may already have received a rotated cookie.
            // Copy the final HTTP state before the browser starts its first request.
            do {
                try await SessionStore.shared.persistHTTPToWeb()
                errors.removeValue(forKey: "session")
            } catch { errors["session"] = message(for: error) }
        }
    }
    func browserDidClose(refreshAfterClose: Bool = true) async {
        let token = generation
        if !isSigningOut {
            do {
                try await SessionStore.shared.captureWebSession()
                try validate(token)
                if snapshot.profile != nil {
                    do { _ = try await probeSession() }
                    catch let failure as PortalFailure {
                        // The browser's cookies are only a candidate. If they are not signed in,
                        // keep the app's last verified session instead of losing it.
                        guard case .loginRequired = failure, await recoverVerifiedSession(token: token) else { throw failure }
                        try await SessionStore.shared.persistHTTPToWeb()
                    }
                    try validate(token)
                }
                errors.removeValue(forKey: "session")
            }
            catch {
                if token == generation, !isSigningOut, !Task.isCancelled {
                    errors["session"] = message(for: error)
                }
            }
        }
        browserCount = max(0, browserCount - 1)
        if token == generation && browserCount == 0 && !isSigningOut && refreshAfterClose {
            _ = await refresh(force: true)
        }
    }

    func clearCredentials() async {
        guard !isSigningOut else { return }
        isSigningOut = true; generation += 1
        SessionJournal.add("Выход из аккаунта")
        UserDefaults.standard.set(true, forKey: "smarttable.didLogout")
        bootstrapTask?.cancel()
        if let task = bootstrapTask { await task.value }
        bootstrapTask = nil
        refreshTask?.cancel(); loginTask?.cancel()
        await client.cancelAll()
        if let task = refreshTask { _ = await task.value }
        if let task = loginTask { _ = await task.value }
        refreshTask = nil; refreshID = nil; loginTask = nil; showLogin = false
        snapshot = PortalSnapshot(); retryNotBefore = nil; transientFailures = 0; sessionState = .needsLogin
        loadingKeys = []
        WidgetBridge.clear()
        // The server must stop keeping a session the user has left. Not awaited: logout stays instant.
        Task.detached { await Keeper.forget() }
        keeperRetryAfter = nil
        CredentialVault.delete()
        MobileTokenVault.delete()
        lastAutologinAttempt = nil
        UserDefaults.standard.removeObject(forKey: Self.lastContactKey)
        Messenger.shared.reset()
        errors = [:]; isLoading = false; isCheckingLogin = false; loginVerificationCanRetry = false
        do { try cache.remove() } catch { errors["cache"] = error.localizedDescription }
        do { try await SessionStore.shared.clear() } catch { errors["session"] = error.localizedDescription }
        for key in ["isLoggedIn", "cached_grades", "cached_username", "saved_password", "saved_login"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        AppDataManager.shared.clearPersonalData()
        AppNotificationManager.shared.removeScheduleNotifications()
        RefreshScheduler.shared.cancelBackground()
        isSigningOut = false
    }

    private func acceptProfile(_ profile: StudentProfile) throws {
        if let old = snapshot.profile, old.accountKey != profile.accountKey {
            let legacy = old.accountKey.hasPrefix("legacy:") && old.name == profile.name
            if !legacy {
                var empty = PortalSnapshot(); empty.profile = profile
                try commit(empty)
                AppDataManager.shared.clearPersonalData()
                AppNotificationManager.shared.removeScheduleNotifications()
                Messenger.shared.reset() // chats are personal: never show A's list to B
                SessionJournal.add("Вошёл другой аккаунт: данные прежнего удалены")
            }
        }
        var next = snapshot; next.profile = profile
        next = ManualSchedule.applying(to: next)
        try commit(next)
        UserDefaults.standard.set(false, forKey: "smarttable.didLogout")
        AppNotificationManager.shared.updateFromSnapshot()
    }
    private func commit(_ next: PortalSnapshot) throws {
        try cache.save(next)
        snapshot = next
        errors.removeValue(forKey: "cache")
        WidgetBridge.publish(from: next)
    }

    // MARK: Sections loaded on demand (1.1)

    func page(_ kind: PortalPageKind) -> CachedSection<PortalDocument>? { snapshot.pages?[kind.rawValue] }
    func contents(of course: Course) -> CachedSection<[CourseSection]>? { snapshot.courseContents?[course.id] }
    func isLoading(_ key: String) -> Bool { loadingKeys.contains(key) }

    private func storePage(_ document: PortalDocument, kind: PortalPageKind) throws {
        var next = snapshot
        var pages = next.pages ?? [:]
        pages[kind.rawValue] = CachedSection(value: document, fetchedAt: Date(), sources: [kind.url])
        next.pages = pages
        try commit(next)
        errors.removeValue(forKey: kind.errorKey)
    }

    /// The portal has no «upcoming events» page; the timeline block's web service gives the
    /// same data. The calendar page stays as a fallback for sites without that service.
    private func fetchDeadlines(account: String) async throws -> [DeadlineItem] {
        do {
            let data = try await portalAJAX("core_calendar_get_action_events_by_timesort", [
                "timesortfrom": Int(Date().timeIntervalSince1970) - 86_400, "limittononsuspendedevents": true, "limitnum": 50,
            ])
            return try PortalParser.actionEvents(data)
        } catch let failure as PortalFailure {
            if case .loginRequired = failure { throw failure }
        }
        return try await client.deadlines(account: account)
    }

    private func storeDeadlines(_ values: [DeadlineItem]) throws {
        var next = snapshot
        next.deadlines = CachedSection(value: values, fetchedAt: Date(), sources: [PortalConfiguration.calendarURL])
        try commit(next)
        errors.removeValue(forKey: "deadlines")
        AppNotificationManager.shared.scheduleDeadlineReminders(values)
    }

    func loadPage(_ kind: PortalPageKind) async {
        await loadOnDemand(key: kind.errorKey) { client, account in
            let document = try await client.document(kind, account: account)
            return { try self.storePage(document, kind: kind) }
        }
    }

    func loadDeadlines() async {
        await loadOnDemand(key: "deadlines") { client, account in
            let values = try await self.fetchDeadlines(account: account)
            let overdue = try? await self.fetchOverdue()
            return {
                try self.storeDeadlines(values)
                if let overdue = overdue { try self.storeOverdue(overdue) }
            }
        }
    }

    /// Overdue work: the same timeline service for the last half year up to now. Moodle keeps an
    /// event there only while it still needs an action, so submitted labs and tests disappear.
    private func fetchOverdue() async throws -> [DeadlineItem] {
        let now = Int(Date().timeIntervalSince1970)
        let data = try await portalAJAX("core_calendar_get_action_events_by_timesort", [
            "timesortfrom": now - 183 * 86_400, "timesortto": now, "limittononsuspendedevents": true, "limitnum": 50,
        ])
        return try PortalParser.actionEvents(data).filter { ($0.due ?? .distantFuture) <= Date() }
    }

    private func storeOverdue(_ values: [DeadlineItem]) throws {
        var next = snapshot
        next.overdue = CachedSection(value: values, fetchedAt: Date(), sources: [PortalConfiguration.calendarURL])
        try commit(next)
        errors.removeValue(forKey: "overdue")
    }

    func loadContents(of course: Course) async {
        await loadOnDemand(key: "course.\(course.id)") { client, account in
            let sections = try await client.courseContents(course, account: account)
            return { try self.storeContents(sections, of: course) }
        }
    }

    private func storeContents(_ sections: [CourseSection], of course: Course) throws {
        var next = snapshot
        var all = next.courseContents ?? [:]
        all[course.id] = CachedSection(value: sections, fetchedAt: Date(), sources: [course.url])
        next.courseContents = all
        try commit(next)
        errors.removeValue(forKey: "course.\(course.id)")
    }

    // MARK: Data from pages opened in the in-app browser

    func isNativelyShown(_ url: URL) -> Bool {
        guard PortalConfiguration.allowsDataURL(url) else { return false }
        return PortalPageKind.allCases.contains { $0.url.path == url.path }
            || url.path == "/course/view.php" || url.path == PortalConfiguration.calendarURL.path
    }

    /// Takes the rendered DOM of a page the user opened. The browser runs on the current
    /// session; a login form or another account's page is ignored, and parse failures keep
    /// the previous data.
    func importRenderedPortalPage(html: String, url: URL) {
        guard !isSigningOut, browserCount > 0, let account = snapshot.profile?.accountKey, isNativelyShown(url) else { return }
        do {
            let profile = try PortalParser.authenticatedProfile(html: html, url: url)
            guard profile.accountKey == account else { return }
        } catch let failure as PortalFailure {
            // Some CDO pages have no Moodle user menu; only a login page is a reason to stop.
            if case .loginRequired = failure { return }
        } catch { return }
        if let kind = PortalPageKind.allCases.first(where: { $0.url.path == url.path }) {
            if let document = try? PortalParser.document(html: html, source: url) { try? storePage(document, kind: kind) }
        } else if url.path == "/course/view.php",
                  let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
                  let course = courses.first(where: { $0.id == id }),
                  let sections = try? PortalParser.courseContents(html: html, source: url) {
            try? storeContents(sections, of: course)
        } else if url.path == PortalConfiguration.calendarURL.path, url.query?.contains("view=upcoming") == true,
                  let values = try? PortalParser.deadlines(html: html, source: url) {
            try? storeDeadlines(values)
        }
    }

    /// One read with the same safety rules as the periodic refresh: account check,
    /// one session recovery from WebKit, and nothing committed after logout/browser opening.
    private func loadOnDemand(key: String,
                              _ fetch: @escaping (PortalClient, String) async throws -> () throws -> Void) async {
        await bootstrap()
        guard canOpenApp, !isSigningOut, browserCount == 0, !loadingKeys.contains(key),
              let account = snapshot.profile?.accountKey else { return }
        let token = generation
        loadingKeys.insert(key)
        defer { if token == generation { loadingKeys.remove(key) } }
        do {
            let apply: () throws -> Void
            do { apply = try await fetch(client, account) }
            catch let failure as PortalFailure {
                guard case .loginRequired = failure, try await SessionStore.shared.recoverHTTPFromWeb() else { throw failure }
                try validate(token)
                apply = try await fetch(client, account)
            }
            try validate(token)
            try apply()
            await recordContact()
        } catch {
            guard token == generation, !Task.isCancelled, !(error is CancellationError) else { return }
            if let failure = error as? PortalFailure, case .loginRequired = failure { sessionState = .needsLogin }
            errors[key] = message(for: error)
        }
    }
    // MARK: Long-lived session

    static let serverTimeoutKey = "smarttable.serverSessionTimeout"
    static let lastContactKey = "smarttable.lastServerContact"
    private var lastAutoLoginPrompt: Date?

    /// Moodle ends a session after a period without requests. Ping at a third of that
    /// period (reported by the server itself): at least every 6 h even for a week-long
    /// session, never more often than every 5 min. 15 min until the server has told us.
    var keepAliveInterval: TimeInterval {
        let timeout = UserDefaults.standard.double(forKey: Self.serverTimeoutKey)
        return timeout > 0 ? min(max(timeout / 3, 300), 6 * 3_600) : 900
    }
    var lastServerContact: Date? { UserDefaults.standard.object(forKey: Self.lastContactKey) as? Date }
    var serverSessionTimeout: TimeInterval? {
        let value = UserDefaults.standard.double(forKey: Self.serverTimeoutKey)
        return value > 0 ? value : nil
    }

    private func recordContact() async {
        if let date = await client.lastContact { UserDefaults.standard.set(date, forKey: Self.lastContactKey) }
        await syncKeeper()
    }

    // MARK: Keeper (the user's VPS pings the portal while the phone sleeps)

    private var keeperRetryAfter: Date?

    /// Sends the verified cookies to the keeper when they changed. Cheap when nothing changed:
    /// no request at all. After a failure, waits 30 minutes unless `force` (Settings button).
    @discardableResult
    func syncKeeper(force: Bool = false) async -> Result<KeeperStatus?, Error> {
        guard Keeper.isConfigured, !isSigningOut, sessionState != .needsLogin else { return .success(nil) }
        if !force, let after = keeperRetryAfter, Date() < after { return .success(nil) }
        let cookies = SessionStore.shared.validatedPortalCookies()
        guard !cookies.isEmpty else { return .success(nil) }
        do {
            let status = try await Keeper.push(cookies, force: force)
            keeperRetryAfter = nil
            if let status {
                SessionJournal.add(status.alive ? "Сессия передана серверу-пингеру: он держит её, пока телефон спит"
                                   : "Сервер-пингер получил сессию, но ЭИОС её не приняла: \(status.error ?? "")")
            }
            return .success(status)
        } catch {
            keeperRetryAfter = Date().addingTimeInterval(30 * 60)
            SessionJournal.add("Сервер-пингер недоступен: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    @discardableResult
    func keepAliveIfNeeded(within interval: TimeInterval? = nil) async -> Bool {
        if let last = lastServerContact, Date().timeIntervalSince(last) < (interval ?? keepAliveInterval) { return true }
        return await keepAlive()
    }

    /// One light request that resets the server's idle timer. Falls back to a page load
    /// (which also extends the session) when there is no sesskey yet or the touch is refused.
    @discardableResult
    func keepAlive() async -> Bool {
        await bootstrap()
        guard canOpenApp, !isSigningOut, browserCount == 0, refreshTask == nil, sessionState != .needsLogin else { return false }
        let token = generation
        do {
            var remaining: TimeInterval?
            do { remaining = try await client.touchSession() }
            catch {
                try validate(token)
                _ = try await probeSession()
                try validate(token)
                remaining = try? await client.touchSession()
            }
            try validate(token)
            try? await SessionStore.shared.checkpointValidatedHTTP()
            // Right after a touch the remaining time equals the full server timeout.
            if let remaining = remaining { UserDefaults.standard.set(remaining, forKey: Self.serverTimeoutKey) }
            SessionJournal.add("Сессия продлена (\(Self.appState))" + (remaining.map { ", ЭИОС ждёт без активности \(SessionJournal.duration($0))" } ?? ""))
            await recordContact()
            sessionState = .active
            errors.removeValue(forKey: "session")
            // Logged in before tokens existed: get one now, while nothing is broken.
            if !triedTokenThisRun, MobileTokenVault.load() == nil, let saved = CredentialVault.load() {
                triedTokenThisRun = true
                _ = await fetchMobileToken(username: saved.username, password: saved.password)
            }
            return true
        } catch {
            guard token == generation, !Task.isCancelled, !(error is CancellationError) else { return false }
            if let failure = error as? PortalFailure, case .loginRequired = failure {
                if await recoverVerifiedSession(token: token) {
                    await recordContact()
                    sessionState = .active
                    return true
                }
                guard token == generation, !Task.isCancelled else { return false }
                sessionState = .needsLogin
                noteSessionLost("продление сессии")
                sessionDidExpire()
            } else if PortalErrorMessage.connectionMessage(for: error, hasSavedData: false) != nil {
                sessionState = .offline
                SessionJournal.add("Продление не удалось: нет связи (\(Self.appState))")
            }
            return false
        }
    }

    // MARK: Moodle web services (messenger)

    /// Calls a Moodle AJAX method. When the server answers that the session or sesskey is
    /// stale (the call was rejected, nothing was done), one protected page refreshes both
    /// and the call is made once more. Any other failure is reported as is.
    func portalAJAX(_ method: String, _ args: [String: Any]) async throws -> Any {
        await bootstrap()
        guard canOpenApp, !isSigningOut else { throw PortalFailure.loginRequired }
        do { return try await client.ajax(method, args) }
        catch let failure as PortalFailure {
            guard case .loginRequired = failure else { throw failure }
            do { _ = try await probeSession() }
            catch {
                if let expired = error as? PortalFailure, case .loginRequired = expired {
                    let token = generation
                    if await recoverVerifiedSession(token: token) { return try await client.ajax(method, args) }
                    sessionState = .needsLogin
                    noteSessionLost(method)
                    sessionDidExpire()
                }
                throw error
            }
            return try await client.ajax(method, args)
        }
    }

    func questionForm() async throws -> QuestionForm {
        await bootstrap()
        guard let account = snapshot.profile?.accountKey else { throw PortalFailure.loginRequired }
        do { return try await client.questionForm(account: account) }
        catch let failure as PortalFailure {
            guard case .loginRequired = failure, try await SessionStore.shared.recoverHTTPFromWeb() else { throw failure }
            return try await client.questionForm(account: account)
        }
    }

    func sendQuestion(category: String, subject: String, message: String, email: String) async throws {
        guard canOpenApp, !isSigningOut else { throw PortalFailure.loginRequired }
        try await client.sendQuestion(category: category, subject: subject, message: message, email: email)
        await recordContact()
    }

    var studentGroup: String? { StudentGroup.detect(in: courses) }

    // MARK: Portal forms (заказ справок)

    private func account() throws -> String {
        guard canOpenApp, !isSigningOut, let account = snapshot.profile?.accountKey else { throw PortalFailure.loginRequired }
        return account
    }

    func loadForms(at url: URL) async throws -> (forms: [PortalForm], page: PortalPage) {
        await bootstrap()
        let page = try await client.page(at: url, expectedAccount: try account())
        return (try PortalParser.forms(html: page.html, source: page.url), page)
    }

    func openForm(_ form: PortalForm, values: [String: String]) async throws -> (forms: [PortalForm], page: PortalPage) {
        let page = try await client.openForm(form, values: values, account: try account())
        return (try PortalParser.forms(html: page.html, source: page.url), page)
    }

    // MARK: Quiz

    func quizPage(_ url: URL) async throws -> QuizContent {
        await bootstrap()
        let page = try await client.page(at: url, expectedAccount: try account())
        return try QuizParser.parse(html: page.html, url: page.url)
    }

    /// Only the quiz's own endpoints are posted to, and only on an explicit tap (or the timer,
    /// exactly as the site's own script does when time is up).
    func quizSubmit(_ url: URL, items: [URLQueryItem]) async throws -> QuizContent {
        guard ["/mod/quiz/processattempt.php", "/mod/quiz/startattempt.php"].contains(url.path) else { throw PortalFailure.invalidURL }
        let page = try await client.post(url, items: items, account: try account())
        await recordContact()
        return try QuizParser.parse(html: page.html, url: page.url)
    }

    func submitForm(_ form: PortalForm, values: [String: String]) async throws -> PortalPage {
        let page = try await client.submitForm(form, values: values, account: try account())
        await recordContact()
        return page
    }

    /// The signed-in user's Moodle ID, loading a page first if no page was read yet.
    func moodleUserID() async throws -> Int {
        if let id = await client.userID { return id }
        _ = try await probeSession()
        guard let id = await client.userID else { throw PortalFailure.unrecognized("идентификатор пользователя") }
        return id
    }

    /// After a reinstall the cache is empty but the Keychain still holds the session cookies
    /// (and possibly the saved login). Verify them with one protected page instead of
    /// sending the user to the login screen.
    func restoreSavedSession() async {
        defer { startupResolved = true }
        guard snapshot.profile == nil, !isSigningOut, !isRestoringSession else { return }
        isRestoringSession = true
        defer { isRestoringSession = false }
        await bootstrap()
        guard SessionStore.shared.hasSavedSession else { return }
        let token = generation
        do {
            let page = try await client.page(at: PortalConfiguration.sessionProbeURL)
            try validate(token)
            try acceptProfile(page.profile)
            sessionState = .active
            SessionJournal.add("Сессия восстановлена из Keychain после переустановки")
            await recordContact()
        } catch {
            // An expired session is normal here: the login screen (with autofill) takes over.
            SessionJournal.add("Сохранённая в Keychain сессия уже не действует")
            return
        }
        _ = await refresh(force: true)
    }

    /// With a saved login the sign-in sheet opens by itself and submits automatically;
    /// only a MAX code, if the portal asks for one, is left for the user.
    func sessionDidExpire() {
        guard CredentialVault.hasCredentials, UIApplication.shared.applicationState == .active,
              !showLogin, browserCount == 0, !isSigningOut else { return }
        if let last = lastAutoLoginPrompt, Date().timeIntervalSince(last) < 600 { return }
        lastAutoLoginPrompt = Date()
        SessionJournal.add("Открыт экран входа (автовход)")
        showLogin = true
    }

    /// The last check failed with «sign in». Before believing it, put back the cookies that
    /// were last verified (the in-app browser may have replaced them) and check once more.
    private func recoverVerifiedSession(token: Int) async -> Bool {
        guard token == generation, !isSigningOut else { return false }
        if SessionStore.shared.restoreValidatedHTTP() {
            let expected = snapshot.profile.flatMap { $0.accountKey.hasPrefix("legacy:") ? nil : $0.accountKey }
            do {
                _ = try await client.page(at: PortalConfiguration.sessionProbeURL, expectedAccount: expected)
                try validate(token)
                SessionJournal.add("Сессия спасена: вернулись к последним проверенным кукам")
                return true
            } catch {
                if token == generation { SessionStore.shared.restoreValidatedHTTP() }
            }
        }
        if await recoverFromKeeper(token: token) { return true }
        return await recoverWithMobileToken(token: token)
    }

    /// The phone's cookies were lost or replaced, but the keeper kept the session alive:
    /// take it back from the server instead of showing the login screen and MAX.
    private func recoverFromKeeper(token: Int) async -> Bool {
        guard Keeper.isConfigured, token == generation, !isSigningOut else { return false }
        let expected = snapshot.profile.flatMap { $0.accountKey.hasPrefix("legacy:") ? nil : $0.accountKey }
        do {
            guard let values = try await Keeper.liveSession() else {
                SessionJournal.add("Сервер-пингер: живой сессии на сервере тоже нет")
                return false
            }
            try validate(token)
            let previous = HTTPCookieStorage.shared.cookies ?? []
            SessionStore.shared.installKeeperCookies(Keeper.httpCookies(values))
            do {
                let page = try await client.page(at: PortalConfiguration.sessionProbeURL, expectedAccount: expected)
                try validate(token)
                try? await SessionStore.shared.persistHTTPToWeb()
                if snapshot.profile == nil { try? acceptProfile(page.profile) }
                SessionJournal.add("Сессия восстановлена с сервера-пингера (\(Self.appState)), без входа и MAX")
                return true
            } catch {
                // Not this account or not accepted: put the phone's cookies back as they were.
                for cookie in HTTPCookieStorage.shared.cookies ?? [] where PortalConfiguration.isUniversityCookieDomain(cookie.domain) {
                    HTTPCookieStorage.shared.deleteCookie(cookie)
                }
                for cookie in previous { HTTPCookieStorage.shared.setCookie(cookie) }
                SessionJournal.add("Сессия с сервера-пингера не подошла")
                return false
            }
        } catch {
            if token == generation && !Task.isCancelled {
                SessionJournal.add("Сервер-пингер недоступен при восстановлении: \(error.localizedDescription)")
            }
            return false
        }
    }

    // MARK: Mobile token (long-lived sign-in)

    private var lastAutologinAttempt: Date?
    private var triedTokenThisRun = false
    private var tokenTask: Task<MobileToken?, Never>?

    /// Called right after a confirmed login while the password is still at hand. Failure is
    /// only logged: the app keeps working with cookies as before.
    func obtainMobileToken(username: String, password: String) async {
        guard !isSigningOut, !username.isEmpty, !password.isEmpty else { return }
        _ = await fetchMobileToken(username: username, password: password, force: true)
    }

    /// `force`: right after a confirmed login (a fresh password) the weekly pause is ignored.
    private func fetchMobileToken(username: String, password: String, force: Bool = false) async -> MobileToken? {
        if let task = tokenTask { return await task.value }
        guard force || MobileTokenBackoff.mayRequest() else { return nil }
        let task = Task { () -> MobileToken? in
            do {
                let value = try await MobileAPI.requestToken(username: username, password: password)
                MobileTokenVault.save(value)
                MobileTokenBackoff.reset()
                SessionJournal.add("Получен токен мобильного приложения: сессия больше не зависит от кук"
                                   + (value.privateToken == nil ? " (без privatetoken: автовход недоступен)" : ""))
                return value
            } catch let failure as MobileAPIError {
                // The portal said no (service off, wrong login…): asking again on every launch
                // only adds failed sign-ins to its logs. Wait a week.
                MobileTokenBackoff.refused()
                SessionJournal.add("Токен мобильного приложения не выдан: \(failure.journalText). Следующая попытка через неделю")
            } catch {
                SessionJournal.add("Токен мобильного приложения не получен: нет связи")
            }
            return nil
        }
        tokenTask = task
        let value = await task.value
        tokenTask = nil
        return value
    }

    /// The token survives the web session: get a one-time key and turn it into new cookies.
    private func recoverWithMobileToken(token: Int) async -> Bool {
        guard token == generation, !isSigningOut, UserDefaults.standard.bool(forKey: "smarttable.didLogout") == false else { return false }
        // The portal allows one key per ~6 minutes; do not burn attempts.
        if let last = lastAutologinAttempt, Date().timeIntervalSince(last) < 6 * 60 { return false }
        var stored = MobileTokenVault.load()
        if stored == nil, let saved = CredentialVault.load() {
            stored = await fetchMobileToken(username: saved.username, password: saved.password)
        }
        guard var mobile = stored, token == generation else { return false }
        lastAutologinAttempt = Date()
        let expected = snapshot.profile.flatMap { $0.accountKey.hasPrefix("legacy:") ? nil : $0.accountKey }
        do {
            let url: URL
            do { url = try await MobileAPI.autologinURL(for: mobile) }
            catch MobileAPIError.invalidToken {
                // Expired or revoked: one new token from the saved login, then one more try.
                MobileTokenVault.delete()
                guard let saved = CredentialVault.load(),
                      let fresh = await fetchMobileToken(username: saved.username, password: saved.password) else {
                    SessionJournal.add("Токен больше не действует, сохранённого входа нет")
                    return false
                }
                mobile = fresh
                url = try await MobileAPI.autologinURL(for: mobile)
            }
            try validate(token)
            try await client.openAutologin(url)
            try validate(token)
            let page = try await client.page(at: PortalConfiguration.sessionProbeURL, expectedAccount: expected)
            try validate(token)
            try? await SessionStore.shared.persistHTTPToWeb()
            if snapshot.profile == nil { try? acceptProfile(page.profile) }
            SessionJournal.add("Сессия восстановлена через токен (\(Self.appState)), без входа и MAX")
            return true
        } catch let failure as MobileAPIError {
            SessionJournal.add("Автовход по токену не удался: \(failure.journalText)")
        } catch {
            if token == generation && !Task.isCancelled {
                SessionJournal.add("Автовход по токену не удался: ЭИОС не открыла сессию")
            }
        }
        return false
    }

    /// Records the facts needed to tell an idle timeout from a forced logout.
    private func noteSessionLost(_ context: String) {
        var text = "Сессия завершена (\(context), \(Self.appState))"
        if let last = lastServerContact {
            text += ": последний контакт \(SessionJournal.duration(Date().timeIntervalSince(last))) назад"
        }
        if let timeout = serverSessionTimeout { text += ", ЭИОС ждёт без активности \(SessionJournal.duration(timeout))" }
        SessionJournal.add(text)
    }

    static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: return "приложение открыто"
        case .background: return "в фоне"
        default: return "неактивно"
        }
    }

    /// After a plan file is imported or reset: rebuild, save, refresh reminders and widget.
    func reloadManualPlan() {
        do { try installManualSchedule() } catch { errors["cache"] = error.localizedDescription }
        AppNotificationManager.shared.updateFromSnapshot()
    }

    private func installManualSchedule() throws {
        let next = ManualSchedule.applying(to: snapshot)
        guard next.schedule?.value != snapshot.schedule?.value else { return }
        try commit(next)
    }
    private func validate(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == generation, !isSigningOut else { throw CancellationError() }
    }
    private func handleSectionError(_ error: Error, key: String, token: Int) throws {
        try validate(token)
        if let failure = error as? PortalFailure, case .loginRequired = failure { throw failure }
        errors[key] = message(for: error, section: key)
    }
    private func migrateLegacyGradesIfNeeded() {
        struct LegacyGrade: Decodable {
            let subject: String; let type: String; let grade: String; let date: String; let teacher: String
        }
        guard snapshot.profile == nil, UserDefaults.standard.bool(forKey: "isLoggedIn"),
              let data = UserDefaults.standard.data(forKey: "cached_grades"),
              let old = try? JSONDecoder().decode([LegacyGrade].self, from: data), !old.isEmpty,
              let name = UserDefaults.standard.string(forKey: "cached_username"), !name.isEmpty else { return }
        var migrated = PortalSnapshot()
        migrated.profile = StudentProfile(accountKey: "legacy:" + StableID.make([name]), name: name, identityUsesName: true)
        let values = old.enumerated().map { i, value in
            GradeItem(id: StableID.make(["legacy", String(i)]), subject: value.subject, type: value.type,
                      grade: value.grade, date: value.date, teacher: value.teacher, semester: "")
        }
        migrated.grades = CachedSection(value: values, fetchedAt: .distantPast, sources: [PortalConfiguration.gradesURL])
        do { try commit(migrated) } catch { errors["cache"] = error.localizedDescription }
    }
}
