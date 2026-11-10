package com.anton.smartulsu.core

import com.google.gson.Gson
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

data class LessonTemplate(
    val weekday: Int,
    val number: Int,
    val subject: String,
    val type: String,
    val teacher: String,
    val place: String,
    val requiresConfirmation: Boolean = false,
)

/**
 * A semester plan; the same JSON as the iOS ManualPlan, so one file serves both apps.
 * The optional fields let a new semester change times, notes and cancellations without
 * an app update. Nullable because Gson does not apply Kotlin defaults.
 */
data class ManualPlan(
    val group: String,
    val firstDay: String,
    val lastDay: String,
    val revisionDay: String,
    val weekOne: List<LessonTemplate>,
    val weekTwo: List<LessonTemplate>,
    val revisedWeekOne: List<LessonTemplate>,
    val revisedWeekTwo: List<LessonTemplate>,
    val firstWeekNumber: Int? = null,
    val times: Map<String, List<String>>? = null,
    val dayNotes: Map<String, String>? = null,
    val cancelledDays: List<String>? = null,
) {
    /** Rejects files that would produce a broken or absurd calendar (same rules as iOS). */
    fun validate(): ManualPlan {
        fun date(value: String?): LocalDate = runCatching { LocalDate.parse(value, DateTimeFormatter.ISO_LOCAL_DATE) }
            .getOrElse { throw PortalFailure.Parse("дата «$value» в плане") }
        val first = date(firstDay)
        val last = date(lastDay)
        date(revisionDay)
        if (group.isNullOrBlank() || first > last || ChronoUnit.DAYS.between(first, last) > 400)
            throw PortalFailure.Parse("период плана")
        if (firstWeekNumber != null && firstWeekNumber !in 1..2) throw PortalFailure.Parse("номер первой недели")
        val lessons = weekOne.orEmpty() + weekTwo.orEmpty() + revisedWeekOne.orEmpty() + revisedWeekTwo.orEmpty()
        if (lessons.size > 800 || lessons.any { it.weekday !in 1..7 || it.number !in 1..12 || it.subject.isNullOrBlank() })
            throw PortalFailure.Parse("занятия плана")
        val time = Regex("(?:[01][0-9]|2[0-3]):[0-5][0-9]")
        times.orEmpty().forEach { (key, pair) ->
            if (key.toIntOrNull() !in 1..12 || pair.size != 2 || pair.any { !time.matches(it) } || pair[0] >= pair[1])
                throw PortalFailure.Parse("время пары $key")
        }
        (dayNotes.orEmpty().keys + cancelledDays.orEmpty()).forEach { date(it) }
        return this
    }
}

/** [imported]: the student loaded this plan themselves (Settings), so it is theirs even before
 *  the group is known; the built-in plan is shown only to its own group. */
class ManualSchedule(json: String, val imported: Boolean = false) {
    val plan: ManualPlan = runCatching { Gson().fromJson(json, ManualPlan::class.java) }.getOrNull()
        ?.validate() ?: throw PortalFailure.Parse("файл плана (ожидается JSON как manual_schedule.json)")
    private val first = LocalDate.parse(plan.firstDay)
    private val last = LocalDate.parse(plan.lastDay)
    private val times =
        mapOf(
            1 to ("08:00" to "09:20"),
            2 to ("09:30" to "10:50"),
            3 to ("11:00" to "12:20"),
            4 to ("12:45" to "14:05"),
            5 to ("14:15" to "15:35"),
            6 to ("15:45" to "17:05"),
            7 to ("17:15" to "18:35"),
        ) + plan.times.orEmpty().mapNotNull { (key, pair) -> key.toIntOrNull()?.let { it to (pair[0] to pair[1]) } }

    fun weekNumber(day: LocalDate): Int? {
        if (day < first || day > last) return null
        val start = plan.firstWeekNumber ?: 2
        // A study week starts on Monday even when the semester begins mid-week.
        val monday = first.minusDays((first.dayOfWeek.value - 1).toLong())
        return if ((ChronoUnit.DAYS.between(monday, day) / 7) % 2 == 0L) start else 3 - start
    }

    val periodLabel: String
        get() {
            val format = DateTimeFormatter.ofPattern("d MMMM yyyy", java.util.Locale.forLanguageTag("ru"))
            return "${first.format(format)} — ${last.format(format)}"
        }

    val window: ScheduleWindow by lazy {
        val days = generateSequence(first) { it.plusDays(1) }.takeWhile { it <= last }.toList()
        val items =
            days.flatMap { day ->
                val week = weekNumber(day)
                val template =
                    if (day.toString() >= plan.revisionDay) {
                        if (week == 1) plan.revisedWeekOne else plan.revisedWeekTwo
                    } else if (week == 1) plan.weekOne else plan.weekTwo
                template.orEmpty()
                    .filter { it.weekday == day.dayOfWeek.value }
                    .sortedBy { it.number }
                    .map {
                        val t = times[it.number] ?: ("" to "")
                        ScheduleItem(
                            StableID.make(
                                "manual",
                                plan.group,
                                day.toString(),
                                it.number.toString(),
                                it.subject,
                            ),
                            day.toString(),
                            t.first,
                            t.second,
                            it.type.orEmpty(),
                            it.subject,
                            it.teacher.orEmpty(),
                            it.place.orEmpty(),
                            lessonNumber = it.number,
                            requiresConfirmation = it.requiresConfirmation,
                        )
                    }
            }
        ScheduleWindow(
            days.map { it.toString() },
            items,
            "manual",
            plan.dayNotes.orEmpty(),
            plan.cancelledDays.orEmpty(),
        )
    }
}

/** Which lessons to show: the group's plan, the portal, or Auto (plan inside its period, portal outside). */
object ScheduleSource {
    const val AUTO = "auto"
    const val MANUAL = "manual"
    const val PORTAL = "portal"

    /** The group's plan with full teacher names and rooms filled in from courses and the portal. */
    fun enrichedPlan(snapshot: PortalSnapshot, manual: ManualSchedule) =
        ScheduleEnricher.enrich(manual.window, snapshot.courses?.value.orEmpty(), snapshot.portalSchedule?.value)

    fun window(snapshot: PortalSnapshot, manual: ManualSchedule, source: String): ScheduleWindow? {
        val portal = snapshot.portalSchedule?.value
        return when (source) {
            MANUAL -> enrichedPlan(snapshot, manual)
            PORTAL -> portal
            else -> {
                // Another group's plan is never shown: those students get the portal schedule.
                if (!StudentGroup.planApplies(snapshot, manual)) return portal
                val plan = enrichedPlan(snapshot, manual)
                if (portal == null) return plan
                val planned = plan.days.toSet()
                ScheduleWindow(
                    (planned + portal.days.orEmpty()).sorted(),
                    (plan.items + portal.items.orEmpty().filter { it.day !in planned })
                        .sortedWith(compareBy({ it.day }, { it.timeStart }, { it.id })),
                    "auto",
                    portal.dayNotes.orEmpty() + plan.dayNotes,
                    plan.cancelledDays,
                )
            }
        }
    }

    fun isPlanned(day: String, manual: ManualSchedule, source: String, snapshot: PortalSnapshot? = null) = when (source) {
        MANUAL -> true
        PORTAL -> false
        else -> (snapshot == null || StudentGroup.planApplies(snapshot, manual)) && day in manual.window.days
    }
}
