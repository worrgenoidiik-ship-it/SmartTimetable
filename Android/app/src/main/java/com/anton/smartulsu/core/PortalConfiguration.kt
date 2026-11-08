package com.anton.smartulsu.core

import java.net.URI
import kotlin.random.Random

object PortalConfiguration {
    const val BASE = "https://portal.ulsu.ru"
    const val LOGIN = "$BASE/login/index.php"
    const val COURSES = "$BASE/my/"
    const val GRADES = "$BASE/blocks/buttons/academic_progress.php"
    const val NOTIFICATIONS = "$BASE/message/output/popup/notifications.php"
    const val SCHEDULE = "$BASE/blocks/schedule/ajax_schedule.php"
    const val MAX_BYTES = 8_000_000

    // Standard Moodle pages and portal menu items found in version2.html (iOS 1.1 port).
    const val MESSAGES = "$BASE/message/index.php"
    const val CALENDAR_UPCOMING = "$BASE/calendar/view.php?view=upcoming"
    const val GRADE_OVERVIEW = "$BASE/grade/report/overview/index.php"
    const val NEWS_FORUM = "$BASE/mod/forum/view.php?f=65"
    const val INQUIRY = "$BASE/CDO/inquiry/index.php"
    const val QUESTION = "$BASE/CDO/questionizer.php"
    const val ELECTIVES = "$BASE/blocks/elective_courses/list_elective_courses.php"
    const val OPEN_COURSES = "$BASE/blocks/online_eduv2/list_open_courses.php"
    const val QUESTIONNAIRES = "$BASE/blocks/questionnaire/user_questionnaires.php"
    const val THESIS = "$BASE/local/cdo_vkr/index.php"
    const val PORTFOLIO = "$BASE/blocks/exaport/resume.php?courseid=1"
    const val LIBRARY_ACCESS = "$BASE/blocks/ulsu_redact/ei.php"
    const val PROFILE = "$BASE/user/profile.php"

    fun courseQuizzes(id: String) = "$BASE/mod/quiz/index.php?id=$id"
    fun courseAssignments(id: String) = "$BASE/mod/assign/index.php?id=$id"
    fun courseGrades(id: String) = "$BASE/grade/report/user/index.php?id=$id"
    fun courseParticipants(id: String) = "$BASE/user/index.php?id=$id"

    fun randomRefreshDelay() = Random.nextLong(30, 61) * 60_000

    fun allowsDataURL(value: String) =
        runCatching {
                val u = URI(value)
                u.scheme.equals("https", true) &&
                    u.host.equals("portal.ulsu.ru", true) &&
                    u.port in listOf(-1, 443) &&
                    u.rawUserInfo == null
            }
            .getOrDefault(false)

    fun allowsBrowserURL(value: String) =
        runCatching {
                val u = URI(value)
                val h = u.host?.lowercase().orEmpty()
                u.scheme.equals("https", true) &&
                    (h == "ulsu.ru" || h.endsWith(".ulsu.ru")) &&
                    u.port in listOf(-1, 443, 8443) &&
                    u.rawUserInfo == null
            }
            .getOrDefault(false)

    fun isAuthenticationURL(value: String) =
        runCatching {
                // An unknown/external destination is a navigation error, not evidence
                // of session expiration. Keep existing university SSO handoffs until
                // the supported SSO origins can be independently established.
                if (!allowsBrowserURL(value)) return@runCatching false
                val u = URI(value)
                val p = u.path.lowercase()
                !u.host.equals("portal.ulsu.ru", true) ||
                    p.contains("/login/") ||
                    p.endsWith("/wait.php") ||
                    p.contains("/login-actions/")
            }
            .getOrDefault(false)

    fun path(value: String) = runCatching { URI(value).path }.getOrDefault("")
}

/** Read-only portal pages shown natively with the generic document parser. */
enum class PortalPageKind(val url: String, val title: String, val subtitle: String) {
    ATTESTATION("${PortalConfiguration.BASE}/CDO/academic_progress_inside.php", "Текущая успеваемость", "Аттестация и текущие баллы семестра"),
    DEBTS("${PortalConfiguration.BASE}/blocks/buttons/debts.php", "Задолженности", "Официальный список задолженностей"),
    STUDY_PLAN("${PortalConfiguration.BASE}/CDO/eduplan.php", "Учебный план", "Дисциплины, часы и формы контроля"),
    NOTIFICATION_CENTER("${PortalConfiguration.BASE}/blocks/cdo_notif_center/messages.php", "Мои уведомления", "Уведомления от университета");

    val key: String get() = "page." + name
}
