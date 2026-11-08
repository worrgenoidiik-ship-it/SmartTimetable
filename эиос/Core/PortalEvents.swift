import Foundation

/// Ported from the Android PortalEvents. Only committed, successfully parsed portal
/// snapshots are compared, so a network error or a parser failure never looks like a change.
enum PortalEvents {
    /// Future days returned by both portal responses whose lessons differ.
    /// New coverage and missing days are not reported: absence is not a cancellation.
    static func changedScheduleDays(before: ScheduleWindow?, after: ScheduleWindow?,
                                    today: String = CampusDate.key(Date())) -> [String] {
        guard let before = before, let after = after,
              before.origin != .manual, after.origin != .manual else { return [] }
        return Set(before.days).intersection(after.days)
            .filter { $0 >= today && fingerprint(before, $0) != fingerprint(after, $0) }
            .sorted()
    }

    /// Unread notifications newer than everything seen before. The first import is
    /// history, not news, and older pages loaded later never count as new.
    static func newUnreadNotifications(before: [PortalNotification]?, after: [PortalNotification]) -> Int {
        guard let before = before else { return 0 }
        let known = Set(before.map(\.id))
        let newest = before.compactMap { Int($0.id) }.max() ?? 0
        return Set(after.filter { $0.isUnread && !known.contains($0.id) && (Int($0.id) ?? 0) > newest }.map(\.id)).count
    }

    private static func fingerprint(_ window: ScheduleWindow, _ day: String) -> [String] {
        window.items.filter { $0.day == day }.map {
            StableID.make([$0.timeStart, $0.timeEnd, $0.type, $0.subject, $0.teacher, $0.place, $0.subgroup])
        }.sorted()
    }
}
