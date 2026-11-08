package com.anton.smartulsu.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.anton.smartulsu.NetworkManager
import com.anton.smartulsu.core.*
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.Locale

// Port of the iOS 1.1 screens: the ЭИОС hub, generic portal pages, course contents.

private const val STALE_MS = 30 * 60_000L

private fun formatDue(millis: Long) =
    Instant.ofEpochMilli(millis).atZone(CampusDate.zone)
        .format(DateTimeFormatter.ofPattern("d MMM, HH:mm", Locale.forLanguageTag("ru")))

@Composable
private fun LinkRow(title: String, subtitle: String, onClick: () -> Unit) {
    SectionCard(Modifier.clickable(onClick = onClick)) {
        Text(title, fontWeight = FontWeight.SemiBold)
        Hint(subtitle)
    }
}

@Composable
private fun GroupTitle(text: String) {
    Text(text.uppercase(), style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp))
}

@Composable
internal fun DeadlineLine(item: DeadlineItem) {
    val urgent = (item.due ?: Long.MAX_VALUE) < System.currentTimeMillis() + 86_400_000L
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(item.title, fontWeight = FontWeight.SemiBold)
        if (item.course.isNotBlank()) Hint(item.course)
        Text(
            item.kindLabel + " · " + (item.due?.let(::formatDue) ?: item.whenLabel) +
                if ((item.due ?: Long.MAX_VALUE) < System.currentTimeMillis()) " · просрочено" else "",
            style = MaterialTheme.typography.labelSmall,
            color = if (urgent) MaterialTheme.colorScheme.error else Color(0xFFE08A00),
        )
    }
}

