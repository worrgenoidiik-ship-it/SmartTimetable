import Foundation
import WidgetKit

/// Shares a small summary with the widget through the App Group container.
/// The widget never talks to the portal; without the App Group entitlement this is a no-op.
enum WidgetBridge {
    static let appGroup = "group.com.antonborisov.smartulsu.app2025"
    static let fileName = "widget-v1.json"

    // Keep in sync with SmartUlSUWidget/SmartUlSUWidget.swift (WidgetPayload).
    struct Payload: Codable, Equatable {
        struct Lesson: Codable, Equatable {
            let day: String
            let start: String
            let end: String
            let subject: String
            let type: String
            let place: String
        }
        struct Deadline: Codable, Equatable {
            let title: String
            let kind: String
            let due: Date
        }
        let lessons: [Lesson]
        let deadlines: [Deadline]
    }

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(fileName)
    }

    @MainActor private static var lastPayload: Payload?

    static func payload(from snapshot: PortalSnapshot, now: Date = Date()) -> Payload {
        let schedule = ScheduleSource.window(of: snapshot, mode: PortalConfiguration.scheduleMode)
        let today = CampusDate.key(now)
        let limit = CampusDate.key(now.addingTimeInterval(14 * 86_400))
        let lessons = (schedule?.value.notificationItems ?? [])
            .filter { $0.day >= today && $0.day <= limit && !$0.timeStart.isEmpty && !$0.timeEnd.isEmpty }
            .sorted { ($0.day, $0.timeStart) < ($1.day, $1.timeStart) }
            .prefix(80)
            .map { Payload.Lesson(day: $0.day, start: $0.timeStart, end: $0.timeEnd, subject: $0.subject, type: $0.type, place: $0.place) }
        let deadlines = (snapshot.deadlines?.value ?? [])
            .compactMap { item in item.due.flatMap { $0 > now ? Payload.Deadline(title: item.title, kind: item.kindLabel, due: $0) : nil } }
            .sorted { $0.due < $1.due }
            .prefix(5)
        return Payload(lessons: Array(lessons), deadlines: Array(deadlines))
    }

    /// Called after every cache commit; rewrites the file and reloads widgets only on change.
    @MainActor static func publish(from snapshot: PortalSnapshot) {
        guard let url = fileURL else { return }
        let next = payload(from: snapshot)
        guard next != lastPayload else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(next),
              (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else { return }
        lastPayload = next
        WidgetCenter.shared.reloadAllTimelines()
    }

    @MainActor static func clear() {
        lastPayload = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
