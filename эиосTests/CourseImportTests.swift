import XCTest
@testable import SmartTable

final class CourseImportTests: XCTestCase {
    private let source = PortalConfiguration.coursesURL

    func testPlaceholderWithoutRenderedCardsIsNotAnEmptySuccess() {
        XCTAssertThrowsError(try PortalParser.courses(html: "<main id='region-main'><div>Загрузка…</div></main>", source: source))
    }

    func testRenderedCardsUseRealCourseIDsAndExcludeOtherHosts() throws {
        let html = """
        <main id="region-main">
          <a href="/course/view.php?id=17&amp;sesskey=synthetic">Базы <span>данных</span></a>
          <a href="/course/view.php?id=17">Базы данных</a>
          <a href="https://other.example/course/view.php?id=18">Чужой сайт</a>
          <a href="/course/view.php?id=0">Не курс</a>
        </main>
        """
        let items = try PortalParser.courses(html: html, source: source)
        XCTAssertEqual(items.map(\.id), ["17"])
        XCTAssertEqual(items.first?.title, "Базы данных")
        XCTAssertEqual(items.first?.url.absoluteString, "https://portal.ulsu.ru/course/view.php?id=17")
        XCTAssertEqual(items.first?.teacher, "")
    }

    func testPartialDashboardUpdatesExistingCardsWithoutErasingOtherCourses() throws {
        let cached = try PortalParser.courses(html: "<main id='region-main'><a href='/course/view.php?id=1'>Один</a><a href='/course/view.php?id=2'>Старое имя</a></main>", source: source)
        let observed = try PortalParser.courses(html: "<main id='region-main'><a href='/course/view.php?id=2'>Новое имя</a><a href='/course/view.php?id=3'>Три</a></main>", source: source)
        let merged = PortalParser.mergingObservedCourses(observed, into: cached)
        XCTAssertEqual(merged.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(merged.map(\.title), ["Один", "Новое имя", "Три"])
        XCTAssertEqual(PortalParser.mergingObservedCourses(observed, into: merged), merged)
    }
}
