import XCTest
@testable import SmartTable

final class EnrichmentAndFormsTests: XCTestCase {
    private let courseURL = URL(string: "https://portal.ulsu.ru/course/view.php?id=1")!
    private func lesson(_ day: String, _ start: String, _ subject: String, teacher: String = "", place: String = "") -> ScheduleItem {
        ScheduleItem(id: day + start + subject, day: day, timeStart: start, timeEnd: "23:00", type: "", subject: subject,
                     teacher: teacher, place: place, subgroup: "")
    }

    func testTeachersComeFromCourseTitlesWhenInitialsAgree() {
        let courses = [
            Course(id: "1", title: "Психология и педагогика ИС-О-25/1 (3 семестр,Данилова Жанна Никитична)", teacher: "", url: courseURL),
            Course(id: "2", title: "Ознакомительная практика ИС-О-25/1 (3 семестр,Комарова Юлиана Егоровна)", teacher: "", url: courseURL),
            Course(id: "3", title: "Иностранный язык ИС-О-25/1 (3 семестр,Морозова Инна Руслановна)", teacher: "", url: courseURL),
        ]
        let window = ScheduleWindow(days: ["2026-11-05"], items: [
            lesson("2026-11-05", "14:15", "Психология и педагогика", teacher: "Ж. Н. Донилова"),
            lesson("2026-11-05", "11:00", "Ознакомительная практика"),
            lesson("2026-11-05", "09:30", "Английский язык"),
            lesson("2026-11-05", "08:00", "Психология и педагогика", teacher: "А. Б. Другой"),
            lesson("2026-11-05", "12:45", "Базы данных", teacher: "Комарова Юлиана Егоровна"),
        ], origin: .manual)
        let teachers = ScheduleEnricher.enrich(window, courses: courses, portal: nil).items.map(\.teacher)
        XCTAssertEqual(teachers, ["Данилова Жанна Никитична", "Комарова Юлиана Егоровна", "Морозова Инна Руслановна",
                                  "А. Б. Другой", "Комарова Юлиана Егоровна"])
    }

    func testRoomComesFromThePortalSlotOfTheSameSubject() {
        // 2026-11-05 and 2026-11-12 are both Thursdays.
        let portal = ScheduleWindow(days: ["2026-11-12"], items: [
            lesson("2026-11-12", "11:00", "Базы данных", place: "3/118"),
            lesson("2026-11-12", "11:00", "Физика", place: "2/20"),
        ], origin: .portal)
        let plan = ScheduleWindow(days: ["2026-11-05"], items: [
            lesson("2026-11-05", "11:00", "Базы данных"),
            lesson("2026-11-05", "12:45", "Базы данных"),
        ], origin: .manual)
        let places = ScheduleEnricher.enrich(plan, courses: [], portal: portal).items.map(\.place)
        XCTAssertEqual(places, ["3/118", ""])
    }

    func testTimelineEvents() throws {
        let data: [String: Any] = ["events": [[
            "id": 77, "name": "Лабораторная работа №1 — срок сдачи", "modulename": "assign", "timesort": 1_793_600_000,
            "url": "https://portal.ulsu.ru/mod/assign/view.php?id=2461106",
            "course": ["fullname": "Базы данных ИС-О-25/1 (3 семестр,Комарова Юлиана Егоровна)"],
        ]]]
        let item = try XCTUnwrap(PortalParser.actionEvents(data).first)
        XCTAssertEqual(item.kindLabel, "Задание")
        XCTAssertEqual(item.course, "Базы данных")
        XCTAssertEqual(item.due, Date(timeIntervalSince1970: 1_793_600_000))
        XCTAssertThrowsError(try PortalParser.actionEvents(["warnings": []]))
    }

    // Structure of the second «Заказ справок» form (values replaced): three fields share one id.
    func testFormLabelsComeFromTheirRows() throws {
        let html = """
        <section id="region-main"><form class="forminquiry mform" action="https://portal.ulsu.ru/CDO/inquiry/index.php" method="post">
        <input name="record_book" type="hidden" value="1"><input name="sesskey" type="hidden" value="AbCdEf1234">
        <div class="form-group row fitem"><label for="id_form_fields_"> Телефон для связи </label><input type="text" name="form_fields[Телефон]" id="id_form_fields_" value=""></div>
        <div class="form-group row fitem"><label for="id_form_fields_"> Комментарий </label><input type="text" name="form_fields[КомментарииСтудента]" id="id_form_fields_" value=""></div>
        <div class="form-group row fitem"><label for="id_form_fields_"> Вид печати </label><select name="form_fields[ВидПечати]" id="id_form_fields_"><option value="1">без герба</option><option value="2">Герб</option></select></div>
        <input type="submit" name="submitbutton" value="Отправить запрос"></form></section>
        """
        let form = try XCTUnwrap(PortalParser.forms(html: html, source: PortalConfiguration.inquiryURL).first)
        XCTAssertTrue(form.isPost)
        XCTAssertEqual(form.visibleFields.map(\.label), ["Телефон для связи", "Комментарий", "Вид печати"])
        XCTAssertEqual(form.visibleFields.last?.options.map(\.title), ["без герба", "Герб"])
        let payload = form.payload(["form_fields[Телефон]": "+7 900 000-00-00"])
        XCTAssertTrue(payload.contains(URLQueryItem(name: "sesskey", value: "AbCdEf1234")))
        XCTAssertTrue(payload.contains(URLQueryItem(name: "form_fields[Телефон]", value: "+7 900 000-00-00")))
        XCTAssertTrue(payload.contains(URLQueryItem(name: "form_fields[ВидПечати]", value: "1")))
        XCTAssertTrue(payload.contains(URLQueryItem(name: "submitbutton", value: "Отправить запрос")))
    }

    func testBareTextPageIsANoticeNotAnError() throws {
        let html = "<html><head><title>Текущая успеваемость</title></head><body><section id='region-main'><div role='main'><span id='maincontent'></span>Текущая успеваемость не найдена!</div></section></body></html>"
        let document = try PortalParser.document(html: html, source: PortalPageKind.attestation.url)
        XCTAssertEqual(document.paragraphs, ["Текущая успеваемость не найдена!"])
    }
}

final class OverdueTests: XCTestCase {
    func testOverdueListIsNewestFirstAndOnlyPast() {
        let network = NetworkManager.shared
        let past1 = DeadlineItem(id: "1", title: "Лабораторная №1", course: "Базы данных", kind: "mod_assign", whenLabel: "",
                                 due: Date().addingTimeInterval(-10 * 86_400), url: nil)
        let past2 = DeadlineItem(id: "2", title: "Самостоятельная работа №1", course: "Маркетинг", kind: "mod_quiz", whenLabel: "",
                                 due: Date().addingTimeInterval(-2 * 86_400), url: nil)
        var snapshot = PortalSnapshot()
        snapshot.overdue = CachedSection(value: [past1, past2], fetchedAt: Date(), sources: [])
        XCTAssertEqual(snapshot.overdue?.value.sorted { ($0.due ?? .distantPast) > ($1.due ?? .distantPast) }.map(\.id), ["2", "1"])
        XCTAssertEqual(past2.kindLabel, "Самостоятельная работа")
        _ = network // the same ordering is used by NetworkManager.overdue
        let decoded = try? JSONDecoder().decode(PortalSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded?.overdue?.value.count, 2)
    }
}