/** The «ЭИОС» tab: deadlines, news and every portal section. */
@Composable
internal fun ServicesScreen(
    state: PortalState,
    openBrowser: (String, String) -> Unit,
    openPage: (PortalPageKind) -> Unit,
    openQuiz: (String, String) -> Unit = { _, _ -> },
    openCourses: () -> Unit = {},
    question: () -> Unit = {},
    inquiry: () -> Unit = {},
) {
    val now = System.currentTimeMillis()
    val deadlines = state.snapshot.deadlines?.value.orEmpty().filter { (it.due ?: Long.MAX_VALUE) > now }
    val news = state.snapshot.news?.value.orEmpty()
    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Text("ЭИОС", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        }
        item {
            SectionCard {
                Text("Ближайшие сроки", fontWeight = FontWeight.Bold, color = Color(0xFFE08A00))
                if (deadlines.isEmpty())
                    Hint(if (state.snapshot.deadlines == null) "Календарь загрузится при обновлении данных." else "Сроков в ближайшее время нет.")
                deadlines.take(5).forEach { d ->
                    Box(Modifier.fillMaxWidth().clickable {
                        val target = d.url
                        if (d.kind == "mod_quiz" && target != null) openQuiz(d.title, target)
                        else openBrowser(d.kindLabel, target ?: PortalConfiguration.CALENDAR_UPCOMING)
                    }) { DeadlineLine(d) }
                }
                state.errors[PortalSection.DEADLINES]?.let { Hint(it) }
                TextButton(onClick = { openBrowser("Календарь", PortalConfiguration.CALENDAR_UPCOMING) }) { Text("Календарь на сайте") }
            }
        }
        item {
            // Between deadlines and news: past-due labs, assignments and tests not submitted yet.
            val overdue = state.snapshot.overdue?.value.orEmpty()
            var showAll by remember { mutableStateOf(false) }
            SectionCard {
                Text("Просроченные работы" + if (overdue.isNotEmpty()) " · ${overdue.size}" else "",
                    fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.error)
                if (overdue.isEmpty())
                    Hint(if (state.snapshot.overdue == null) "Появятся после обновления данных." else "Всё сдано — просроченных работ нет.")
                (if (showAll) overdue else overdue.take(3)).forEach { d ->
                    Box(Modifier.fillMaxWidth().clickable {
                        val target = d.url
                        if (d.kind == "mod_quiz" && target != null) openQuiz(d.title, target)
                        else openBrowser(d.kindLabel, target ?: PortalConfiguration.CALENDAR_UPCOMING)
                    }) { DeadlineLine(d) }
                }
                if (overdue.size > 3) TextButton(onClick = { showAll = !showAll }) { Text(if (showAll) "Свернуть" else "Показать все") }
            }
        }
        item {
            SectionCard {
                Text("Новости УлГУ", fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.primary)
                if (news.isEmpty()) Hint("Объявления появятся после обновления данных.")
                news.take(5).forEach { n ->
                    Column(Modifier.fillMaxWidth().clickable { openBrowser("Объявление", n.url) }) {
                        Text(n.title, fontWeight = FontWeight.SemiBold)
                        Hint(listOf(n.dateLabel, n.author).filter { it.isNotBlank() }.joinToString(" · "))
                    }
                }
                TextButton(onClick = { openBrowser("Новости", PortalConfiguration.NEWS_FORUM) }) { Text("Все объявления") }
            }
        }
        item { GroupTitle("Учёба") }
        item { LinkRow("Мои курсы", "Материалы, тесты, задания и содержание курсов", openCourses) }
        items(listOf(PortalPageKind.ATTESTATION, PortalPageKind.DEBTS, PortalPageKind.STUDY_PLAN)) { kind ->
            LinkRow(kind.title, kind.subtitle) { openPage(kind) }
        }
        item { LinkRow("Оценки по курсам", "Итоговые баллы по каждому курсу") { openBrowser("Оценки", PortalConfiguration.GRADE_OVERVIEW) } }
        item { GroupTitle("Связь и заявления") }
        item { LinkRow("Задать вопрос", "Обращение в деканат и службы университета", question) }
        item { LinkRow("Заказ справок", "Справка об обучении, о стипендии, 2-НДФЛ и другие", inquiry) }
        item { LinkRow(PortalPageKind.NOTIFICATION_CENTER.title, PortalPageKind.NOTIFICATION_CENTER.subtitle) { openPage(PortalPageKind.NOTIFICATION_CENTER) } }
        item { GroupTitle("Выбор и прочее") }
        val links = listOf(
            Triple("Курсы по выбору", "Запись на университетские курсы по выбору", PortalConfiguration.ELECTIVES),
            Triple("Открытые онлайн-курсы", "Массовые открытые онлайн-курсы", PortalConfiguration.OPEN_COURSES),
            Triple("Анкеты", "Опросы и анкетирование студентов", PortalConfiguration.QUESTIONNAIRES),
            Triple("Работа с ВКР", "Выпускная квалификационная работа", PortalConfiguration.THESIS),
            Triple("Портфолио", "Резюме и артефакты портфолио", PortalConfiguration.PORTFOLIO),
            Triple("Доступ к ЭИ", "Электронные библиотеки и ресурсы", PortalConfiguration.LIBRARY_ACCESS),
            Triple("Профиль ЭИОС", "Личные данные на портале", PortalConfiguration.PROFILE),
        )
        items(links) { (title, subtitle, url) -> LinkRow(title, subtitle) { openBrowser(title, url) } }
    }
}

