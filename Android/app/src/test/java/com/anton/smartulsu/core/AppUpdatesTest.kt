package com.anton.smartulsu.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppUpdatesTest {
    private val json = """
        [
          {"tag_name":"v1.9.5","draft":false,"prerelease":false,"html_url":"https://github.com/x/y/releases/tag/v1.9.5","assets":[]},
          {"tag_name":"android-v2.0.2","draft":false,"prerelease":false,
           "html_url":"https://github.com/x/y/releases/tag/android-v2.0.2","body":"Проверка обновлений",
           "assets":[{"browser_download_url":"https://github.com/x/y/releases/download/android-v2.0.2/SmartTimetable-2.0.2.apk"}]},
          {"tag_name":"android-v2.0.10","draft":true,"prerelease":false,"assets":[]},
          {"tag_name":"android-v2.1.0","draft":false,"prerelease":true,"assets":[]},
          {"tag_name":"android-v2.0.1","draft":false,"prerelease":false,"assets":[]}
        ]
    """.trimIndent()

    @Test fun picksNewestPublishedAndroidRelease() {
        val release = AppUpdates.latest(json)!!
        assertEquals("2.0.2", release.version)
        assertEquals("https://github.com/x/y/releases/download/android-v2.0.2/SmartTimetable-2.0.2.apk", release.apkUrl)
        assertEquals("Проверка обновлений", release.notes)
    }

    @Test fun ignoresGarbageAndForeignLinks() {
        assertNull(AppUpdates.latest("not json"))
        assertNull(AppUpdates.latest("""{"message":"Not Found"}"""))
        val evil = """[{"tag_name":"android-v9.0","draft":false,"prerelease":false,
            "html_url":"https://evil.example/x","assets":[{"browser_download_url":"https://evil.example/a.apk"}]}]"""
        val release = AppUpdates.latest(evil)!!
        assertNull(release.apkUrl)
        assertEquals(AppUpdates.RELEASES_PAGE, release.pageUrl)
    }

    @Test fun comparesVersionsNumerically() {
        assertTrue(AppUpdates.isNewer("2.0.10", "2.0.9"))
        assertTrue(AppUpdates.isNewer("2.1", "2.0.9"))
        assertFalse(AppUpdates.isNewer("2.0.1", "2.0.1"))
        assertFalse(AppUpdates.isNewer("2.0", "2.0.0"))
        assertFalse(AppUpdates.isNewer("2.0.1", "2.0.2"))
    }
}
