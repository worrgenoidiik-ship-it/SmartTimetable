import XCTest
@testable import SmartTable

final class PortalEventsTests: XCTestCase {
    private func lesson(_ day: String, _ start: String, _ subject: String, place: String = "1/101") -> ScheduleItem {
        ScheduleItem(id: StableID.make([day, start, subject, place]), day: day, timeStart: start, timeEnd: "23:59",
                     type: "Лекция", subject: subject, teacher: "", place: place, subgroup: "")
    }

    func testChangedFutureDayIsReported() {
        let before = ScheduleWindow(days: ["2026-11-02", "2026-11-03"],
                                    items: [lesson("2026-11-02", "08:00", "Математика"), lesson("2026-11-03", "08:00", "История")],
                                    origin: .portal)
        let after = ScheduleWindow(days: ["2026-11-02", "2026-11-03"],
                                   items: [lesson("2026-11-02", "08:00", "Математика", place: "2/26"), lesson("2026-11-03", "08:00", "История")],
                                   origin: .portal)
        XCTAssertEqual(PortalEvents.changedScheduleDays(before: before, after: after, today: "2026-11-01"), ["2026-11-02"])
    }

    func testPastDaysNewCoverageAndManualPlanAreIgnored() {
        let before = ScheduleWindow(days: ["2026-10-30"], items: [lesson("2026-10-30", "08:00", "А")], origin: .portal)
        let after = ScheduleWindow(days: ["2026-10-30", "2026-11-05"],
                                   items: [lesson("2026-10-30", "09:00", "Б"), lesson("2026-11-05", "08:00", "В")], origin: .portal)
        XCTAssertEqual(PortalEvents.changedScheduleDays(before: before, after: after, today: "2026-11-01"), [])
        XCTAssertEqual(PortalEvents.changedScheduleDays(before: nil, after: after, today: "2026-11-01"), [])
        var manual = before; manual.origin = .manual
        XCTAssertEqual(PortalEvents.changedScheduleDays(before: manual, after: after, today: "2026-10-01"), [])
    }

    func testOnlyNewerUnreadNotificationsCount() {
        let old = [PortalNotification(id: "10", message: "a", sourceTimeLabel: "1 ч", isUnread: true)]
        let current = [
            PortalNotification(id: "12", message: "c", sourceTimeLabel: "сейчас", isUnread: true),
            PortalNotification(id: "11", message: "b", sourceTimeLabel: "5 мин", isUnread: false),
            PortalNotification(id: "5", message: "older page", sourceTimeLabel: "2 дня", isUnread: true),
            PortalNotification(id: "10", message: "a", sourceTimeLabel: "1 ч", isUnread: true),
        ]
        XCTAssertEqual(PortalEvents.newUnreadNotifications(before: old, after: current), 1)
        // The first import is history, not news.
        XCTAssertEqual(PortalEvents.newUnreadNotifications(before: nil, after: current), 0)
    }

    func testCourseLinksStayOnThePortal() {
        let urls = [PortalConfiguration.courseQuizzesURL("42"), PortalConfiguration.courseAssignmentsURL("42"),
                    PortalConfiguration.courseGradesURL("42"), PortalConfiguration.courseParticipantsURL("42"),
                    PortalConfiguration.messagesURL, PortalConfiguration.calendarURL]
        XCTAssertTrue(urls.allSatisfy(PortalConfiguration.allowsDataURL))
        XCTAssertEqual(PortalConfiguration.courseQuizzesURL("42").absoluteString, "https://portal.ulsu.ru/mod/quiz/index.php?id=42")
        XCTAssertEqual(PortalConfiguration.calendarURL.absoluteString, "https://portal.ulsu.ru/calendar/view.php?view=upcoming")
    }

    func testScheduleSourceFollowsTheSetting() {
        let defaults = UserDefaults.standard
        let keys = [PortalConfiguration.portalScheduleKey, PortalConfiguration.scheduleSourceKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        keys.forEach(defaults.removeObject(forKey:))
        XCTAssertEqual(PortalConfiguration.scheduleMode, .auto)
        // 1.1 users who had switched the portal source on keep it.
        defaults.set(true, forKey: PortalConfiguration.portalScheduleKey)
        XCTAssertEqual(PortalConfiguration.scheduleMode, .portal)
        defaults.set(ScheduleMode.manual.rawValue, forKey: PortalConfiguration.scheduleSourceKey)
        XCTAssertEqual(PortalConfiguration.scheduleMode, .manual)
    }
}
