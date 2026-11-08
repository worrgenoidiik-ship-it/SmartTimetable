import XCTest
import SwiftUI
@testable import SmartTable

final class StudentContextTests: XCTestCase {
    private let url = URL(string: "https://portal.ulsu.ru/course/view.php?id=1")!
    private func course(_ title: String) -> Course { Course(id: title, title: title, teacher: "", url: url) }
    private func date(_ value: String) -> Date { CampusDate.formatter("yyyy-MM-dd").date(from: value)! }

    func testGroupComesFromCourseTitles() {
        let courses = [course("Базы данных ИС-О-25/1 (3 семестр, Комарова Юлиана Егоровна)"),
                       course("ИС_О_25/1_Web_технологии_4_415356"), course("История")]
        XCTAssertEqual(StudentGroup.detect(in: courses), "ИС-О-25/1")
        XCTAssertNil(StudentGroup.detect(in: [course("История")]))
    }

    func testCurrentSemesterFromEnrolmentYear() {
        XCTAssertEqual(StudentGroup.currentSemester(group: "ИС-О-25/1", on: date("2026-11-01")), 3)
        XCTAssertEqual(StudentGroup.currentSemester(group: "ИС-О-25/1", on: date("2027-01-15")), 3)
        XCTAssertEqual(StudentGroup.currentSemester(group: "ИС-О-25/1", on: date("2027-03-01")), 4)
        XCTAssertEqual(StudentGroup.currentSemester(group: "ИС-О-25/1", on: date("2025-10-01")), 1)
        XCTAssertNil(StudentGroup.currentSemester(group: nil))
    }

    func testAnotherGroupGetsThePortalScheduleInAuto() {
        let lesson = ScheduleItem(id: "p", day: "2026-11-02", timeStart: "08:00", timeEnd: "09:20", type: "", subject: "ЭИОС",
                                  teacher: "", place: "", subgroup: "")
        var snapshot = PortalSnapshot()
        snapshot.schedule = CachedSection(value: ManualSchedule.window, fetchedAt: Date(), sources: [])
        snapshot.portalSchedule = CachedSection(value: ScheduleWindow(days: ["2026-11-02"], items: [lesson], origin: .portal),
                                                fetchedAt: Date(), sources: [])
        snapshot.courses = CachedSection(value: [course("Физика ПИ-О-24/2 (5 семестр)")], fetchedAt: Date(), sources: [])
        XCTAssertFalse(StudentGroup.planApplies(to: snapshot))
        XCTAssertEqual(ScheduleSource.window(of: snapshot, mode: .auto)?.value.items.map(\.subject), ["ЭИОС"])
        snapshot.courses = CachedSection(value: [course("Базы данных ИС-О-25/1 (3 семестр)")], fetchedAt: Date(), sources: [])
        XCTAssertTrue(StudentGroup.planApplies(to: snapshot))
    }

    // Markup from the saved CDO_questionizer.html (e-mail replaced).
    func testQuestionFormFromThePortalPage() throws {
        let html = """
        <div class="container-fluid"><div class="form-group"><select class="select custom-select selectpicker" id="cat" name="faculty"><option value="8ad18a8c-ff00-11e9-80ca-ac1f6b415db5">Общие вопросы</option><option value="be0b8520-ff00-11e9-80ca-ac1f6b415db5">Учебный процесс</option><option value="c6ec5ef4-ffb8-11e9-80ca-ac1f6b415db5">Финансовые вопросы</option></select><label>Тема:</label><input id="subject" type="text"></div><div class="form-group"><label>Вопрос:</label><textarea id="message" type="text"></textarea></div><div class="form-group"><label>EMAIL:</label><input id="reply_type" type="text" value="student@ulsu.ru"></div></div>
        """
        let form = try PortalParser.questionForm(html: html, source: PortalConfiguration.questionURL)
        XCTAssertEqual(form.categories.map(\.title), ["Общие вопросы", "Учебный процесс", "Финансовые вопросы"])
        XCTAssertEqual(form.categories.first?.id, "8ad18a8c-ff00-11e9-80ca-ac1f6b415db5")
        XCTAssertEqual(form.email, "student@ulsu.ru")
        XCTAssertThrowsError(try PortalParser.questionForm(html: "<p>нет формы</p>", source: PortalConfiguration.questionURL))
    }

    func testWinterAndColourStorage() {
        XCTAssertTrue(ChristmasMode.isWinter(date("2026-12-01")))
        XCTAssertTrue(ChristmasMode.isWinter(date("2027-02-28")))
        XCTAssertFalse(ChristmasMode.isWinter(date("2026-11-30")))
        XCTAssertFalse(ChristmasMode.isWinter(date("2027-03-01")))
        let colour = Color(.sRGB, red: 1, green: 0.5, blue: 0, opacity: 1)
        XCTAssertEqual(colour.hexString, "FF8000FF")
        XCTAssertEqual(Color(hex: "FF8000FF")?.hexString, "FF8000FF")
        XCTAssertNil(Color(hex: "xyz"))
    }
}
