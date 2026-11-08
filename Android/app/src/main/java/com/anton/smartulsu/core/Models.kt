package com.anton.smartulsu.core

import com.google.gson.Gson
import java.io.IOException
import java.security.MessageDigest
import java.time.LocalDate
import java.time.ZoneId

data class StudentProfile(val accountKey: String, val name: String)

data class GradeItem(
    val id: String,
    val subject: String,
    val type: String,
    val grade: String,
    val date: String,
    val teacher: String,
    val semester: String,
    val retake: String? = null,
)

data class ScheduleItem(
    val id: String,
    val day: String,
    val timeStart: String,
    val timeEnd: String,
    val type: String,
    val subject: String,
    val teacher: String,
    val place: String,
    val subgroup: String = "",
    val lessonNumber: Int? = null,
    val requiresConfirmation: Boolean = false,
)

data class ScheduleWindow(
    val days: List<String>,
    val items: List<ScheduleItem>,
    val origin: String = "portal",
    val dayNotes: Map<String, String> = emptyMap(),
    val cancelledDays: List<String> = emptyList(),
)

data class Course(val id: String, val title: String, val teacher: String, val url: String)

data class PortalNotification(
    val id: String,
    val message: String,
    val sourceTimeLabel: String,
    val isUnread: Boolean,
    val observedAt: Long = System.currentTimeMillis(),
)

data class CachedSection<T>(val value: T, val fetchedAt: Long = System.currentTimeMillis())

// ---- Added with the iOS 1.1 port: more portal pages read by the parser ----

/** One table of a portal page. Headers may be empty when the site has none. */
data class PortalTable(val caption: String, val headers: List<String>, val rows: List<List<String>>)

data class PortalLink(val title: String, val url: String)

/** Readable content of a portal page's main region, kept for offline viewing. */
data class PortalDocument(
    val title: String,
    val tables: List<PortalTable>,
    val paragraphs: List<String>,
    val links: List<PortalLink>,
)

/** «Последние объявления» from the dashboard news block. */
data class NewsItem(val id: String, val title: String, val author: String, val dateLabel: String, val url: String)

/** One event of calendar/view.php?view=upcoming. [due] is epoch millis when the site exposes the time. */
data class DeadlineItem(
    val id: String,
    val title: String,
    val course: String,
    val kind: String,
    val whenLabel: String,
    val due: Long?,
    val url: String?,
) {
    val kindLabel: String get() = when (kind) {
        "mod_quiz" -> QuizKind.label(title)
        "mod_assign" -> "Задание"
        "mod_forum" -> "Форум"
        "mod_lesson" -> "Лекция"
        "mod_feedback", "mod_questionnaire" -> "Анкета"
        "" -> "Событие"
        else -> "Событие курса"
    }
}

data class CourseActivity(val id: String, val name: String, val kind: String, val info: String, val url: String?) {
    val kindLabel: String get() = when (kind) {
        "quiz" -> QuizKind.label(name)
        "assign" -> "Задание"
        "resource" -> "Файл"
        "folder" -> "Папка"
        "url" -> "Ссылка"
        "page", "book" -> "Материал"
        "forum" -> "Форум"
        "label" -> "Пояснение"
        "lesson" -> "Лекция"
        "feedback", "questionnaire", "choice" -> "Опрос"
        else -> "Элемент курса"
    }
}

data class CourseSection(val id: String, val title: String, val summary: String, val activities: List<CourseActivity>)

data class PortalSnapshot(
    val schemaVersion: Int = 1,
    val profile: StudentProfile? = null,
    val grades: CachedSection<List<GradeItem>>? = null,
    val courses: CachedSection<List<Course>>? = null,
    val notifications: CachedSection<List<PortalNotification>>? = null,
    val portalSchedule: CachedSection<ScheduleWindow>? = null,
    // Nullable on purpose: Gson does not run Kotlin defaults when an old cache lacks a field.
    val news: CachedSection<List<NewsItem>>? = null,
    val deadlines: CachedSection<List<DeadlineItem>>? = null,
    /** Past-due work that still needs an action (Moodle drops submitted items itself). */
    val overdue: CachedSection<List<DeadlineItem>>? = null,
    val pages: Map<String, CachedSection<PortalDocument>>? = null,
    val courseContents: Map<String, CachedSection<List<CourseSection>>>? = null,
    val notes: String = "",
    val profilePhoto: String? = null,
    val nextRefreshAt: Long = 0,
)

enum class SessionState {
    UNCHECKED,
    ACTIVE,
    OFFLINE,
    NEEDS_LOGIN,
}

enum class PortalSection(val url: String, val title: String) {
    GRADES(PortalConfiguration.GRADES, "Зачётная книжка"),
    COURSES(PortalConfiguration.COURSES, "Курсы"),
    NOTIFICATIONS(PortalConfiguration.NOTIFICATIONS, "Уведомления"),
    SCHEDULE(PortalConfiguration.SCHEDULE, "Расписание"),
    // Refreshed together with the sections above (iOS 1.1 port).
    ATTESTATION(PortalPageKind.ATTESTATION.url, "Текущая успеваемость"),
    DEBTS(PortalPageKind.DEBTS.url, "Задолженности"),
    DEADLINES(PortalConfiguration.CALENDAR_UPCOMING, "Дедлайны"),
}

data class PortalState(
    val snapshot: PortalSnapshot = PortalSnapshot(),
    val session: SessionState = SessionState.UNCHECKED,
    val ready: Boolean = false,
    val loading: Boolean = false,
    val errors: Map<PortalSection, String> = emptyMap(),
    /** Pages loaded on demand (study plan, course contents…): key → error / in progress. */
    val extraErrors: Map<String, String> = emptyMap(),
    val extraLoading: Set<String> = emptySet(),
    val message: String? = null,
)

sealed class PortalFailure(message: String) : IOException(message) {
    class LoginRequired :
        PortalFailure("Сессия завершена. Войдите снова. Сохранённые данные доступны.")

    class Parse(section: String) :
        PortalFailure("Не удалось надёжно распознать: $section. Сохранённые данные не изменены.")

    class Http(val status: Int) : PortalFailure("ЭИОС вернула HTTP $status.")

    class UnsafeURL : PortalFailure("Адрес страницы не разрешён.")

    class InvalidResponse : PortalFailure("ЭИОС вернула неподходящий ответ.")
}

object StableID {
    fun make(vararg values: String) =
        MessageDigest.getInstance("SHA-256")
            .digest(Gson().toJson(values).toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}

object CampusDate {
    val zone: ZoneId = ZoneId.of("Europe/Samara")

    fun today(): LocalDate = LocalDate.now(zone)
}
