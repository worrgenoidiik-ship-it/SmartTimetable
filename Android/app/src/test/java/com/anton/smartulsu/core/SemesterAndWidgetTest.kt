package com.anton.smartulsu.core

import com.anton.smartulsu.widget.WidgetBridge
import com.anton.smartulsu.widget.WidgetClock
import com.anton.smartulsu.widget.WidgetPayload
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.time.LocalDateTime

/** Same rules as the iOS SemesterAndSessionTests: new semester without an update, widget summary. */
class SemesterAndWidgetTest {
    private val asset = File("src/main/assets/manual_schedule.json").readText()

    private fun lesson(day: String, subject: String, start: String = "08:00") =
        ScheduleItem(day + subject, day, start, "09:20", "", subject, "", "")

    @Test fun builtInPlanKeepsItsNotesAndCancellation() {
        val window = ManualSchedule(asset).window
        assertEquals("Занятия отменены. Плановые пары сохранены для истории.", window.dayNotes["2026-09-25"])
        assertEquals(listOf("2026-09-25"), window.cancelledDays)
        assertEquals(102, window.days.size)
    }

    @Test fun brokenPlansAreRejected() {
        val ok = """{"group":"ИС","firstDay":"2027-02-09","lastDay":"2027-06-30","revisionDay":"2027-07-01",
            "weekOne":[{"weekday":1,"number":1,"subject":"Матанализ","type":"","teacher":"","place":""}],
            "weekTwo":[],"revisedWeekOne":[],"revisedWeekTwo":[]}"""
        assertEquals("ИС", ManualSchedule(ok).plan.group)
        for (bad in listOf(
            ok.replace("2027-06-30", "2027-01-01"),
            ok.replace("2027-02-09", "2027-02-30"),
            ok.replace("\"weekday\":1", "\"weekday\":8"),
            ok.replace("\"weekTwo\":[]", "\"weekTwo\":[],\"times\":{\"1\":[\"10:00\",\"09:00\"]}"),
            "not json",
        )) assertThrows(PortalFailure.Parse::class.java) { ManualSchedule(bad) }
    }

    @Test fun firstWeekNumberAndCustomTimesApply() {
        val json = """{"group":"ИС","firstDay":"2027-02-08","lastDay":"2027-02-21","revisionDay":"2027-03-01",
            "weekOne":[{"weekday":1,"number":1,"subject":"Первая","type":"","teacher":"","place":""}],
            "weekTwo":[{"weekday":1,"number":1,"subject":"Вторая","type":"","teacher":"","place":""}],
            "revisedWeekOne":[],"revisedWeekTwo":[],"firstWeekNumber":1,"times":{"1":["08:30","09:50"]}}"""
        val items = ManualSchedule(json).window.items
        assertEquals(listOf("Первая", "Вторая"), items.map { it.subject })
        assertTrue(items.all { it.timeStart == "08:30" })
    }

    @Test fun autoUsesThePlanInsideItsPeriodAndThePortalAfterIt() {
        val manual = ManualSchedule(asset)
        val snapshot = PortalSnapshot(portalSchedule = CachedSection(ScheduleWindow(
            listOf("2026-12-30", "2027-02-09"),
            listOf(lesson("2026-12-30", "ЭИОС"), lesson("2027-02-09", "Новый семестр")))))
        val auto = ScheduleSource.window(snapshot, manual, ScheduleSource.AUTO)!!
        assertTrue(auto.items.none { it.subject == "ЭИОС" })
        assertTrue(auto.items.any { it.subject == "Новый семестр" })
        assertTrue(ScheduleSource.isPlanned("2026-12-31", manual, ScheduleSource.AUTO))
        assertFalse(ScheduleSource.isPlanned("2027-02-09", manual, ScheduleSource.AUTO))
        assertEquals(manual.window, ScheduleSource.window(PortalSnapshot(), manual, ScheduleSource.AUTO))
    }

    @Test fun widgetSummaryAndNextChange() {
        val now = LocalDateTime.of(2026, 11, 2, 12, 0)
        val millis = now.atZone(CampusDate.zone).toInstant().toEpochMilli()
        val window = ScheduleWindow(listOf("2026-11-01", "2026-11-02", "2026-11-03"), listOf(
            lesson("2026-11-01", "Вчера"), lesson("2026-11-02", "Сегодня", "13:00").copy(timeEnd = "14:20"),
            lesson("2026-11-03", "Отменено")), cancelledDays = listOf("2026-11-03"))
        val deadlines = listOf(
            DeadlineItem("1", "Тест", "", "mod_quiz", "", millis + 3_600_000, null),
            DeadlineItem("2", "Без времени", "", "mod_assign", "Скоро", null, null))
        val payload = WidgetBridge.payload(window, deadlines, millis)
        assertEquals(listOf("Сегодня"), payload.lessons.map { it.subject })
        assertEquals(listOf("Тест"), payload.deadlines.map { it.title })
        val clock = WidgetClock(now)
        assertEquals("Сегодня", clock.next(payload)?.subject)
        assertEquals(LocalDateTime.of(2026, 11, 2, 13, 0), clock.nextChange(payload))
        assertEquals(LocalDateTime.of(2026, 11, 3, 0, 1), clock.nextChange(WidgetPayload(emptyList(), emptyList())))
    }
}
