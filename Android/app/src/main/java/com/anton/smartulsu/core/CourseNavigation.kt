package com.anton.smartulsu.core

object CourseNavigation {
    /** Revalidate cached links and their IDs; never derive a destination from a title. */
    fun destination(course: Course): String {
        if (course.url.isNullOrBlank()) return PortalConfiguration.COURSES
        val url = PortalParser.courseURL(course.url, PortalConfiguration.BASE)
        return url?.takeIf { it.substringAfter("?id=") == course.id }
            ?: PortalConfiguration.COURSES
    }
}
