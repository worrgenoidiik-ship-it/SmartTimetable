import XCTest
@testable import SmartTable

final class AjaxScheduleTests: XCTestCase {
    private let source = URL(string: "https://portal.ulsu.ru/blocks/schedule/ajax_schedule.php")!
    private func fixture() throws -> String {
        let bundle = Bundle(for: AjaxScheduleTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "ajax_schedule", withExtension: "json", subdirectory: "Fixtures")
                               ?? bundle.url(forResource: "ajax_schedule", withExtension: "json"))
        return try String(contentsOf: url, encoding: .utf8)
    }
    private func html() throws -> String {
        let json = try JSONDecoder().decode([String: String].self, from: Data(fixture().utf8))
        return try XCTUnwrap(json["html"])
    }
    private func parseHTML(_ html: String) throws -> [String: [ScheduleItem]] {
        let data = try JSONEncoder().encode(["html": html])
        return try PortalParser.parseAjaxSchedule(jsonString: String(decoding: data, as: UTF8.self), source: source)
    }
    func testSuppliedAjaxExamplePreservesAllFields() throws {
        let days = try PortalParser.parseAjaxSchedule(jsonString: fixture(), source: source)
        XCTAssertEqual(Set(days.keys), Set(["2026-09-21"]))
        let items = try XCTUnwrap(days["2026-09-21"])
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.day, "2026-09-21")
        XCTAssertEqual(item.timeStart, "09:30")
        XCTAssertEqual(item.timeEnd, "10:50")
        XCTAssertEqual(item.type, "Практич.")
        XCTAssertEqual(item.subject, "Элективные дисциплины по физической культуре и спорту")
        XCTAssertEqual(item.teacher, "Соколова Олеся Алексеевна")
        XCTAssertEqual(item.place, "Спортзал (Спортзал,3 корп")
        XCTAssertEqual(item.subgroup, "")
        XCTAssertFalse(item.id.isEmpty)
    }
    func testAllDaysIncludingInactivePanesAreParsed() throws {
        let first = try html()
        let second = first.replacingOccurrences(of: "day20260921", with: "day20260922")
            .replacingOccurrences(of: "tab-pane fade", with: "tab-pane fade show active")
        let days = try parseHTML(first + second)
        XCTAssertEqual(Set(days.keys), Set(["2026-09-21", "2026-09-22"]))
    }
    func testInvalidJSONAndMissingHTMLAreRejected() {
        for json in ["{", "{}", "{\"html\":null}", "{\"html\":42}", "<html>Login</html>"] {
            XCTAssertThrowsError(try PortalParser.parseAjaxSchedule(jsonString: json, source: source))
        }
    }
    func testEmptyHTMLAndMissingPanesAreNotSuccessfulEmptySchedules() {
        XCTAssertThrowsError(try parseHTML(""))
        XCTAssertThrowsError(try parseHTML("<div>Временная ошибка</div>"))
    }
    func testLoginFormInsideJSONRequiresLogin() {
        XCTAssertThrowsError(try parseHTML("<form id='login'><input name='logintoken'></form>")) { error in
            guard let failure = error as? PortalFailure, case .loginRequired = failure else {
                return XCTFail("Expected loginRequired, got \(error)")
            }
        }
    }
    func testInvalidDayIdentifiersAndImpossibleDatesAreRejected() throws {
        let original = try html()
        for invalid in ["20260921", "day2026-09-21", "day20260230", "day20261301", "day2026092x"] {
            XCTAssertThrowsError(try parseHTML(original.replacingOccurrences(of: "day20260921", with: invalid)))
        }
    }
    func testMalformedOrReversedTimeIsRejected() throws {
        let original = try html()
        for invalid in ["09:30", "10:50 - 09:30", "09:30 - 09:30", "24:00 - 25:00", "1:003 - 10:50", "09:30 - 10:50 - 12:00"] {
            XCTAssertThrowsError(try parseHTML(original.replacingOccurrences(of: "09:30 - 10:50", with: invalid)))
        }
    }
    func testNonBreakingSpacesAndLongDashAreNormalized() throws {
        let value = try html().replacingOccurrences(of: "09:30 - 10:50", with: " 09:30&nbsp;—&nbsp;10:50 ")
        let item = try XCTUnwrap(parseHTML(value)["2026-09-21"]?.first)
        XCTAssertEqual(item.timeStart, "09:30")
        XCTAssertEqual(item.timeEnd, "10:50")
    }
    func testMissingTeacherFieldRejectsWholeResponse() throws {
        let first = try html()
        let brokenSecond = first.replacingOccurrences(of: "day20260921", with: "day20260922")
            .replacingOccurrences(of: "schedule-table_category", with: "unexpected-teacher-field")
        XCTAssertThrowsError(try parseHTML(first + brokenSecond))
    }
    func testDuplicateDayAndMissingTableAreRejected() throws {
        let first = try html()
        XCTAssertThrowsError(try parseHTML(first + first))
        XCTAssertThrowsError(try parseHTML("<div class='tab-content'><div class='tab-pane' id='day20260921'></div></div>"))
    }
    func testTeacherLineBreaksKeepCompleteNames() throws {
        let value = try html().replacingOccurrences(of: "Соколова Олеся Алексеевна", with: "Соколова Олеся Алексеевна<br><a href='/user/profile.php?id=7'>Иванов Иван Иванович</a><br>")
        let item = try XCTUnwrap(parseHTML(value)["2026-09-21"]?.first)
        XCTAssertEqual(item.teacher, "Соколова Олеся Алексеевна\nИванов Иван Иванович")
    }
    func testStableIDsSurviveRowOrderAndPreserveDuplicateLessons() throws {
        let first = try html()
        let rowStart = try XCTUnwrap(first.range(of: "<tr>"))
        let rowEnd = try XCTUnwrap(first.range(of: "</tr>"))
        let row = String(first[rowStart.lowerBound..<rowEnd.upperBound])
        let other = row.replacingOccurrences(of: "Элективные дисциплины по физической культуре и спорту", with: "Алгебра")
        let forward = try parseHTML(first.replacingOccurrences(of: row, with: row + other))
        let backward = try parseHTML(first.replacingOccurrences(of: row, with: other + row))
        XCTAssertEqual(forward, backward)
        let duplicate = try XCTUnwrap(parseHTML(first.replacingOccurrences(of: row, with: row + row))["2026-09-21"])
        XCTAssertEqual(duplicate.count, 2)
        XCTAssertEqual(Set(duplicate.map(\.id)).count, 2)
    }
    func testAnyNumberOfReturnedDatesIsAccepted() throws {
        let date = try XCTUnwrap(CampusDate.formatter("yyyy-MM-dd").date(from: "2026-09-21"))
        let first = try html()
        for count in [1, 5, 6, 14, 21] {
            let dates = try (0..<count).map { offset in
                CampusDate.key(try XCTUnwrap(CampusDate.calendar.date(byAdding: .day, value: offset, to: date)))
            }
            let response = dates.map { day in
                first.replacingOccurrences(of: "day20260921", with: "day" + day.replacingOccurrences(of: "-", with: ""))
            }.joined()
            let window = try PortalParser.mergeSchedule([parseHTML(response)])
            XCTAssertEqual(window.days, dates)
            XCTAssertEqual(window.items.count, count)
        }
    }
    func testDatedEmptyTableIsSavedWithoutInventingOtherDays() throws {
        let value = "<div class='tab-content'><div class='tab-pane' id='day20260922'><table class='schedule-table'><tbody>  </tbody></table></div></div>"
        let window = try PortalParser.mergeSchedule([parseHTML(html() + value)])
        XCTAssertEqual(window.days, ["2026-09-21", "2026-09-22"])
        XCTAssertEqual(window.items.count, 1)
        XCTAssertTrue(window.items.filter { $0.day == "2026-09-22" }.isEmpty)
        XCTAssertFalse(window.days.contains("2026-09-23"))
    }
    func testFiveDaySnapshotSurvivesCacheRoundTripAndCanShrinkOnRefresh() throws {
        let first = try html()
        let days = ["20260921", "20260922", "20260923", "20260924", "20260925"]
        let response = days.map { first.replacingOccurrences(of: "day20260921", with: "day" + $0) }.joined()
        let window = try PortalParser.mergeSchedule([parseHTML(response)])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = CacheStore(url: folder.appendingPathComponent("snapshot.json"))
        let fetchedAt = Date(timeIntervalSince1970: 1_790_000_000)
        var snapshot = PortalSnapshot()
        snapshot.schedule = CachedSection(value: window, fetchedAt: fetchedAt, sources: [source])
        try cache.save(snapshot)
        let loaded = try XCTUnwrap(cache.load()?.schedule)
        XCTAssertEqual(loaded.value, window)
        XCTAssertEqual(loaded.fetchedAt, fetchedAt)
        XCTAssertEqual(loaded.sources, [source])
        snapshot.schedule = CachedSection(value: try PortalParser.mergeSchedule([parseHTML(first)]), fetchedAt: fetchedAt, sources: [source])
        try cache.save(snapshot)
        XCTAssertEqual(try cache.load()?.schedule?.value.days, ["2026-09-21"])
    }
    func testRefreshRetainsDatesOutsideResponseButReplacesExplicitlyEmptyDay() throws {
        let prior = try PortalParser.mergeSchedule([parseHTML(html())])
        let empty = ScheduleWindow(days: ["2026-09-22"], items: [], origin: .portal)
        let history = PortalParser.preservingScheduleHistory(empty, previous: prior)
        XCTAssertEqual(history.days, ["2026-09-21", "2026-09-22"])
        XCTAssertEqual(history.items.count, prior.items.count)
        let cancelled = PortalParser.preservingScheduleHistory(ScheduleWindow(days: ["2026-09-21"], items: [], origin: .portal), previous: history)
        XCTAssertTrue(cancelled.items.isEmpty)
        XCTAssertEqual(cancelled.days.count, 2)
    }
    private func twoWeekFixture() throws -> String {
        let bundle = Bundle(for: AjaxScheduleTests.self)
        let name = "ajax_schedule_two_weeks_synthetic"
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
                               ?? bundle.url(forResource: name, withExtension: "json"))
        return try String(contentsOf: url, encoding: .utf8)
    }
    func testHiddenSecondWeekPanelIncludesLessonsAndExplicitEmptySundays() throws {
        // The wrapper comes from version2.html; dates/lessons are synthetic.
        let days = try PortalParser.parseAjaxSchedule(jsonString: twoWeekFixture(), source: source)
        let window = try PortalParser.mergeSchedule([days])
        XCTAssertEqual(window.days.count, 14)
        XCTAssertEqual(window.days.first, "2026-10-05")
        XCTAssertEqual(window.days.last, "2026-10-18")
        XCTAssertEqual(window.items.count, 12)
        XCTAssertEqual(days["2026-10-12"]?.first?.teacher, "Тестовый Преподаватель Один")
        XCTAssertEqual(days["2026-10-11"], [])
        XCTAssertEqual(days["2026-10-18"], [])
    }
    func testFortnightRefreshKeepsOlderHistoryAndManualDisplayIndependent() throws {
        let previous = try PortalParser.mergeSchedule([parseHTML(html())])
        let observed = try PortalParser.mergeSchedule([
            PortalParser.parseAjaxSchedule(jsonString: twoWeekFixture(), source: source)
        ])
        let history = PortalParser.preservingScheduleHistory(observed, previous: previous)
        XCTAssertEqual(history.days.count, 15)
        XCTAssertEqual(history.items.count, 13)
        var snapshot = PortalSnapshot()
        snapshot.portalSchedule = CachedSection(value: history, fetchedAt: Date(), sources: [source])
        let display = ManualSchedule.applying(to: snapshot)
        XCTAssertEqual(display.portalSchedule?.value, history)
        XCTAssertEqual(display.schedule?.value, ManualSchedule.window)
    }
    func testLoaderWithoutLessonsCannotBecomeAnEmptySchedule() {
        XCTAssertThrowsError(try parseHTML("<div id='schedule-container'>Загрузка расписания...</div>"))
    }
    func testMAXModalInsideJSONRequiresLoginInsteadOfReplacingSchedule() {
        XCTAssertThrowsError(try parseHTML("<div class='loginwait-modal' role='dialog'>Код из MAX</div>")) { error in
            guard let failure = error as? PortalFailure, case .loginRequired = failure else {
                return XCTFail("Expected loginRequired, got \(error)")
            }
        }
    }
}
