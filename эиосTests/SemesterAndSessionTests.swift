import XCTest
@testable import SmartTable

/// 1.3: a new semester without reinstalling, and the session keep-alive.
final class SemesterAndSessionTests: XCTestCase {
    private func androidPlanData() throws -> Data {
        let bundle = Bundle(for: SemesterAndSessionTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "manual_schedule_android", withExtension: "json", subdirectory: "Fixtures")
                                ?? bundle.url(forResource: "manual_schedule_android", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testAndroidPlanFileProducesTheSameCalendarAsTheBuiltInPlan() throws {
        let plan = try JSONDecoder().decode(ManualPlan.self, from: androidPlanData()).validated()
        let fromFile = ManualSchedule.build(plan)
        let builtIn = ManualSchedule.build(ManualSchedule.builtinPlan)
        XCTAssertEqual(fromFile.days, builtIn.days)
        XCTAssertEqual(fromFile.items, builtIn.items)
    }

    func testPlanJSONRoundTripsAndOptionalFieldsChangeTheCalendar() throws {
        var plan = ManualSchedule.builtinPlan
        plan.times = ["1": ["08:30", "09:50"]]
        plan.firstWeekNumber = 1
        let decoded = try JSONDecoder().decode(ManualPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded, plan)
        let window = ManualSchedule.build(decoded)
        XCTAssertTrue(window.items.filter { $0.lessonNumber == 1 }.allSatisfy { $0.timeStart == "08:30" })
        XCTAssertNotEqual(window.items, ManualSchedule.build(ManualSchedule.builtinPlan).items)
    }

    func testBrokenPlansAreRejected() {
        let lesson = LessonTemplate(weekday: 1, number: 1, subject: "Матанализ", type: "", teacher: "", place: "")
        func plan(first: String = "2027-02-09", last: String = "2027-06-30", lessons: [LessonTemplate] = [lesson],
                  times: [String: [String]]? = nil) -> ManualPlan {
            ManualPlan(group: "ИС-О-25/1", firstDay: first, lastDay: last, revisionDay: last,
                       weekOne: lessons, weekTwo: lessons, revisedWeekOne: [], revisedWeekTwo: [], times: times)
        }
        XCTAssertNoThrow(try plan().validated())
        XCTAssertThrowsError(try plan(first: "2027-06-30", last: "2027-02-09").validated())
        XCTAssertThrowsError(try plan(first: "2027-02-30").validated())
        XCTAssertThrowsError(try plan(last: "2029-01-01").validated())
        XCTAssertThrowsError(try plan(lessons: [LessonTemplate(weekday: 8, number: 1, subject: "x", type: "", teacher: "", place: "")]).validated())
        XCTAssertThrowsError(try plan(times: ["1": ["10:00", "09:00"]]).validated())
        XCTAssertThrowsError(try ManualPlanStore.importPlan(Data("not json".utf8)))
    }

    func testAutoModeUsesThePlanInsideItsPeriodAndThePortalAfterIt() {
        let lesson = { (day: String, subject: String) in
            ScheduleItem(id: day + subject, day: day, timeStart: "08:00", timeEnd: "09:20", type: "", subject: subject,
                         teacher: "", place: "", subgroup: "")
        }
        var snapshot = PortalSnapshot()
        snapshot.schedule = CachedSection(value: ScheduleWindow(days: ["2026-12-30", "2026-12-31"],
                                                                items: [lesson("2026-12-30", "План")], origin: .manual),
                                          fetchedAt: Date(), sources: [])
        snapshot.portalSchedule = CachedSection(value: ScheduleWindow(days: ["2026-12-30", "2027-02-09"],
                                                                      items: [lesson("2026-12-30", "ЭИОС"), lesson("2027-02-09", "Новый семестр")],
                                                                      origin: .portal), fetchedAt: Date(), sources: [])
        let auto = ScheduleSource.window(of: snapshot, mode: .auto)?.value
        XCTAssertEqual(auto?.days, ["2026-12-30", "2026-12-31", "2027-02-09"])
        XCTAssertEqual(auto?.items.map(\.subject), ["План", "Новый семестр"])
        XCTAssertTrue(ScheduleSource.isPlanned("2026-12-31", in: snapshot, mode: .auto))
        XCTAssertFalse(ScheduleSource.isPlanned("2027-02-09", in: snapshot, mode: .auto))
        XCTAssertEqual(ScheduleSource.window(of: snapshot, mode: .portal)?.value.items.count, 2)
        snapshot.portalSchedule = nil
        XCTAssertEqual(ScheduleSource.window(of: snapshot, mode: .auto)?.value, snapshot.schedule?.value)
    }

    func testCoursesKeepLastSeenSoOldSemestersCanBeArchived() {
        let url = URL(string: "https://portal.ulsu.ru/course/view.php?id=1")!
        let old = Course(id: "1", title: "Старый", teacher: "", url: url, lastSeen: Date(timeIntervalSince1970: 0))
        let current = Course(id: "2", title: "Новый", teacher: "", url: url)
        let now = Date()
        let merged = PortalParser.mergingObservedCourses([current], into: [old], seenAt: now)
        XCTAssertEqual(merged.map(\.id), ["1", "2"])
        XCTAssertEqual(merged[0].lastSeen, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(merged[1].lastSeen, now)
    }

    func testSesskeyAndKeepAliveAnswers() throws {
        XCTAssertEqual(PortalParser.sesskey(in: #"M.cfg = {"wwwroot":"https:\/\/portal.ulsu.ru","sesskey":"AbCdEf1234","sessiontimeout":"28800"};"#), "AbCdEf1234")
        XCTAssertNil(PortalParser.sesskey(in: "<html>нет ключа</html>"))
        let ok = Data(#"[{"error":false,"data":true},{"error":false,"data":{"userid":42,"timeremaining":7199}}]"#.utf8)
        XCTAssertEqual(try PortalParser.sessionTouchResult(ok), 7199)
        let expired = Data(#"[{"error":true,"exception":{"errorcode":"servicerequireslogin"}}]"#.utf8)
        XCTAssertThrowsError(try PortalParser.sessionTouchResult(expired)) { error in
            guard case .loginRequired? = error as? PortalFailure else { return XCTFail("\(error)") }
        }
        let invalidSesskey = Data(#"{"error":"Неверный ключ сессии","errorcode":"invalidsesskey"}"#.utf8)
        XCTAssertThrowsError(try PortalParser.sessionTouchResult(invalidSesskey))
        XCTAssertNil(try PortalParser.sessionTouchResult(Data(#"[{"error":false,"data":true}]"#.utf8)))
    }
}
