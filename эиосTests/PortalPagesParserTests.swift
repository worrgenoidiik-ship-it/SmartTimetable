import XCTest
@testable import SmartTable

final class PortalPagesParserTests: XCTestCase {
    private let base = URL(string: "https://portal.ulsu.ru/my/")!

    private func page(_ main: String) -> String {
        "<html><head><title>Текущая успеваемость: ЭИОС</title></head><body><section id='region-main'><div role='main'>\(main)</div></section></body></html>"
    }

    // Markup copied from the news_items block of the saved dashboard (version2.html).
    func testNewsBlockFromDashboard() throws {
        let html = """
        <html><body><section data-block="news_items"><ul class='unlist'>
        <div class="post post-custom"><div class="head clearfix"><div class="date">7 Sep 15:26</div><div class="name">ФГБОУ ВО Ульяновский государственный университет</div></div><div class="info"><a href="https://portal.ulsu.ru/mod/forum/discuss.php?d=64781">Университетские курсы по выбору</a></div></div>
        <div class="post post-custom"><div class="head clearfix"><div class="date">3 Jun 13:48</div><div class="name">УлГУ</div></div><div class="info"><a href="https://evil.example/x">Чужая ссылка</a></div></div>
        </ul></section></body></html>
        """
        let news = try PortalParser.news(html: html, source: base)
        XCTAssertEqual(news.count, 1)
        XCTAssertEqual(news[0].id, "64781")
        XCTAssertEqual(news[0].title, "Университетские курсы по выбору")
        XCTAssertEqual(news[0].dateLabel, "7 Sep 15:26")
        XCTAssertThrowsError(try PortalParser.news(html: "<html><body></body></html>", source: base))
    }

    func testGenericDocumentReadsTabsTablesAndLinks() throws {
        let html = page("""
        <h2>Текущая успеваемость</h2>
        <ul><li><a href="#sem1">1 семестр</a></li></ul>
        <div class="tab-content"><div class="tab-pane" id="sem1">
        <table><thead><tr><th>Дисциплина</th><th>Аттестация 1</th><th>Аттестация 2</th></tr></thead>
        <tbody><tr><td>Математика</td><td>45</td><td>не аттестован</td></tr>
        <tr><td>История<br>России</td><td colspan="2">зачтено</td></tr></tbody></table>
        </div></div>
        <a href="/course/view.php?id=5">Курс</a><a href="https://portal.ulsu.ru/login/logout.php?sesskey=1">Выход</a>
        <script>var secret = 1;</script>
        """)
        let document = try PortalParser.document(html: html, source: PortalPageKind.attestation.url)
        XCTAssertEqual(document.title, "Текущая успеваемость")
        XCTAssertEqual(document.tables.count, 1)
        let table = document.tables[0]
        XCTAssertEqual(table.caption, "1 семестр")
        XCTAssertEqual(table.headers, ["Дисциплина", "Аттестация 1", "Аттестация 2"])
        XCTAssertEqual(table.rows, [["Математика", "45", "не аттестован"], ["История\nРоссии", "зачтено", ""]])
        XCTAssertEqual(document.links.map(\.url.absoluteString), ["https://portal.ulsu.ru/course/view.php?id=5"])
    }

    func testGenericDocumentWithoutContentIsAnError() {
        XCTAssertThrowsError(try PortalParser.document(html: page("<div></div>"), source: PortalPageKind.debts.url))
        XCTAssertThrowsError(try PortalParser.document(html: "<html><body><p>нет main</p></body></html>", source: PortalPageKind.debts.url))
        XCTAssertNoThrow(try PortalParser.document(html: page("<p>Задолженностей нет</p>"), source: PortalPageKind.debts.url))
    }

    func testCourseSectionsAndActivities() throws {
        let html = """
        <html><body><ul class="topics">
        <li id="section-0" class="section main"><h3 class="sectionname">Общее</h3><div class="summary">Добро пожаловать</div>
          <ul class="section"><li id="module-11" class="activity forum modtype_forum"><a class="aalink" href="https://portal.ulsu.ru/mod/forum/view.php?id=11"><span class="instancename">Объявления<span class="accesshide"> Форум</span></span></a></li></ul></li>
        <li id="section-1" class="section main"><h3 class="sectionname">Модуль 1</h3>
          <ul class="section">
          <li id="module-12" class="activity quiz modtype_quiz"><a class="aalink" href="https://portal.ulsu.ru/mod/quiz/view.php?id=12"><span class="instancename">Тест 1<span class="accesshide"> Тест</span></span></a><div class="activity-dates">Закрывается: 10 ноября 2026, 23:59</div></li>
          <li id="module-13" class="activity assign modtype_assign"><a class="aalink" href="/mod/assign/view.php?id=13"><span class="instancename">Лабораторная 1</span></a></li>
          <li id="module-14" class="activity label modtype_label"><div class="contentwithoutlink">Сдать до пятницы</div></li>
          </ul></li>
        </ul></body></html>
        """
        let sections = try PortalParser.courseContents(html: html, source: URL(string: "https://portal.ulsu.ru/course/view.php?id=5")!)
        XCTAssertEqual(sections.map(\.title), ["Общее", "Модуль 1"])
        XCTAssertEqual(sections[0].summary, "Добро пожаловать")
        XCTAssertEqual(sections[0].activities.first?.name, "Объявления")
        let module = sections[1].activities
        XCTAssertEqual(module.map(\.kind), ["quiz", "assign", "label"])
        XCTAssertEqual(module[0].name, "Тест 1")
        XCTAssertEqual(module[0].info, "Закрывается: 10 ноября 2026, 23:59")
        XCTAssertEqual(module[1].url?.absoluteString, "https://portal.ulsu.ru/mod/assign/view.php?id=13")
        XCTAssertEqual(module[2].name, "Сдать до пятницы")
        XCTAssertThrowsError(try PortalParser.courseContents(html: "<html><body></body></html>", source: base))
    }

