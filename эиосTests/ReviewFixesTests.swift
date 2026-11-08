import XCTest
@testable import SmartTable

/// 1.9.2: bugs found in the external code review.
@MainActor
final class ReviewFixesTests: XCTestCase {

    /// The semester starts on Tuesday 9 February 2027; a week-one Monday lesson belongs to
    /// Monday 22 February, not to Monday 15 February (that Monday is already week two).
    func testWeeksSwitchOnMondayWhenSemesterStartsMidWeek() {
        let monday = LessonTemplate(weekday: 1, number: 1, subject: "Матанализ", type: "", teacher: "", place: "")
        let plan = ManualPlan(group: "ИС-О-25/1", firstDay: "2027-02-09", lastDay: "2027-03-07", revisionDay: "2027-03-08",
                              weekOne: [monday], weekTwo: [], revisedWeekOne: [], revisedWeekTwo: [], firstWeekNumber: 1)
        let days = ManualSchedule.build(plan).items.map(\.day)
        XCTAssertEqual(days, ["2027-02-22"]) // was ["2027-02-15", "2027-03-01"]
    }

    /// The default plan starts on a Monday: nothing moves.
    func testMondayStartIsUnchanged() {
        let monday = LessonTemplate(weekday: 1, number: 1, subject: "Матанализ", type: "", teacher: "", place: "")
        let plan = ManualPlan(group: "ИС-О-25/1", firstDay: "2026-09-21", lastDay: "2026-10-11", revisionDay: "2026-10-12",
                              weekOne: [], weekTwo: [monday], revisedWeekOne: [], revisedWeekTwo: [])
        XCTAssertEqual(ManualSchedule.build(plan).items.map(\.day), ["2026-09-21", "2026-10-05"])
    }

    func testSubgroupTenIsNotSubgroupOne() {
        XCTAssertFalse(StudentGroup.sameGroup("ИС-О-25/10", "ИС-О-25/1"))
        XCTAssertFalse(StudentGroup.sameGroup("ИС-О-25/1", "ИС-О-25/10"))
        XCTAssertTrue(StudentGroup.sameGroup("ИС_О_25/1", "ИС-О-25/1"))
        XCTAssertTrue(StudentGroup.sameGroup("ИС-О-25", "ИС-О-25/1")) // subgroup unknown
        XCTAssertFalse(StudentGroup.sameGroup("ИС-О-24/1", "ИС-О-25/1"))
    }

    func testMessengerResetDropsPreviousAccountChats() {
        Messenger.shared.reset()
        XCTAssertTrue(Messenger.shared.conversations.isEmpty)
        XCTAssertNil(Messenger.shared.myID)
        XCTAssertFalse(Messenger.shared.loading)
    }
}
