package com.anton.smartulsu.core

import com.google.gson.JsonParser
import java.net.URI
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import org.jsoup.Jsoup
import org.jsoup.nodes.Element

/** Equivalent to the iOS parser. Unknown/partial markup never authorizes cache deletion. */
object PortalParser {
    fun clean(s: String) = s.replace(Regex("[\\s\\u00a0]+"), " ").trim()

    private fun norm(s: String) = clean(s).lowercase().replace('ё', 'е').trim(' ', '.', ':')

    private fun fail(s: String): Nothing = throw PortalFailure.Parse(s)

    private val fields =
        listOf(
            listOf("дисциплина", "наименование дисциплины", "предмет"),
            listOf("вид контроля", "форма контроля", "тип контроля"),
            listOf("отметка", "оценка", "результат", "итоговая оценка"),
            listOf("дата", "дата сдачи", "дата аттестации"),
            listOf("преподаватель", "фио преподавателя", "экзаменатор"),
        )

    private fun cells(e: Element) = e.children().filter { it.tagName() in listOf("td", "th") }

    private fun rows(e: Element): List<Element> =
        e.children().flatMap {
            when (it.tagName()) {
                "tr" -> listOf(it)
                "thead",
                "tbody",
                "tfoot" -> it.children().filter { r -> r.tagName() == "tr" }
                else -> emptyList()
            }
        }

    private fun gradeTable(e: Element) =
        e.hasClass("academic-table") ||
            rows(e).any { r ->
                val h = cells(r).map { norm(it.text()) }
                fields.all { names -> h.any { it in names } }
            }

    private fun teacher(e: Element) =
        e.html()
            .split(Regex("<br\\s*/?>", RegexOption.IGNORE_CASE))
            .map { clean(Jsoup.parse(it).text()) }
            .filter { it.isNotEmpty() }
            .joinToString("\n")

    private fun queryID(url: String): String? =
        runCatching {
                URI(url)
                    .rawQuery
                    ?.split('&')
                    ?.firstOrNull { it.startsWith("id=") }
                    ?.substringAfter('=')
                    ?.toLongOrNull()
                    ?.takeIf { it > 0 }
                    ?.toString()
            }
            .getOrNull()

    fun authenticatedProfile(html: String, source: String): StudentProfile {
        if (
            !PortalConfiguration.allowsDataURL(source) ||
                PortalConfiguration.isAuthenticationURL(source)
        )
            throw PortalFailure.LoginRequired()
        val d = Jsoup.parse(html, source)
        if (
            d.select(
                    "input[name=logintoken], form#kc-form-login, input[name=otp], form#login, .loginwait-modal, #loginwait-content"
                )
                .isNotEmpty()
        )
            throw PortalFailure.LoginRequired()
        val name = clean(d.select("span.usertext").text())
        if (name.isEmpty() || d.select("a[href*='/login/logout.php']").isEmpty())
            fail("подтверждение входа")
        val id =
            d.select(".usermenu a[href*='/user/profile.php']").firstNotNullOfOrNull {
                val u = it.absUrl("href")
                if (PortalConfiguration.allowsDataURL(u)) queryID(u) else null
            } ?: fail("идентификатор пользователя")
        return StudentProfile(StableID.make("portal.ulsu.ru", "id:$id"), name)
    }

    fun academicProgress(
        html: String,
        source: String = PortalConfiguration.GRADES,
    ): List<GradeItem> {
        val d = Jsoup.parse(html, source)
        val tabs =
            d.select(
                ".academic-link, [role=tab], [data-bs-toggle=tab], [data-bs-toggle=pill], [data-toggle=tab], [data-toggle=pill]"
            )
        val tables = d.select("table").filter(::gradeTable)
        val identified = d.select("[id]")
        val visited = mutableMapOf<String, String>()
        val used = mutableSetOf<Element>()
        val labels = mutableSetOf<String>()
        val result = mutableListOf<GradeItem>()
        for (t in tabs) {
            val label = clean(t.text())
            val targets = mutableSetOf<String>()
            for (a in listOf("href", "data-bs-target", "data-target")) {
                val v = clean(t.attr(a))
                if (v.startsWith('#') && v.length > 1) targets += v.drop(1)
                else if (a == "href" && v.isNotEmpty())
                    runCatching {
                        val u = URI(source).resolve(v)
                        val src = URI(source)
                        if (
                            PortalConfiguration.allowsDataURL(u.toString()) &&
                                u.path == src.path &&
                                u.query == src.query &&
                                !u.fragment.isNullOrEmpty()
                        )
                            targets += u.fragment
                    }
            }
            targets += clean(t.attr("aria-controls")).split(' ').filter { it.isNotBlank() }
            val panes = identified.filter { it.id() in targets }
            if (
                !t.hasClass("academic-link") &&
                    !norm(label).contains("семестр") &&
                    panes.none { p -> p.select("table").any { it in tables } }
            )
                continue
            if (targets.size != 1 || panes.size != 1 || label.isEmpty())
                fail("ссылка или содержимое семестра")
            val id = targets.first()
            if (id in visited) {
                if (visited[id] != label) fail("противоречивое название семестра")
                continue
            }
            if (!labels.add(label)) fail("повторяющийся семестр")
            visited[id] = label
            val all = panes.single().select("table")
            val candidates = if (all.size == 1) all.toList() else all.filter { it in tables }
            val table = candidates.singleOrNull() ?: fail("таблица семестра $label")
            if (!used.add(table)) fail("повторяющаяся таблица семестра")
            result += parseGrades(table, source, label)
        }
        if (visited.isEmpty() || tables.any { it !in used }) fail("вкладки семестров")
        return result
    }

