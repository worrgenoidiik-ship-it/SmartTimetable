package com.anton.smartulsu.core

import com.google.gson.Gson
import org.junit.Assert.*
import org.junit.Test

class NotificationRetentionTest {
    private val profile = StudentProfile("synthetic", "Test")
    private fun notice(id: Int, unread: Boolean = true) =
        PortalNotification(id.toString(), "Message $id", "", unread, id.toLong())
    private fun snapshot(items: List<PortalNotification>) =
        PortalSnapshot(profile = profile, notifications = CachedSection(items, 1))
    private fun events(before: PortalSnapshot, after: PortalSnapshot) =
        PortalEvents.detect(before, after, PortalSection.NOTIFICATIONS)

    @Test fun largeUnorderedHistoryIsBoundedByNumericIdDeterministically() {
        val all = (1..10_000).map { notice(it) }
        val merged = PortalParser.mergeNotifications(all.shuffled(), emptyList())
        assertEquals(PortalParser.NOTIFICATION_HISTORY_LIMIT, merged.size)
        assertEquals((10_000 downTo 9_501).map(Int::toString), merged.map { it.id })
        assertEquals(merged, PortalParser.mergeNotifications(emptyList(), all.reversed()))
    }

    @Test fun duplicateIdsUseLatestObservationIncludingReadState() {
        val result = PortalParser.mergeNotifications(listOf(notice(2), notice(2, false)),
            listOf(notice(1), notice(2), notice(1)))
        assertEquals(listOf("2", "1"), result.map { it.id })
        assertFalse(result.first().isUnread)
        assertTrue(PortalParser.mergeNotifications(listOf(notice(2)), result).first().isUnread)
    }

    @Test fun olderPagesCannotLowerWatermarkOrReannounceTrimmedHistoryAfterRestart() {
        val current = snapshot(PortalParser.mergeNotifications((1..1000).map { notice(it) }, emptyList()))
        val restored = Gson().fromJson(Gson().toJson(current), PortalSnapshot::class.java)
        val older = snapshot(PortalParser.mergeNotifications((1..500).map { notice(it) }, restored.notifications!!.value))
        assertEquals("1000", older.notifications!!.value.first().id)
        assertEquals(current.notifications!!.value, older.notifications.value)
        assertTrue(events(restored, older).isEmpty())
        val fresh = snapshot(PortalParser.mergeNotifications(listOf(notice(1001), notice(1)), older.notifications.value))
        assertEquals(listOf(PortalEvent(PortalEventCategory.EIOS, 1)), events(older, fresh))
        assertTrue(events(fresh, fresh).isEmpty())
    }

    @Test fun initialSyncAccountSwitchAndOfflineRemainSilentWithBoundedHistory() {
        val bounded = snapshot(PortalParser.mergeNotifications((1..2000).map { notice(it) }, emptyList()))
        assertTrue(events(PortalSnapshot(profile = profile), bounded).isEmpty())
        assertTrue(events(bounded, bounded.copy(profile = StudentProfile("other", "Other"))).isEmpty())
        assertTrue(events(bounded, bounded.copy(nextRefreshAt = 999)).isEmpty())
    }
}
