package com.anton.smartulsu.core

import com.google.gson.Gson
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDateTime

/** Same cases as the iOS PortalPagesParserTests, so both platforms read pages identically. */
class PortalPagesParserTest {
    private val base = "https://portal.ulsu.ru/my/"

    private fun page(main: String) =
        "<html><head><title>Текущая успеваемость: ЭИОС</title></head><body><section id='region-main'><div role='main'>$main</div></section></body></html>"

    // Markup copied from the news_items block of the saved dashboard (version2.html).
    @Test fun newsBlockFromDashboard() {
        val html = """
            <html><body><section data-block="news_items"><ul class='unlist'>
            <div class="post post-custom"><div class="head clearfix"><div class="date">7 Sep 15:26</div><div class="name">ФГБОУ ВО Ульяновский государственный университет</div></div><div class="info"><a href="https://portal.ulsu.ru/mod/forum/discuss.php?d=64781">Университетские курсы по выбору</a></div></div>
            <div class="post post-custom"><div class="head clearfix"><div class="date">3 Jun 13:48</div><div class="name">УлГУ</div></div><div class="info"><a href="https://evil.example/x">Чужая ссылка</a></div></div>
            </ul></section></body></html>
        """.trimIndent()
        val news = PortalPagesParser.news(html, base)
        assertEquals(1, news.size)
        assertEquals("64781", news[0].id)
        assertEquals("Университетские курсы по выбору", news[0].title)
        assertEquals("7 Sep 15:26", news[0].dateLabel)
        assertThrows(PortalFailure.Parse::class.java) { PortalPagesParser.news("<html><body></body></html>", base) }
    }

    @Test fun genericDocumentReadsTabsTablesAndLinks() {
        val html = page("""
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
        val document = PortalPagesParser.document(html, PortalPageKind.ATTESTATION.url)
        assertEquals("Текущая успеваемость", document.title)
        val table = document.tables.single()
        assertEquals("1 семестр", table.caption)
        assertEquals(listOf("Дисциплина", "Аттестация 1", "Аттестация 2"), table.headers)
        assertEquals(listOf(listOf("Математика", "45", "не аттестован"), listOf("История\nРоссии", "зачтено", "")), table.rows)
        assertEquals(listOf("https://portal.ulsu.ru/course/view.php?id=5"), document.links.map { it.url })
    }

    @Test fun genericDocumentWithoutContentIsAnError() {
        assertThrows(PortalFailure.Parse::class.java) { PortalPagesParser.document(page("<div></div>"), PortalPageKind.DEBTS.url) }
        assertThrows(PortalFailure.Parse::class.java) {
            PortalPagesParser.document("<html><body><p>нет main</p></body></html>", PortalPageKind.DEBTS.url)
        }
        assertEquals(listOf("Задолженностей нет"),
            PortalPagesParser.document(page("<p>Задолженностей нет</p>"), PortalPageKind.DEBTS.url).paragraphs)
    }

    @Test fun courseSectionsAndActivities() {
        val html = """
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
        """.trimIndent()
        val sections = PortalPagesParser.courseContents(html, "https://portal.ulsu.ru/course/view.php?id=5")
        assertEquals(listOf("Общее", "Модуль 1"), sections.map { it.title })
        assertEquals("Объявления", sections[0].activities.first().name)
        val module = sections[1].activities
        assertEquals(listOf("quiz", "assign", "label"), module.map { it.kind })
        assertEquals("Тест 1", module[0].name)
        assertEquals("Закрывается: 10 ноября 2026, 23:59", module[0].info)
        assertEquals("https://portal.ulsu.ru/mod/assign/view.php?id=13", module[1].url)
        assertEquals("Сдать до пятницы", module[2].name)
        assertThrows(PortalFailure.Parse::class.java) { PortalPagesParser.courseContents("<html><body></body></html>", base) }
    }

    @Test fun upcomingDeadlinesWithExactTime() {
        // 1793476800 = 1 November 2026 00:00 in Europe/Samara.
        val html = page("""
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
        val items = PortalPagesParser.deadlines(html, PortalConfiguration.CALENDAR_UPCOMING)
        assertEquals(listOf("900", "901"), items.map { it.id })
        assertEquals("Тест", items[0].kindLabel)
        assertEquals("Программирование", items[0].course)
        assertEquals("https://portal.ulsu.ru/mod/quiz/view.php?id=12", items[0].url)
        val expected = LocalDateTime.of(2026, 11, 1, 23, 59).atZone(CampusDate.zone).toInstant().toEpochMilli()
        assertEquals(expected, items[0].due)
        assertNull(items[1].due)
        assertTrue(PortalPagesParser.deadlines(page("<p>Нет предстоящих событий</p>"), PortalConfiguration.CALENDAR_UPCOMING).isEmpty())
        assertThrows(PortalFailure.Parse::class.java) {
            PortalPagesParser.deadlines(page("<p>Загрузка…</p>"), PortalConfiguration.CALENDAR_UPCOMING)
        }
    }

    @Test fun sesskeyAndKeepAliveAnswers() {
        assertEquals("AbCdEf1234", PortalPagesParser.sesskey(
            """M.cfg = {"wwwroot":"https:\/\/portal.ulsu.ru","sesskey":"AbCdEf1234","sessiontimeout":"28800"};"""))
        assertNull(PortalPagesParser.sesskey("<html>нет ключа</html>"))
        assertEquals(7199L, PortalPagesParser.sessionTouchResult(
            """[{"error":false,"data":true},{"error":false,"data":{"userid":42,"timeremaining":7199}}]"""))
        assertThrows(PortalFailure.LoginRequired::class.java) {
            PortalPagesParser.sessionTouchResult("""[{"error":true,"exception":{"errorcode":"servicerequireslogin"}}]""")
        }
        assertThrows(PortalFailure.LoginRequired::class.java) {
            PortalPagesParser.sessionTouchResult("""{"error":"Неверный ключ сессии","errorcode":"invalidsesskey"}""")
        }
        assertNull(PortalPagesParser.sessionTouchResult("""[{"error":false,"data":true}]"""))
    }

    @Test fun oldCacheWithoutNewSectionsStillDecodes() {
        val snapshot = Gson().fromJson("""{"schemaVersion":1}""", PortalSnapshot::class.java)
        assertNull(snapshot.news)
        assertNull(snapshot.pages)
        assertNull(snapshot.deadlines)
        assertNull(snapshot.courseContents)
    }
}