    private fun parseGrades(table: Element, source: String, semester: String): List<GradeItem> {
        val rr = rows(table)
        val index =
            rr.indexOfFirst { r ->
                val h = cells(r).map { norm(it.text()) }
                fields.all { a -> h.any { it in a } }
            }
        if (index < 0) fail("заголовки таблицы оценок")
        val headers = cells(rr[index]).map { norm(it.text()) }
        val cols = fields.map { a -> headers.indexOfFirst { it in a } }
        if (cols.toSet().size != fields.size) fail("заголовки таблицы оценок")
        val retake = headers.indexOf("пересдача")
        val result = mutableListOf<GradeItem>()
        rr.forEachIndexed { offset, row ->
            if (offset <= index) return@forEachIndexed
            val cc = cells(row)
            if (cc.isEmpty()) return@forEachIndexed
            val values = cc.map { clean(it.text()) }
            if (values.map(::norm) == headers) return@forEachIndexed
            if (
                cc.size != headers.size ||
                    cc.any { it.attr("colspan") !in listOf("", "1") } ||
                    values[cols[0]].isEmpty()
            )
                fail("строка таблицы оценок")
            val subject = values[cols[0]]
            val type = values[cols[1]]
            val date = values[cols[3]]
            val names = teacher(cc[cols[4]])
            result +=
                GradeItem(
                    StableID.make(source, subject, type, date, semester, names, offset.toString()),
                    subject,
                    type,
                    values[cols[2]],
                    date,
                    names,
                    semester,
                    values.getOrNull(retake),
                )
        }
        if (result.isEmpty()) fail("пустая таблица без подтверждения отсутствия данных")
        return result
    }

    internal fun courseURL(href: String, source: String): String? =
        runCatching {
                val u = URI(source).resolve(href).toString()
                if (!PortalConfiguration.allowsDataURL(u) || URI(u).path != "/course/view.php") null
                else queryID(u)?.let { "${PortalConfiguration.BASE}/course/view.php?id=$it" }
            }
            .getOrNull()

    fun courses(html: String, source: String = PortalConfiguration.COURSES): List<Course> {
        val d = Jsoup.parse(html, source)
        val result = linkedMapOf<String, Course>()
        val cards = d.select("[data-region=course-content][data-course-id]")
        if (cards.isNotEmpty())
            for (c in cards) {
                val id =
                    c.attr("data-course-id").toLongOrNull()?.takeIf { it > 0 }?.toString()
                        ?: fail("карточка курса")
                val link = c.selectFirst("a.coursename[href]") ?: fail("ссылка курса")
                val url = courseURL(link.attr("href"), source) ?: fail("адрес курса")
                if (queryID(url) != id) fail("идентификатор курса")
                val prefix = "Действия для текущего курса "
                val title =
                    c.select("button .sr-only")
                        .map { clean(it.text()) }
                        .firstOrNull { it.startsWith(prefix) }
                        ?.removePrefix(prefix)
                        ?.let(::clean) ?: clean(link.select(".multiline").text())
                if (title.isEmpty()) fail("название курса")
                result[id] = Course(id, title, "", url)
            }
        else
            for (link in d.select("#region-main a[href]")) {
                val url = courseURL(link.attr("href"), source) ?: continue
                val id = queryID(url) ?: continue
                val title = clean(link.text())
                if (title.isNotEmpty() && title != "Изображение курса")
                    result[id] = Course(id, title, "", url)
            }
        if (result.isEmpty()) fail("список курсов")
        return result.values.toList()
    }

    fun notifications(
        html: String,
        source: String = PortalConfiguration.NOTIFICATIONS,
    ): List<PortalNotification> {
        if (
            !PortalConfiguration.allowsDataURL(source) ||
                PortalConfiguration.path(source) !=
                    PortalConfiguration.path(PortalConfiguration.NOTIFICATIONS)
        )
            fail("область уведомлений")
        val area =
            Jsoup.parse(html, source).selectFirst("[data-region=notification-area]")
                ?: fail("область уведомлений")
        val rr = area.select("[data-region=notification-content-item-container]")
        if (rr.isEmpty()) fail("загруженный список уведомлений")
        val seen = mutableSetOf<String>()
        return rr.map { r ->
            val id = r.attr("data-id")
            val message = clean(r.select(".notification-message").text())
            val time = clean(r.select(".timestamp").text())
            if (
                (id.toLongOrNull() ?: 0) <= 0 ||
                    message.isEmpty() ||
                    time.isEmpty() ||
                    !seen.add(id)
            )
                fail("строка уведомления")
            PortalNotification(id, message, time, r.hasClass("unread"))
        }
    }

