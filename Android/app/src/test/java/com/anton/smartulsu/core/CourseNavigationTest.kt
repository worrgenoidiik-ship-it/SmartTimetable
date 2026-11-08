package com.anton.smartulsu.core

import com.google.gson.Gson
import org.junit.Assert.*
import org.junit.Test

class CourseNavigationTest {
    @Test fun capturedCoursesOpenTheirOwnParsedIds() {
        val html = javaClass.getResource("/courses_rendered.html")!!.readText()
        val courses = PortalParser.courses(html)
        assertTrue(courses.size > 1)
        assertEquals(courses.size, courses.map(CourseNavigation::destination).distinct().size)
        courses.forEach { assertEquals(it.url, CourseNavigation.destination(it)) }
    }

    @Test fun missingLegacyUrlAndEmptyUrlFallBack() {
        val legacy = Gson().fromJson("""{"id":"42","title":"Synthetic","teacher":""}""", Course::class.java)
        assertEquals(PortalConfiguration.COURSES, CourseNavigation.destination(legacy))
        assertEquals(PortalConfiguration.COURSES, destination(""))
    }

    @Test fun foreignMalformedAndAuthenticationUrlsFallBack() {
        for (url in listOf("https://evil.example/course/view.php?id=42", "javascript:alert(1)",
            "https://portal.ulsu.ru.evil.example/course/view.php?id=42", "not a url", "/login/index.php",
            "https://user@portal.ulsu.ru/course/view.php?id=42", "http://portal.ulsu.ru/course/view.php?id=42",
            "https://s1.ulsu.ru:8443/course/view.php?id=42", "/course/view.php?id=0")) {
            assertEquals(url, PortalConfiguration.COURSES, destination(url))
        }
    }

    @Test fun mismatchingCourseIdFallsBackRatherThanOpeningAnotherCourse() {
        assertEquals(PortalConfiguration.COURSES, destination("/course/view.php?id=99"))
    }

    @Test fun validatedRelativeLinkIsCanonicalizedWithoutUntrustedExtraParameters() {
        assertEquals("${PortalConfiguration.BASE}/course/view.php?id=42",
            destination("/course/view.php?id=42&redirect=https://evil.example/#anything"))
    }

    private fun destination(url: String) = CourseNavigation.destination(Course("42", "Not an ID", "", url))
}
