package com.anton.smartulsu

import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import androidx.test.platform.app.InstrumentationRegistry
import com.anton.smartulsu.core.*
import org.junit.Assert.*
import org.junit.Test

/** Run only on an isolated/read-only emulator with permission granted. Uses synthetic summaries. */
class PortalNotifierTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun notificationCategoriesPublishPrivateSummariesAndMapToScreens() {
        assertTrue("Grant POST_NOTIFICATIONS on the isolated emulator before running", PortalNotifier.allowed(context))
        val manager = context.getSystemService(NotificationManager::class.java)
        try {
            PortalNotifier.publish(context, PortalEventCategory.entries.map { PortalEvent(it, 2) }, UiPreferences(notifications = true))
            for (category in PortalEventCategory.entries) {
                val notification = manager.activeNotifications.single { it.id == category.notificationId }.notification
                assertEquals(Notification.VISIBILITY_PRIVATE, notification.visibility)
                assertEquals("SmartTimetable", notification.publicVersion.extras.getString(Notification.EXTRA_TITLE))
                assertTrue(notification.extras.getString(Notification.EXTRA_TITLE)!!.startsWith("SmartTimetable"))
                assertNotNull(notification.contentIntent)
                val intent = PortalNotifier.intent(context, category.destination)
                assertEquals(category.destination, PortalNotifier.destination(intent))
                assertEquals(MainActivity::class.java.name, intent.component!!.className)
            }
            assertEquals(NotificationDestination.INBOX, PortalNotifier.destination(Intent().putExtra("openInbox", true)))
            assertNull(PortalNotifier.destination(Intent().putExtra(PortalNotifier.DESTINATION_EXTRA, "unknown")))
        } finally {
            PortalNotifier.cancel(context)
        }
    }

    @Test fun missingPermissionDoesNotPost() {
        assertFalse("Revoke POST_NOTIFICATIONS on the isolated emulator before running", PortalNotifier.allowed(context))
        val manager = context.getSystemService(NotificationManager::class.java)
        val before = manager.activeNotifications.map { it.id }.toSet()
        PortalNotifier.publish(context, listOf(PortalEvent(PortalEventCategory.EIOS, 99)), UiPreferences(notifications = true))
        assertEquals(before, manager.activeNotifications.map { it.id }.toSet())
    }
}
