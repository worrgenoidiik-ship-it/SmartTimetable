import XCTest
@testable import SmartTable

// Inline fixtures test edge cases. Fixtures/academic_progress.html is sanitized real portal markup.
final class SmartTableCoreTests: XCTestCase {
    private let url = URL(string: "https://portal.ulsu.ru/blocks/buttons/academic_progress.php")!
    private let headers = "<tr><th>Дисциплина</th><th>Вид контроля</th><th>Оценка</th><th>Дата</th><th>Преподаватель</th></tr>"
    private var example: String {
        "<table id='att0'>" + headers + "<tr><td>Алгебра</td><td>Экзамен</td><td>5</td><td>23.09.2026</td><td>Иванов И. И.</td></tr></table>"
    }
    func testLoginPageDoesNotCountAsAuthenticated() {
        XCTAssertThrowsError(try PortalParser.authenticatedProfile(html: "<form id='login'><input name='logintoken'></form>", url: url))
    }
    func testWaitPageCannotCountAsAuthenticatedEvenWithUserName() {
        let wait = URL(string: "https://portal.ulsu.ru/wait.php")!
        let html = "<span class='usertext'>Тестовый студент</span><a href='/login/logout.php'>Выход</a>"
        XCTAssertThrowsError(try PortalParser.authenticatedProfile(html: html, url: wait))
    }
    func testSuccessfulProfileRequiresPositiveMarkers() throws {
        let html = "<div class='usermenu'><span class='usertext'>Тестовый студент</span><a href='/user/profile.php?id=42'>Профиль</a><a href='/login/logout.php'>Выход</a></div>"
        let profile = try PortalParser.authenticatedProfile(html: html, url: url)
        XCTAssertEqual(profile.name, "Тестовый студент")
        XCTAssertFalse(profile.identityUsesName)
        XCTAssertThrowsError(try PortalParser.authenticatedProfile(html: "<h1>Техработы</h1>", url: url))
    }
    func testMissingTableAndUnconfirmedEmptyTableAreRejected() {
        XCTAssertThrowsError(try PortalParser.grades(html: "<html>Ошибка</html>", mapping: GradeTableMapping(selector: "#att0"), source: url))
        XCTAssertThrowsError(try PortalParser.grades(html: "<table id='att0'>" + headers + "</table>", mapping: GradeTableMapping(selector: "#att0"), source: url))
    }
    func testConfirmedEmptyTableIsAccepted() throws {
        var mapping = GradeTableMapping(selector: "#att0"); mapping.emptySelector = ".confirmed-empty"
        let html = "<table id='att0'>" + headers + "<tr><td colspan='5'><span class='confirmed-empty'>Нет записей</span></td></tr></table>"
        XCTAssertTrue(try PortalParser.grades(html: html, mapping: mapping, source: url).isEmpty)
    }
    func testTeacherInitialsArePreservedWithoutInventingNames() throws {
        let rows = try PortalParser.grades(html: example, mapping: GradeTableMapping(selector: "#att0"), source: url)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.teacher, "Иванов И. И.")
        XCTAssertEqual(rows.first?.grade, "5")
    }
    func testReorderedColumnsUseHeaders() throws {
        let html = "<table id='att0'><tr><th>Преподаватель</th><th>Дата</th><th>Дисциплина</th><th>Оценка</th><th>Вид контроля</th></tr><tr><td>Иванов Иван Иванович</td><td>23.09.2026</td><td>Алгебра</td><td>Зачтено</td><td>Зачёт</td></tr></table>"
        let row = try XCTUnwrap(PortalParser.grades(html: html, mapping: GradeTableMapping(selector: "#att0"), source: url).first)
        XCTAssertEqual(row.subject, "Алгебра")
        XCTAssertEqual(row.teacher, "Иванов Иван Иванович")
        XCTAssertEqual(row.type, "Зачёт")
    }
    func testMalformedRowRejectsWholeSection() {
        let broken = example.replacingOccurrences(of: "</table>", with: "<tr><td>Обрезанная строка</td></tr></table>")
        XCTAssertThrowsError(try PortalParser.grades(html: broken, mapping: GradeTableMapping(selector: "#att0"), source: url))
    }
    func testReturnedDatesSortAcrossTheYearBoundaryWithoutPadding() throws {
        let days: [String: [ScheduleItem]] = ["2027-01-04": [], "2026-12-28": []]
        let window = try PortalParser.mergeSchedule([days])
        XCTAssertEqual(window.days, ["2026-12-28", "2027-01-04"])
    }
    func testFiveReturnedDaysAreAcceptedWithoutMissingDates() throws {
        let days = ["2026-09-21", "2026-09-22", "2026-09-24", "2026-09-25", "2026-09-26"]
        let response = Dictionary(uniqueKeysWithValues: days.map { ($0, [ScheduleItem]()) })
        let window = try PortalParser.mergeSchedule([response])
        XCTAssertEqual(window.days, days)
        XCTAssertFalse(window.days.contains("2026-09-23"))
    }
    func testOneReturnedEmptyDayIsValidButNoDatesAreRejected() throws {
        let window = try PortalParser.mergeSchedule([["2026-09-21": []]])
        XCTAssertEqual(window.days, ["2026-09-21"])
        XCTAssertTrue(window.items.isEmpty)
        XCTAssertThrowsError(try PortalParser.mergeSchedule([]))
        XCTAssertThrowsError(try PortalParser.mergeSchedule([[:]]))
    }
    func testConflictingSchedulePagesAreRejected() {
        let day = "2026-09-21"
        let lesson = ScheduleItem(id: "test", day: day, timeStart: "08:00", timeEnd: "09:20", type: "Лекция", subject: "Тест", teacher: "", place: "", subgroup: "")
        XCTAssertThrowsError(try PortalParser.mergeSchedule([[day: []], [day: [lesson]]]))
    }
    func testScheduleMergingRejectsImpossibleDatesAndMisplacedLessons() {
        XCTAssertThrowsError(try PortalParser.mergeSchedule([["2026-02-30": []]]))
        let lesson = ScheduleItem(id: "test", day: "2026-09-22", timeStart: "08:00", timeEnd: "09:20", type: "Лекция", subject: "Тест", teacher: "", place: "", subgroup: "")
        XCTAssertThrowsError(try PortalParser.mergeSchedule([["2026-09-21": [lesson]]]))
    }
    func testLookalikeDomainsAndNonHTTPSAreRejected() {
        XCTAssertFalse(PortalConfiguration.allowsDataURL(URL(string: "https://portal.ulsu.ru.evil.example/test")!))
        XCTAssertFalse(PortalConfiguration.allowsBrowserURL(URL(string: "https://evilulsu.ru")!))
        XCTAssertFalse(PortalConfiguration.allowsDataURL(URL(string: "http://portal.ulsu.ru/my/")!))
        XCTAssertFalse(PortalConfiguration.isUniversityCookieDomain("ulsu.ru.evil.example"))
    }
    func testCourseLinksDeduplicateAndDoNotKeepSessionTokens() throws {
        let html = "<div id='region-main'><a href='/course/view.php?id=7&amp;sesskey=synthetic'>Математика</a><a href='/course/view.php?id=7'>Ещё ссылка</a><a href='https://evil.example/course/view.php?id=9'>Чужая</a></div>"
        let courses = try PortalParser.courses(html: html, source: url)
        XCTAssertEqual(courses.count, 1)
        XCTAssertEqual(courses.first?.url.absoluteString, "https://portal.ulsu.ru/course/view.php?id=7")
    }
    func testCacheRoundTripAndCorruptionIsNotAnEmptySuccess() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = CacheStore(url: folder.appendingPathComponent("snapshot.json"))
        var snapshot = PortalSnapshot()
        snapshot.profile = StudentProfile(accountKey: "test-account", name: "Тестовый студент", identityUsesName: false)
        snapshot.grades = CachedSection(value: try PortalParser.grades(html: example, mapping: GradeTableMapping(selector: "#att0"), source: url), fetchedAt: Date(), sources: [url])
        try cache.save(snapshot)
        XCTAssertEqual(try cache.load()?.grades?.value, snapshot.grades?.value)
        try Data("broken-json".utf8).write(to: cache.url)
        XCTAssertThrowsError(try cache.load())
    }
    private func fixtureURL(_ name: String, extension ext: String) throws -> URL {
        let bundle = Bundle(for: SmartTableCoreTests.self)
        return try XCTUnwrap(bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
                             ?? bundle.url(forResource: name, withExtension: ext))
    }
    private func academicFixture() throws -> String {
        try String(contentsOf: fixtureURL("academic_progress", extension: "html"), encoding: .utf8)
    }
    func testActualAcademicPageAllRowsAndFields() throws {
        struct Expected: Decodable {
            let semester: String; let subject: String; let date: String
            let type: String; let grade: String; let retake: String; let teachers: [String]
        }
        let expected = try JSONDecoder().decode([Expected].self, from: Data(contentsOf: fixtureURL("academic_progress.expected", extension: "json")))
        let rows = try PortalParser.academicProgress(html: academicFixture(), source: url)
        XCTAssertEqual(rows.count, 24)
        XCTAssertEqual(rows.filter { $0.semester == "1 семестр" }.count, 11)
        XCTAssertEqual(rows.filter { $0.semester == "2 семестр" }.count, 13)
        XCTAssertEqual(rows.count, expected.count)
        guard rows.count == expected.count else { return }
        for (actual, wanted) in zip(rows, expected) {
            XCTAssertEqual(actual.semester, wanted.semester)
            XCTAssertEqual(actual.subject, wanted.subject)
            XCTAssertEqual(actual.date, wanted.date)
            XCTAssertEqual(actual.type, wanted.type)
            XCTAssertEqual(actual.grade, wanted.grade)
            XCTAssertEqual(actual.retake ?? "", wanted.retake)
            XCTAssertEqual(actual.teacherNames, wanted.teachers)
        }
        XCTAssertEqual(Set(rows.map(\.id)).count, 24)
    }
    func testActualPageKeepsBothTeachersOnSeparateLines() throws {
        let rows = try PortalParser.academicProgress(html: academicFixture(), source: url)
        let row = try XCTUnwrap(rows.first { $0.subject == "Иностранный язык" && $0.semester == "2 семестр" })
        XCTAssertEqual(row.teacherNames, ["Морозова Инна Руслановна", "Фёдорова Алина Витальевна"])
    }
    func testMissingSemesterPaneRejectsEntireAcademicSnapshot() throws {
        let original = try academicFixture()
        let broken = original.replacingOccurrences(of: "id=\"ep2000000069\"", with: "id=\"missing-pane\"")
        XCTAssertNotEqual(broken, original)
        XCTAssertThrowsError(try PortalParser.academicProgress(html: broken, source: url))
    }
    func testMalformedSecondSemesterRejectsEntireAcademicSnapshot() throws {
        let original = try academicFixture()
        let broken = original.replacingOccurrences(of: #"<td[^>]*>Жуков Денис Витальевич<br>\s*</td>"#, with: "", options: .regularExpression)
        XCTAssertNotEqual(broken, original)
        XCTAssertThrowsError(try PortalParser.academicProgress(html: broken, source: url))
    }
    func testUnknownMarkHeaderIsNotSilentlyAccepted() throws {
        let original = try academicFixture()
        let broken = original.replacingOccurrences(of: ">Отметка<", with: ">Неизвестное поле<")
        XCTAssertNotEqual(broken, original)
        XCTAssertThrowsError(try PortalParser.academicProgress(html: broken, source: url))
    }
    func testActualAuthenticatedPageRequiresUniqueProfileID() throws {
        let original = try academicFixture()
        XCTAssertFalse(try PortalParser.authenticatedProfile(html: original, url: url).identityUsesName)
        let withoutID = original.replacingOccurrences(of: "/user/profile.php?id=42", with: "/user/profile.php")
        XCTAssertThrowsError(try PortalParser.authenticatedProfile(html: withoutID, url: url))
    }
    func testOlderCachedGradeWithoutRetakeFieldStillDecodes() throws {
        let json = #"{"id":"old","subject":"Алгебра","type":"Экзамен","grade":"5","date":"23.09.2026","teacher":"Иванов И. И.","semester":"1 семестр"}"#
        let grade = try JSONDecoder().decode(GradeItem.self, from: Data(json.utf8))
        XCTAssertEqual(grade.subject, "Алгебра")
        XCTAssertNil(grade.retake)
    }

}
