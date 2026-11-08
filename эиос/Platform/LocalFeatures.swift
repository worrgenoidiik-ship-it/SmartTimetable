import Foundation
import LocalAuthentication
import Combine
import UserNotifications

@MainActor
final class AppAuthManager: ObservableObject {
    static let shared = AppAuthManager()
    // Without Face ID the lock screen must not flash before the first authenticate().
    @Published private(set) var isLocked = UserDefaults.standard.bool(forKey: "isFaceIDEnabled")
    @Published private(set) var message: String?
    private var authenticating = false
    static var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
    func lock() {
        if UserDefaults.standard.bool(forKey: "isFaceIDEnabled") { isLocked = true }
    }
    func authenticate() {
        guard UserDefaults.standard.bool(forKey: "isFaceIDEnabled") else { isLocked = false; return }
        guard !authenticating else { return }
        isLocked = true
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            message = error?.localizedDescription ?? "Защита устройства недоступна."
            return
        }
        authenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Доступ к данным SmartTimetable") { success, error in
            Task { @MainActor in
                self.authenticating = false
                self.isLocked = !success
                self.message = success ? nil : error?.localizedDescription
            }
        }
    }
}

@MainActor
final class AppNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationManager()
    private let prefix = "smarttable.lesson."
    private var revision = 0

    func updateFromSnapshot() {
        // Same trigger points (launch, foreground, schedule source switch) keep the widget current.
        WidgetBridge.publish(from: NetworkManager.shared.snapshot)
        revision += 1
        let token = revision
        let enabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        let schedule = NetworkManager.shared.displayedSchedule?.value.notificationItems ?? []
        Task {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let pending = await center.pendingNotificationRequests()
            guard token == revision else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
            guard enabled, !schedule.isEmpty else { return }
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            guard granted, token == revision else { return }
            let future = schedule.compactMap { item -> (ScheduleItem, Date)? in
                guard let start = CampusDate.start(of: item) else { return nil }
                let when = start.addingTimeInterval(-5 * 60)
                return when > Date() ? (item, when) : nil
            }.sorted { $0.1 < $1.1 }
            // iOS has a finite pending-notification budget; keep the nearest lessons.
            for (item, when) in future.prefix(48) {
                guard token == revision else { return }
                let content = UNMutableNotificationContent()
                content.title = "Пара через 5 минут"
                content.body = item.subject + (item.place.isEmpty ? "" : " · " + item.place)
                content.sound = .default
                var date = CampusDate.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: when)
                date.timeZone = CampusDate.calendar.timeZone
                let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: false)
                let identifier = prefix + item.id
                try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                if token != revision {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    return
                }
            }
        }
    }
    func removeScheduleNotifications() {
        revision += 1
        deadlineRevision += 1 // an unfinished deadline task of the old account must not add anything now
        let token = revision
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            // Deadlines belong to the account that is gone: always remove them. Lessons only if
            // no newer schedule was published meanwhile (updateFromSnapshot replaces those itself).
            let lessons = token == revision
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier)
                .filter { (lessons && $0.hasPrefix(prefix)) || $0.hasPrefix(deadlinePrefix) })
        }
    }
    static let deadlineRemindersKey = "deadlineReminders"
    private let deadlinePrefix = "smarttable.deadline."

    /// Reminders 24 h and 3 h before each known deadline. Only events whose exact time
    /// the site exposes are scheduled; the permission prompt is never shown from here.
    /// Same protection as lesson reminders: every call (and logout) bumps the revision, and a task
    /// that finds a newer revision stops adding and removes what it has just added.
    private var deadlineRevision = 0

    func scheduleDeadlineReminders(_ items: [DeadlineItem]) {
        let enabled = Self.isEnabled(Self.deadlineRemindersKey)
        deadlineRevision += 1
        let token = deadlineRevision
        Task {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let pending = await center.pendingNotificationRequests()
            guard token == deadlineRevision else { return }
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(deadlinePrefix) })
            guard enabled, await center.notificationSettings().authorizationStatus == .authorized, token == deadlineRevision else { return }
            let now = Date()
            var requests: [(Date, UNNotificationRequest)] = []
            for item in items {
                guard let due = item.due, due > now else { continue }
                for (hours, label) in [(24.0, "через сутки"), (3.0, "через 3 часа")] {
                    let when = due.addingTimeInterval(-hours * 3_600)
                    guard when > now else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = "\(item.kindLabel): срок \(label)"
                    content.body = item.title + (item.course.isEmpty ? "" : " · " + item.course)
                    content.sound = .default
                    var date = CampusDate.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: when)
                    date.timeZone = CampusDate.calendar.timeZone
                    let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: false)
                    requests.append((when, UNNotificationRequest(identifier: deadlinePrefix + item.id + "." + String(Int(hours)),
                                                                 content: content, trigger: trigger)))
                }
            }
            // iOS keeps 64 pending requests: 48 for lessons, 12 for the nearest deadlines.
            for (_, request) in requests.sorted(by: { $0.0 < $1.0 }).prefix(12) {
                guard token == deadlineRevision else { return }
                try? await center.add(request)
                if token != deadlineRevision {
                    center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                    return
                }
            }
        }
    }

    static let scheduleChangesKey = "scheduleChangeNotifications"
    static let portalNewsKey = "eiosNotifications"

    static func isEnabled(_ key: String) -> Bool { (UserDefaults.standard.object(forKey: key) as? Bool) ?? true }

    func announceScheduleChanges(days: Int) {
        guard days > 0, Self.isEnabled(Self.scheduleChangesKey) else { return }
        // Same wording as Android: no subjects or names on the lock screen.
        post(identifier: "smarttable.schedule-changed", body: "ЭИОС обновила расписание. Дней с изменениями: \(days).")
    }

    func announceNewPortalNotifications(count: Int) {
        guard count > 0, Self.isEnabled(Self.portalNewsKey) else { return }
        post(identifier: "smarttable.portal-news", body: "Новых уведомлений ЭИОС: \(count). Откройте приложение.")
    }

    /// A background refresh never shows the permission prompt; it posts only if already allowed.
    private func post(identifier: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            guard await center.notificationSettings().authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "SmartTimetable"; content.body = body; content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    func requestPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) }
    }

    func sendTestNotification() {
        Task {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            guard (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "SmartTimetable"; content.body = "Уведомления работают"; content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: "smarttable.test", content: content, trigger: trigger))
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
