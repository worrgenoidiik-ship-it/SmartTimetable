package com.anton.smartulsu.core

import org.junit.Assert.*
import org.junit.Test

/** Same cases as the iOS ReviewFixesTests (1.9.2). */
class ReviewFixesTest {
    @Test fun weeksSwitchOnMondayWhenSemesterStartsMidWeek() {
        val plan = """{"group":"ИС-О-25/1","firstDay":"2027-02-09","lastDay":"2027-03-07","revisionDay":"2027-03-08",
            "firstWeekNumber":1,
            "weekOne":[{"weekday":1,"number":1,"subject":"Матанализ","type":"","teacher":"","place":""}],
            "weekTwo":[],"revisedWeekOne":[],"revisedWeekTwo":[]}"""
        // Was 15 Feb and 1 Mar: the Monday after a Tuesday start already belongs to week two.
        assertEquals(listOf("2027-02-22"), ManualSchedule(plan).window.items.map { it.day })
    }

    @Test fun subgroupTenIsNotSubgroupOne() {
        assertFalse(StudentGroup.sameGroup("ИС-О-25/10", "ИС-О-25/1"))
        assertFalse(StudentGroup.sameGroup("ИС-О-25/1", "ИС-О-25/10"))
        assertTrue(StudentGroup.sameGroup("ИС_О_25/1", "ИС-О-25/1"))
        assertTrue(StudentGroup.sameGroup("ИС-О-25", "ИС-О-25/1"))
        assertFalse(StudentGroup.sameGroup("ИС-О-24/1", "ИС-О-25/1"))
    }
}
