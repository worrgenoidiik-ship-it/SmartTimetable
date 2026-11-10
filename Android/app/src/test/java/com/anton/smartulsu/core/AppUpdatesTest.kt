package com.anton.smartulsu.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppUpdatesTest {
    private val json = """
        [
          {"tag_name":"v1.9.5","draft":false,"prerelease":false,"html_url":"https://github.com/worrgenoidiik-ship-it/SmartTimetable/releases/tag/v1.9.5","assets":[]},
          {"tag_name":"android-v2.0.2","draft":false,"prerelease":false,
           "html_url":"https://github.com/worrgenoidiik-ship-it/SmartTimetable/releases/tag/android-v2.0.2","body":"Проверка обновлений",
           "assets":[{"browser_download_url":"https://github.com/worrgenoidiik-ship-it/SmartTimetable/releases/download/android-v2.0.2/SmartTimetable-2.0.2.apk"}]},
          {"tag_name":"android-v2.0.10","draft":true,"prerelease":false,"assets":[]},
          {"tag_name":"android-v2.1.0","draft":false,"prerelease":true,"assets":[]},
          {"tag_name":"android-v2.0.1","draft":false,"prerelease":false,"assets":[]}
        ]
    """.trimIndent()

    @Test fun picksNewestPublishedAndroidRelease() {
        val release = AppUpdates.latest(json)!!
        assertEquals("2.0.2", release.version)
        assertEquals("https://github.com/worrgenoidiik-ship-it/SmartTimetable/releases/download/android-v2.0.2/SmartTimetable-2.0.2.apk", release.apkUrl)
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

    @Test fun apkOnlyFromThisRepositoryAndThisRelease() {
        val own = "https://github.com/worrgenoidiik-ship-it/SmartTimetable/releases/download/android-v2.0.5/SmartTimetable-2.0.5.apk"
        assertTrue(AppUpdates.isOwnApk(own, "android-v2.0.5"))
        assertFalse(AppUpdates.isOwnApk(own, "android-v2.0.4"))
        assertFalse(AppUpdates.isOwnApk("https://github.com/someone/SmartTimetable/releases/download/android-v2.0.5/a.apk", "android-v2.0.5"))
        assertFalse(AppUpdates.isOwnApk("https://github.com/worrgenoidiik-ship-it/SmartTimetable/releases/download/android-v2.0.5/../x/a.apk", "android-v2.0.5"))
        assertFalse(AppUpdates.isOwnApk(own.removeSuffix(".apk") + ".zip", "android-v2.0.5"))
        val foreign = """[{"tag_name":"android-v9.0","draft":false,"prerelease":false,
            "html_url":"https://github.com/someone/fake/releases/tag/android-v9.0",
            "assets":[{"browser_download_url":"https://github.com/someone/fake/releases/download/android-v9.0/a.apk"}]}]"""
        val release = AppUpdates.latest(foreign)!!
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

    @Test fun laterAsksAgainAfterThreeDaysAndSkipHidesOnlyThatVersion() {
        val now = 1_800_000_000_000L
        assertTrue(AppUpdates.shouldPrompt("2.0.4", "2.0.3", null, null, 0, now))
        // «Позже»: silent for three days, then asks again
        val until = now + AppUpdates.SNOOZE_MILLIS
        assertFalse(AppUpdates.shouldPrompt("2.0.4", "2.0.3", null, "2.0.4", until, now + 1))
        assertTrue(AppUpdates.shouldPrompt("2.0.4", "2.0.3", null, "2.0.4", until, until))
        // a newer version is offered at once even during the pause
        assertTrue(AppUpdates.shouldPrompt("2.0.5", "2.0.3", null, "2.0.4", until, now + 1))
        // «Пропустить»: never for that version, but yes for the next one
        assertFalse(AppUpdates.shouldPrompt("2.0.4", "2.0.3", "2.0.4", null, 0, now))
        assertTrue(AppUpdates.shouldPrompt("2.0.5", "2.0.3", "2.0.4", null, 0, now))
        // never an older or equal version
        assertFalse(AppUpdates.shouldPrompt("2.0.3", "2.0.3", null, null, 0, now))
    }
}