/** Tables of a portal page as cards: first column is the title, others «поле: значение». */
@Composable
internal fun PortalDocumentContent(
    state: PortalState,
    kind: PortalPageKind,
    openBrowser: (String, String) -> Unit,
    maxRows: Int = Int.MAX_VALUE,
) {
    val section = state.snapshot.pages?.get(kind.name)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (kind.key in state.extraLoading) LinearProgressIndicator(Modifier.fillMaxWidth())
        section?.value?.let { document ->
            val captions = document.tables.map { it.caption }
            if (document.tables.size > 1 && captions.none { it.isBlank() }) {
                // One semester at a time; the current one (by the group's enrolment year) first.
                val current = StudentGroup.currentSemester(StudentGroup.detect(state.snapshot.courses?.value.orEmpty()))
                val default = captions.indexOfFirst { current != null && it.startsWith("$current ") }.takeIf { it >= 0 } ?: captions.lastIndex
                var selected by remember(kind) { mutableIntStateOf(default) }
                androidx.compose.foundation.lazy.LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(captions.size) { index ->
                        FilterChip(selected = selected == index, onClick = { selected = index }, label = { Text(captions[index]) })
                    }
                }
                PortalTableCards(document.tables[selected.coerceIn(0, document.tables.lastIndex)].copy(caption = ""), maxRows)
            } else document.tables.forEach { table -> PortalTableCards(table, maxRows) }
            if (document.tables.isEmpty() && document.paragraphs.size <= 2)
                EmptyCard(document.paragraphs.joinToString("\n"), "Данные появятся, когда ЭИОС их опубликует.")
            else document.paragraphs.take(if (maxRows == Int.MAX_VALUE) 200 else 6).forEach { Text(it) }
            if (maxRows == Int.MAX_VALUE && document.links.isNotEmpty()) {
                Text("Ссылки на странице", fontWeight = FontWeight.Bold)
                document.links.take(40).forEach { link ->
                    TextButton(onClick = { openBrowser(link.title, link.url) }) { Text(link.title) }
                }
            }
        }
        if (section == null && kind.key !in state.extraLoading && state.extraErrors[kind.key] == null)
            Hint("Данные ещё не загружены.")
        (state.extraErrors[kind.key] ?: kind.section?.let { state.errors[it] })?.let {
            Hint(it)
            Hint("Если раздел не распознаётся, откройте его на сайте — там данные всегда актуальны.")
        }
        Updated(section?.fetchedAt)
        TextButton(onClick = { openBrowser(kind.title, kind.url) }) { Text("Открыть на сайте") }
    }
}

private val PortalPageKind.section: PortalSection?
    get() = when (this) {
        PortalPageKind.ATTESTATION -> PortalSection.ATTESTATION
        PortalPageKind.DEBTS -> PortalSection.DEBTS
        else -> null
    }

@Composable
private fun PortalTableCards(table: PortalTable, maxRows: Int) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (table.caption.isNotBlank()) Text(table.caption, fontWeight = FontWeight.Bold)
        // Title = «Наименование дисциплины»-like column, else the first non-numeric one; «№» and «Файлы» hidden.
        val names = table.headers.map { it.lowercase().replace('ё', 'е') }
        val titleColumn = names.indexOfFirst { n -> listOf("наименование", "дисциплин", "предмет", "название").any { it in n } }
            .takeIf { it >= 0 } ?: (0 until (table.rows.maxOfOrNull { it.size } ?: 0)).firstOrNull { c ->
                !table.rows.all { r -> c >= r.size || r[c].all { it.isDigit() } } } ?: 0
        fun hidden(i: Int) = names.getOrNull(i)?.trim()?.let { it == "№" || it == "№ п/п" || it == "файлы" } == true
        table.rows.take(maxRows).forEach { row ->
            val order = listOf(titleColumn) + row.indices.filter { it != titleColumn }
            val pairs = order.mapNotNull { i -> row.getOrNull(i)?.takeIf { it.isNotBlank() && !hidden(i) }?.let { table.headers.getOrElse(i) { "" } to it } }
            SectionCard {
                pairs.firstOrNull()?.let { Text(it.second, fontWeight = FontWeight.SemiBold) }
                pairs.drop(1).forEach { (label, value) ->
                    if (label.isBlank()) Hint(value)
                    else Row(Modifier.fillMaxWidth()) {
                        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(value, style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.Medium,
                            textAlign = TextAlign.End, modifier = Modifier.weight(1f))
                    }
                }
            }
        }
        if (table.rows.size > maxRows) Hint("Ещё строк: ${table.rows.size - maxRows}")
    }
}