    func testUpcomingDeadlinesWithExactTime() throws {
        // 1793476800 = 2026-10-31T20:00:00Z = 1 November 00:00 in Europe/Samara.
        let html = page("""
        <div class="eventlist">
        <div class="event" data-type="event" data-event-id="900" data-event-component="mod_quiz" data-event-title="Тест 1 закрывается">
          <h3 class="name">Тест 1 закрывается</h3>
          <div class="description"><div class="row"><a href="https://portal.ulsu.ru/calendar/view.php?view=day&amp;time=1793476800">Воскресенье, 1 ноября</a>, 23:59</div>
          <div class="row"><a href="https://portal.ulsu.ru/course/view.php?id=5">Программирование</a></div></div>
          <div class="card-footer"><a class="card-link" href="https://portal.ulsu.ru/mod/quiz/view.php?id=12">Перейти к элементу курса</a></div>
        </div>
        <div class="event" data-type="event" data-event-id="901" data-event-component="mod_assign" data-event-title="Отчёт">
          <div class="description"><div class="row">Скоро</div></div>
        </div></div>
        """)
        let items = try PortalParser.deadlines(html: html, source: PortalConfiguration.calendarURL)
        XCTAssertEqual(items.map(\.id), ["900", "901"])
        XCTAssertEqual(items[0].kindLabel, "Тест")
        XCTAssertEqual(items[0].course, "Программирование")
        XCTAssertEqual(items[0].url?.absoluteString, "https://portal.ulsu.ru/mod/quiz/view.php?id=12")
        let expected = CampusDate.formatter("yyyy-MM-dd HH:mm").date(from: "2026-11-01 23:59")
        XCTAssertEqual(items[0].due, expected)
        XCTAssertNil(items[1].due)
        XCTAssertEqual(try PortalParser.deadlines(html: page("<p>Нет предстоящих событий</p>"), source: PortalConfiguration.calendarURL), [])
        XCTAssertThrowsError(try PortalParser.deadlines(html: page("<p>Загрузка…</p>"), source: PortalConfiguration.calendarURL))
    }

    func testWidgetPayloadKeepsOnlyUpcomingLessonsAndTimedDeadlines() {
        let now = CampusDate.formatter("yyyy-MM-dd HH:mm").date(from: "2026-11-02 12:00")!
        var snapshot = PortalSnapshot()
        snapshot.schedule = CachedSection(value: ScheduleWindow(days: ["2026-11-01", "2026-11-02"], items: [
            ScheduleItem(id: "a", day: "2026-11-01", timeStart: "08:00", timeEnd: "09:20", type: "", subject: "Вчера", teacher: "", place: "", subgroup: ""),
            ScheduleItem(id: "b", day: "2026-11-02", timeStart: "13:00", timeEnd: "14:20", type: "Лекция", subject: "Сегодня", teacher: "", place: "1", subgroup: ""),
        ]), fetchedAt: now, sources: [])
        snapshot.deadlines = CachedSection(value: [
            DeadlineItem(id: "1", title: "Тест", course: "", kind: "mod_quiz", whenLabel: "", due: now.addingTimeInterval(3_600), url: nil),
            DeadlineItem(id: "2", title: "Без времени", course: "", kind: "mod_assign", whenLabel: "Скоро", due: nil, url: nil),
        ], fetchedAt: now, sources: [])
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: PortalConfiguration.portalScheduleKey)
        defer { defaults.set(saved, forKey: PortalConfiguration.portalScheduleKey) }
        defaults.set(false, forKey: PortalConfiguration.portalScheduleKey)
        let payload = WidgetBridge.payload(from: snapshot, now: now)
        XCTAssertEqual(payload.lessons.map(\.subject), ["Сегодня"])
        XCTAssertEqual(payload.deadlines.map(\.title), ["Тест"])
    }

    func testOldCacheWithoutNewSectionsStillDecodes() throws {
        let json = #"{"schemaVersion":1}"#
        let snapshot = try JSONDecoder().decode(PortalSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.news); XCTAssertNil(snapshot.pages); XCTAssertNil(snapshot.deadlines)
    }
}