    fun parseAjaxSchedule(
        jsonString: String,
        source: String = PortalConfiguration.SCHEDULE,
    ): ScheduleWindow {
        if (jsonString.toByteArray().size > PortalConfiguration.MAX_BYTES)
            throw PortalFailure.InvalidResponse()
        val html =
            runCatching {
                    val v = JsonParser.parseString(jsonString).asJsonObject.get("html")
                    if (!v.isJsonPrimitive || !v.asJsonPrimitive.isString)
                        throw PortalFailure.InvalidResponse()
                    v.asString
                }
                .getOrElse { throw PortalFailure.InvalidResponse() }
        if (html.isBlank()) fail("расписание")
        val d = Jsoup.parse(html, source)
        if (d.select("form#login, input[name=logintoken], .loginwait-modal").isNotEmpty())
            throw PortalFailure.LoginRequired()
        val panes = d.select(".tab-content .tab-pane")
        if (panes.isEmpty()) fail("дни расписания")
        val days = sortedMapOf<String, List<ScheduleItem>>()
        for (p in panes) {
            if (!p.id().matches(Regex("day[0-9]{8}"))) fail("идентификатор дня расписания")
            val day =
                runCatching {
                        LocalDate.parse(p.id().drop(3), DateTimeFormatter.BASIC_ISO_DATE).toString()
                    }
                    .getOrElse { fail("дата расписания") }
            if (day in days) fail("повторяющийся день расписания")
            val table =
                p.select("table.schedule-table").singleOrNull() ?: fail("таблица расписания")
            val body = table.select("tbody").singleOrNull() ?: fail("таблица расписания")
            val rr = body.select("tr")
            if (rr.isEmpty() && clean(body.text()).isNotEmpty()) fail("пустой день расписания")
            val counts = mutableMapOf<String, Int>()
            days[day] =
                rr.map { row ->
                        fun field(selector: String, multiline: Boolean = false): String {
                            val e =
                                row.select(selector).singleOrNull()
                                    ?: fail("поле занятия $selector")
                            return if (multiline) teacher(e) else clean(e.text())
                        }
                        val times =
                            field(".schedule-table_time")
                                .replace(Regex("[–—−]"), "-")
                                .split('-')
                                .map(::clean)
                        if (
                            times.size != 2 ||
                                times.any {
                                    !it.matches(Regex("(?:[01][0-9]|2[0-3]):[0-5][0-9]"))
                                } ||
                                times[0] >= times[1]
                        )
                            fail("время занятия")
                        val subject = field(".schedule-table_exam")
                        if (subject.isEmpty()) fail("название занятия")
                        val type = field(".schedule-table_type")
                        val names = field(".schedule-table_category", true)
                        val place = field(".schedule-table_adress")
                        val fp =
                            StableID.make(day, times[0], times[1], subject, type, names, place, "")
                        val occurrence = counts[fp] ?: 0
                        counts[fp] = occurrence + 1
                        ScheduleItem(
                            StableID.make("ajax-schedule", fp, occurrence.toString()),
                            day,
                            times[0],
                            times[1],
                            type,
                            subject,
                            names,
                            place,
                        )
                    }
                    .sortedWith(compareBy({ it.timeStart }, { it.id }))
        }
        return ScheduleWindow(days.keys.toList(), days.values.flatten())
    }

    fun preserveScheduleHistory(
        observed: ScheduleWindow,
        previous: ScheduleWindow?,
    ): ScheduleWindow =
        if (previous == null || previous.origin == "manual") observed
        else
            observed.copy(
                days = (previous.days + observed.days).distinct().sorted(),
                items =
                    (previous.items.filter { it.day !in observed.days } + observed.items)
                        .sortedWith(compareBy({ it.day }, { it.timeStart }, { it.id })),
            )

    fun mergeCourses(observed: List<Course>, cached: List<Course>) =
        (cached.associateBy { it.id } + observed.associateBy { it.id }).values.toList()

    // Keep the 500 greatest portal IDs, including the maximum ever seen. That maximum is
    // the persisted event watermark: loading older pages can never announce history again.
    const val NOTIFICATION_HISTORY_LIMIT = 500

    fun mergeNotifications(observed: List<PortalNotification>, cached: List<PortalNotification>) =
        (cached.associateBy { it.id } + observed.associateBy { it.id }).values
            .sortedWith(compareByDescending<PortalNotification> { it.id.toLongOrNull() ?: 0L }
                .thenBy { it.id })
            .take(NOTIFICATION_HISTORY_LIMIT)
}
