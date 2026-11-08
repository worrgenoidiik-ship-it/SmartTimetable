package com.anton.smartulsu.core

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class BrandingCompatibilityTest {
    private fun source(path: String): String {
        val module = if (File("src/main").isDirectory) File(".") else File("app")
        return File(module, path).readText()
    }

    @Test fun launcherNameChangesWithoutChangingPersistentIdentifiers() {
        assertTrue(source("src/main/res/values/strings.xml").contains(">SmartTimetable<"))
        assertTrue(source("build.gradle.kts").contains("applicationId = \"com.anton.smartulsu\""))
        val storage = source("src/main/java/com/anton/smartulsu/data/CacheStore.kt")
        for (id in listOf("portal-v1.enc", "smarttable.cache.v1", "logout.pending")) assertTrue(id, storage.contains("\"$id\""))
        val preferences = source("src/main/java/com/anton/smartulsu/SmartTableApplication.kt")
        for (id in listOf("appearance", "notifications", "autoRefresh", "portalSchedule", "appLock")) assertTrue(id, preferences.contains("\"$id\""))
        assertTrue(source("src/main/java/com/anton/smartulsu/RefreshScheduler.kt").contains("\"smarttable.eios.refresh\""))
        assertEquals("eios", PortalEventCategory.EIOS.channel)
        assertEquals(100, PortalEventCategory.EIOS.notificationId)
    }
}
