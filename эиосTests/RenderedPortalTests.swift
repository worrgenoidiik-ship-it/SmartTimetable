import XCTest
@testable import SmartTable

final class RenderedPortalTests: XCTestCase {
    private func fixture(_ name: String, ext: String = "html") throws -> String {
        let bundle = Bundle(for: RenderedPortalTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
                               ?? bundle.url(forResource: name, withExtension: ext))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testAll27ActualCourseCardsUseFullNamesAndSkipImageLinks() throws {
        struct Expected: Decodable {
            struct Entry: Decodable { let id: String; let title: String }
            let courses: [Entry]
        }
        let expected = try JSONDecoder().decode(Expected.self, from: Data(fixture("rendered.expected", ext: "json").utf8))
        let items = try PortalParser.courses(html: fixture("courses_rendered"), source: PortalConfiguration.coursesURL)
        XCTAssertEqual(items.count, 27)
        XCTAssertEqual(items.map(\.id), expected.courses.map(\.id))
        XCTAssertEqual(items.map(\.title), expected.courses.map(\.title))
        XCTAssertTrue(items.contains { $0.title.contains("Комарова Юлиана Егоровна") })
        XCTAssertFalse(items.contains { $0.title == "Изображение курса" || $0.title.contains("Курс является избранным") })
    }

    func testMalformedActualCourseCardDoesNotCommitAPartialList() throws {
        let html = try fixture("courses_rendered").replacingOccurrences(of: "data-course-id=\"492925\"", with: "data-course-id=\"999\"")
        XCTAssertThrowsError(try PortalParser.courses(html: html, source: PortalConfiguration.coursesURL))
    }

    func testActualNotificationsIncludeAll16RowsAndTenUnread() throws {
        let html = try fixture("notifications_rendered")
        let items = try PortalParser.notifications(html: html, source: PortalConfiguration.notificationsURL)
        XCTAssertEqual(items.count, 16)
        XCTAssertEqual(items.filter(\.isUnread).count, 10)
        XCTAssertEqual(items.first?.id, "12755819")
        XCTAssertEqual(items.first?.sourceTimeLabel, "2 дн. 20 час. назад")
        XCTAssertFalse(items.first?.isUnread ?? true)
        XCTAssertTrue(html.contains("Уведомлений нет"))
        XCTAssertFalse(items.contains { $0.message == "Уведомлений нет" })
        let profile = try PortalParser.authenticatedProfile(html: html, url: PortalConfiguration.notificationsURL)
        XCTAssertEqual(profile.accountKey, StableID.make(["portal.ulsu.ru", "id:42"]))
    }

    func testEmptyLoadingInboxAndBrokenRowCannotEraseCachedMessages() throws {
        let empty = "<div data-region='notification-area'><div class='empty-text'>Уведомлений нет</div></div>"
        XCTAssertThrowsError(try PortalParser.notifications(html: empty, source: PortalConfiguration.notificationsURL))
        let broken = try fixture("notifications_rendered").replacingOccurrences(of: "data-id=\"12755819\"", with: "data-id=\"invalid\"")
        XCTAssertThrowsError(try PortalParser.notifications(html: broken, source: PortalConfiguration.notificationsURL))
    }

    func testMergingNotificationsUpdatesReadStatusAndPreservesOlderObservationDate() {
        let oldDate = Date(timeIntervalSince1970: 1_000)
        let newDate = Date(timeIntervalSince1970: 2_000)
        let old = PortalNotification(id: "1", message: "Один", sourceTimeLabel: "вчера", isUnread: true, observedAt: oldDate)
        let cached = PortalNotification(id: "2", message: "Два", sourceTimeLabel: "неделю назад", isUnread: false, observedAt: oldDate)
        let updated = PortalNotification(id: "1", message: "Один", sourceTimeLabel: "два дня назад", isUnread: false, observedAt: newDate)
        let items = PortalParser.mergingObservedNotifications([updated], into: [old, cached])
        XCTAssertEqual(items.map(\.id), ["1", "2"])
        XCTAssertFalse(items[0].isUnread)
        XCTAssertEqual(items[1].observedAt, oldDate)
    }

    func testLegacySnapshotWithoutInboxStillDecodesAndNewInboxRoundTrips() throws {
        let old = try JSONDecoder().decode(PortalSnapshot.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        XCTAssertNil(old.notifications)
        var next = old
        let items = try PortalParser.notifications(html: fixture("notifications_rendered"), source: PortalConfiguration.notificationsURL)
        next.notifications = CachedSection(value: items, fetchedAt: Date(), sources: [PortalConfiguration.notificationsURL])
        let decoded = try JSONDecoder().decode(PortalSnapshot.self, from: JSONEncoder().encode(next))
        XCTAssertEqual(decoded.notifications?.value, items)
    }

    func testActualMAXModalCannotCountAsAuthenticatedOnADashboardURL() throws {
        let html = "<div class='usermenu'><span class='usertext'>Тест</span><a href='/user/profile.php?id=42'>Профиль</a><a href='/login/logout.php'>Выход</a></div>" + (try fixture("max_form"))
        XCTAssertThrowsError(try PortalParser.authenticatedProfile(html: html, url: PortalConfiguration.dashboardURL))
    }
}