@Composable
internal fun PortalDocumentScreen(
    repo: NetworkManager,
    state: PortalState,
    kind: PortalPageKind,
    openBrowser: (String, String) -> Unit,
    close: () -> Unit,
) {
    BackHandler(onBack = close)
    LaunchedEffect(kind) {
        val fetched = state.snapshot.pages?.get(kind.name)?.fetchedAt ?: 0L
        if (fetched < System.currentTimeMillis() - STALE_MS) repo.loadPage(kind)
    }
    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            TextButton(onClick = close) { Text("Назад") }
            Text(state.snapshot.pages?.get(kind.name)?.value?.title?.ifBlank { null } ?: kind.title,
                style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            Hint(kind.subtitle)
        }
        item { PortalDocumentContent(state, kind, openBrowser) }
    }
}

/** Course card: quick links to tests/assignments plus the parsed course contents. */
@Composable
internal fun CourseDetailScreen(
    repo: NetworkManager,
    state: PortalState,
    course: Course,
    openBrowser: (String, String) -> Unit,
    writeTeacher: (String) -> Unit = {},
    openQuiz: (String, String) -> Unit = { _, _ -> },
    close: () -> Unit,
) {
    BackHandler(onBack = close)
    val key = "course.${course.id}"
    val contents = state.snapshot.courseContents?.get(course.id)
    LaunchedEffect(course.id) {
        if ((contents?.fetchedAt ?: 0L) < System.currentTimeMillis() - STALE_MS) repo.loadCourseContents(course)
    }
    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            TextButton(onClick = close) { Text("Назад") }
            val title = CourseTitle(course.title)
            Text(title.subject, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            if (title.detailLine.isNotBlank()) Hint(title.detailLine)
        }
        val actions = listOf(
            Triple("Материалы курса", "Лекции, файлы и все разделы", CourseNavigation.destination(course)),
            Triple("Тесты", "Пройти, продолжить попытку, посмотреть результат", PortalConfiguration.courseQuizzes(course.id)),
            Triple("Задания", "Сроки сдачи, загрузка файлов, отзывы", PortalConfiguration.courseAssignments(course.id)),
            Triple("Оценки по курсу", "Баллы за тесты и задания", PortalConfiguration.courseGrades(course.id)),
        )
        items(actions) { (title, subtitle, url) -> LinkRow(title, subtitle) { openBrowser(title, url) } }
        item {
            LinkRow("Написать преподавателю", "Чат в приложении; преподаватель найдётся по названию курса") {
                writeTeacher(CourseTitle(course.title).teacher.orEmpty())
            }
        }
        item {
            Text("Содержание курса", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(top = 8.dp))
            if (key in state.extraLoading) LinearProgressIndicator(Modifier.fillMaxWidth())
            state.extraErrors[key]?.let { Hint(it) }
            if (contents == null && key !in state.extraLoading && state.extraErrors[key] == null)
                Hint("Содержание ещё не загружено.")
        }
        items(contents?.value.orEmpty(), key = { it.id }) { section ->
            SectionCard {
                Text(section.title, fontWeight = FontWeight.Bold)
                if (section.summary.isNotBlank()) Hint(section.summary.take(300))
                section.activities.forEach { activity ->
                    if (activity.kind == "label") Hint(activity.name)
                    else Row(
                        Modifier.fillMaxWidth().clickable(enabled = activity.url != null) {
                            // Tests are answered natively; everything else opens in the clean in-app page.
                            activity.url?.let { if (activity.kind == "quiz") openQuiz(activity.name, it) else openBrowser(activity.kindLabel, it) }
                        }.padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(Modifier.weight(1f)) {
                            Text(activity.name)
                            Text(
                                activity.kindLabel + if (activity.info.isNotBlank()) " · " + activity.info else "",
                                style = MaterialTheme.typography.labelSmall,
                                color = when (activity.kind) {
                                    "quiz" -> Color(0xFFE08A00)
                                    "assign" -> Color(0xFF8E44AD)
                                    else -> MaterialTheme.colorScheme.primary
                                },
                            )
                        }
                    }
                }
            }
        }
        item { Updated(contents?.fetchedAt) }
    }
}
