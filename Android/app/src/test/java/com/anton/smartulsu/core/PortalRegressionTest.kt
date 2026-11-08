package com.anton.smartulsu.core

import com.google.gson.Gson
import com.google.gson.JsonParser
import java.time.LocalDate
import org.junit.Assert.*
import org.junit.Test

class PortalRegressionTest {
    private fun fixture(name: String) = requireNotNull(javaClass.getResourceAsStream("/$name"))
        .bufferedReader().use { it.readText() }

    @Test fun renderedCoursesMatchCapturedExpectedValues() {
        val expected = JsonParser.parseString(fixture("rendered.expected.json")).asJsonObject["courses"].asJsonArray
        val actual = PortalParser.courses(fixture("courses_rendered.html"))
        assertEquals(expected.size(), actual.size)
        expected.zip(actual).forEach { (json, course) ->
            val item = json.asJsonObject
            assertEquals(item["id"].asString, course.id)
            assertEquals(item["title"].asString, course.title)
            assertEquals("${PortalConfiguration.BASE}/course/view.php?id=${course.id}", course.url)
        }
    }

    @Test fun courseFailureDoesNotMutatePreviousList() {
        val previous = PortalParser.courses(fixture("courses_rendered.html"))
        val saved = previous.toList()
        assertThrows(PortalFailure.Parse::class.java) { PortalParser.courses("<main id='region-main'>Loading</main>") }
        assertEquals(saved, previous)
    }

    @Test fun malformedCourseCardRejectsWholeResponse() {
        val html = fixture("courses_rendered.html")
        val doc = org.jsoup.Jsoup.parse(html)
        doc.select("[data-region=course-content][data-course-id]").first()!!.attr("data-course-id", "invalid")
        assertThrows(PortalFailure.Parse::class.java) { PortalParser.courses(doc.outerHtml()) }
    }

    @Test fun coursesRejectForeignLink() {
        val doc = org.jsoup.Jsoup.parse(fixture("courses_rendered.html"))
        doc.select("a.coursename[href]").first()!!.attr("href", "https://evil.example/course/view.php?id=1")
        assertThrows(PortalFailure.Parse::class.java) { PortalParser.courses(doc.outerHtml()) }
    }

    @Test fun courseMergeKeepsPreviouslyDownloadedCards() {
        val previous = PortalParser.courses(fixture("courses_rendered.html"))
        val observed = previous.take(1).map { it.copy(title = "Updated title") }
        val merged = PortalParser.mergeCourses(observed, previous)
        assertEquals(previous.size, merged.size)
        assertEquals("Updated title", merged.first { it.id == observed.first().id }.title)
    }

    @Test fun allGradeRowsAndSemestersMatchExpectedFixture() {
        val expected = JsonParser.parseString(fixture("academic_progress.expected.json")).asJsonArray
        val actual = PortalParser.academicProgress(fixture("academic_progress.html"))
        assertEquals(expected.size(), actual.size)
        expected.zip(actual).forEach { (json, grade) ->
            val e = json.asJsonObject
            assertEquals(e["subject"].asString, grade.subject)
            assertEquals(e["semester"].asString, grade.semester)
            assertEquals(e["grade"].asString, grade.grade)
            assertEquals(e["teachers"].asJsonArray.joinToString("\n") { it.asString }, grade.teacher)
        }
    }

    @Test fun modernSemesterTabsAreRecognized() {
        assertFalse(PortalParser.academicProgress(fixture("academic_progress_modern.html")).isEmpty())
    }

    @Test fun brokenSemesterReferenceIsRejected() {
        assertThrows(PortalFailure.Parse::class.java) { PortalParser.academicProgress("<a class='academic-link' href='#missing'>1 семестр</a>") }
    }

    @Test fun scheduleKeepsEveryReturnedDayAcrossTwoWeeks() {
        val json = fixture("ajax_schedule_two_weeks_synthetic.json")
        val html = JsonParser.parseString(json).asJsonObject["html"].asString
        val expected = org.jsoup.Jsoup.parse(html).select(".tab-content .tab-pane")
            .map { LocalDate.parse(it.id().removePrefix("day"), java.time.format.DateTimeFormatter.BASIC_ISO_DATE).toString() }.sorted()
        val actual = PortalParser.parseAjaxSchedule(json)
        assertEquals(expected, actual.days)
        assertTrue(LocalDate.parse(actual.days.last()).toEpochDay() - LocalDate.parse(actual.days.first()).toEpochDay() >= 7)
        assertTrue(actual.items.all { it.timeStart < it.timeEnd && it.subgroup.isEmpty() })
    }

