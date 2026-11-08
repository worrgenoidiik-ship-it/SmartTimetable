package com.anton.smartulsu.core

import com.google.gson.Gson
import com.google.gson.JsonParser
import org.junit.Assert.*
import org.junit.Test

class FacultyScheduleTest {
    private fun fixture() = javaClass.getResource("/ajax_schedule_varied_synthetic.json")!!.readText()

    @Test fun differentSubjectsRoomsAndNestedMarkupUseTheSameSupportedSelectors() {
        val result = PortalParser.parseAjaxSchedule(fixture())
        assertEquals(listOf("2026-10-19", "2026-10-20", "2026-10-26", "2026-10-27"), result.days)
        assertEquals(3, result.items.size)
        val first = result.items.first()
        assertEquals("14:40", first.timeStart)
        assertEquals("16:00", first.timeEnd)
        assertEquals("Синтетическая биология", first.subject)
        assertEquals("Лабораторная", first.type)
        assertEquals("Корпус Б, 204", first.place)
        assertEquals("Тестовый преподаватель А\nТестовый преподаватель Б", first.teacher)
    }

    @Test fun absentFirstPeriodsAndEmptyDaysNeverProduceInventedLessons() {
        val result = PortalParser.parseAjaxSchedule(fixture())
        assertTrue(result.items.none { it.day in listOf("2026-10-20", "2026-10-27") })
        assertTrue(result.items.filter { it.day == "2026-10-19" }.all { it.timeStart >= "14:40" })
        assertEquals("", result.items.last().teacher)
        assertEquals("", result.items.last().place)
    }

    @Test fun unknownOrIncompleteMarkupFailsInsteadOfPublishingPartialSchedule() {
        val html = JsonParser.parseString(fixture()).asJsonObject["html"].asString
        assertThrows(PortalFailure.Parse::class.java) {
            PortalParser.parseAjaxSchedule(Gson().toJson(mapOf("html" to html.replace("schedule-table_exam", "unknown-subject"))))
        }
    }

    @Test fun automaticScheduleEndpointContainsNoFacultyGroupOrUserIdentifier() {
        val uri = java.net.URI(PortalSection.SCHEDULE.url)
        assertEquals("/blocks/schedule/ajax_schedule.php", uri.path)
        assertNull(uri.rawQuery)
        assertEquals("portal.ulsu.ru", uri.host)
    }
}