    @Test fun capturedScheduleParsesDatesTimesAndTeachers() {
        val actual = PortalParser.parseAjaxSchedule(fixture("ajax_schedule.json"))
        assertTrue(actual.days.all { it.matches(Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}")) })
        assertTrue(actual.items.isNotEmpty())
        assertTrue(actual.items.all { it.subject.isNotBlank() && it.timeStart < it.timeEnd })
    }

    @Test fun malformedScheduleDoesNotReplaceHistory() {
        val previous = PortalParser.parseAjaxSchedule(fixture("ajax_schedule.json"))
        assertThrows(PortalFailure.InvalidResponse::class.java) { PortalParser.parseAjaxSchedule("{}") }
        assertThrows(PortalFailure.Parse::class.java) { PortalParser.parseAjaxSchedule(Gson().toJson(mapOf("html" to "<div class='tab-content'><div class='tab-pane' id='day212314'></div></div>"))) }
        assertTrue(previous.items.isNotEmpty())
    }

    @Test fun explicitEmptyDayReplacesOnlyThatDay() {
        val previous = PortalParser.parseAjaxSchedule(fixture("ajax_schedule.json"))
        val day = previous.items.first().day
        val observed = PortalParser.parseAjaxSchedule(Gson().toJson(mapOf("html" to "<div class='tab-content'><div class='tab-pane' id='day${day.replace("-", "")}'><table class='schedule-table'><tbody></tbody></table></div></div>")))
        val merged = PortalParser.preserveScheduleHistory(observed, previous)
        assertEquals(previous.days, merged.days)
        assertEquals(previous.items.filter { it.day != day }, merged.items)
    }

    @Test fun notificationsMatchFixtureAndRetainHistory() {
        val expected = JsonParser.parseString(fixture("rendered.expected.json")).asJsonObject["notifications"].asJsonArray
        val actual = PortalParser.notifications(fixture("notifications_rendered.html"))
        assertEquals(expected.size(), actual.size)
        assertEquals(actual.size, PortalParser.mergeNotifications(actual.take(1), actual).size)
    }

    @Test fun manualScheduleRemainsAvailableAndAlternatesWeeks() {
        val manual = ManualSchedule(fixture("manual_schedule.json"))
        assertEquals("ИС-О-25/1", manual.plan.group)
        assertEquals(2, manual.weekNumber(LocalDate.parse("2026-09-21")))
        assertEquals(1, manual.weekNumber(LocalDate.parse("2026-09-28")))
        assertEquals("2026-12-31", manual.window.days.last())
        assertTrue(manual.window.items.none { LocalDate.parse(it.day).dayOfWeek.value == 7 })
        assertTrue(manual.window.items.filter { it.lessonNumber in 1..7 }.all { it.timeStart < it.timeEnd })
        // The supplied plan includes lesson 8 but no verified time for it.
        assertTrue(manual.window.items.filter { it.lessonNumber == 8 }.all { it.timeStart.isEmpty() && it.timeEnd.isEmpty() })
    }

    private fun account(id: Int) = "<div class='usermenu'><span class='usertext'>Student</span><a href='/user/profile.php?id=$id'>Profile</a></div><a href='/login/logout.php'>Logout</a>"

    @Test fun accountIdentityUsesNumericIDNotDisplayName() {
        val a = PortalParser.authenticatedProfile(account(1), PortalConfiguration.GRADES)
        val b = PortalParser.authenticatedProfile(account(2), PortalConfiguration.GRADES)
        assertNotEquals(a.accountKey, b.accountKey)
        assertEquals(a.accountKey, PortalParser.authenticatedProfile(account(1).replace("Student", "New name"), PortalConfiguration.GRADES).accountKey)
    }

    @Test fun unknownMarkupIsNotConfirmedExpiration() {
        assertThrows(PortalFailure.Parse::class.java) { PortalParser.authenticatedProfile("<html>Maintenance</html>", PortalConfiguration.GRADES) }
    }

    @Test fun officialLoginAndMaxStillRequireAuthentication() {
        for (name in listOf("login.html", "max_form.html")) {
            assertThrows(PortalFailure.LoginRequired::class.java) { PortalParser.authenticatedProfile(fixture(name), PortalConfiguration.GRADES) }
        }
        assertThrows(PortalFailure.LoginRequired::class.java) { PortalParser.authenticatedProfile(account(1), "${PortalConfiguration.BASE}/local/loginwait/wait.php") }
    }

    @Test fun strictDataOriginsRejectLookalikesCredentialsAndHttp() {
        for (url in listOf("http://portal.ulsu.ru/", "https://portal.ulsu.ru.evil.example/", "https://user@portal.ulsu.ru/", "https://portal.ulsu.ru:8443/")) assertFalse(url, PortalConfiguration.allowsDataURL(url))
        assertTrue(PortalConfiguration.allowsDataURL(PortalConfiguration.GRADES))
        assertTrue(PortalConfiguration.allowsBrowserURL("https://s1.ulsu.ru:8443/realms/ulsu/"))
    }

    @Test fun bridgeAcceptsJsonStringAndRejectsMalformedResults() {
        assertEquals("code", LoginBridgeCodec.decode(Gson().toJson("{\"kind\":\"code\",\"pending\":true}"))!!["kind"].asString)
        for (raw in listOf("null", "{}", "42", Gson().toJson("{\"kind\":\"unexpected\"}"), Gson().toJson("{\"kind\":\"code\",\"pending\":1}"))) assertNull(LoginBridgeCodec.decode(raw))
    }
}
