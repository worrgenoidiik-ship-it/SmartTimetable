package com.anton.smartulsu.core

import com.anton.smartulsu.PortalNotifier
import com.anton.smartulsu.UiPreferences
import com.google.gson.Gson
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class PortalEventsTest {
    private val today = LocalDate.of(2026, 10, 12)
    private val profile = StudentProfile("synthetic", "Private name")
    private fun notice(id: String, unread: Boolean = true) = PortalNotification(id, "Private message", "сейчас", unread)
    private fun snapshot(vararg ids: String) = PortalSnapshot(profile = profile,
        notifications = CachedSection(ids.map { notice(it) }))
    private fun events(a: PortalSnapshot, b: PortalSnapshot, section: PortalSection = PortalSection.NOTIFICATIONS) =
        PortalEvents.detect(a, b, section, today)
    private fun lesson(day: String, place: String = "A", id: String = "one") =
        ScheduleItem(id, day, "09:00", "10:00", "Лекция", "Private subject", "Private teacher", place)
    private fun schedule(vararg items: ScheduleItem) = PortalSnapshot(profile = profile,
        portalSchedule = CachedSection(ScheduleWindow(items.map { it.day }.distinct(), items.toList())))

    @Test fun initialSynchronizationAndAccountChangeAreSilent() {
        assertTrue(events(PortalSnapshot(profile = profile), snapshot("20")).isEmpty())
        assertTrue(events(snapshot("10"), snapshot("20").copy(profile = StudentProfile("other", "Other"))).isEmpty())
        assertTrue(events(PortalSnapshot(), snapshot("20")).isEmpty())
        assertTrue(events(PortalSnapshot(profile = profile), schedule(lesson(today.toString())), PortalSection.SCHEDULE).isEmpty())
    }

    @Test fun newUnreadPortalIdsProduceOneInboxSummary() {
        val result = events(snapshot("10"), snapshot("10", "11", "12"))
        assertEquals(listOf(PortalEvent(PortalEventCategory.EIOS, 2)), result)
        assertEquals(NotificationDestination.INBOX, result.single().category.destination)
        assertFalse(result.single().message.contains("Private"))
    }

    @Test fun unreadFlagChangeAndOlderHistoryAreNotNewEvents() {
        val old = snapshot("10").copy(notifications = CachedSection(listOf(notice("10", false))))
        assertTrue(events(old, snapshot("9", "10")).isEmpty())
        assertTrue(events(snapshot("10"), snapshot("10").copy(notifications = CachedSection(listOf(notice("11", false))))).isEmpty())
    }

    @Test fun persistedMergedSnapshotSuppressesDuplicatesAfterRestart() {
        val before = snapshot("10")
        val after = snapshot("10", "11")
        assertEquals(1, events(before, after).size)
        val restored = Gson().fromJson(Gson().toJson(after), PortalSnapshot::class.java)
        val refreshed = restored.copy(notifications = CachedSection(
            PortalParser.mergeNotifications(listOf(notice("11")), restored.notifications!!.value)))
        assertTrue(events(restored, refreshed).isEmpty())
        assertTrue(events(refreshed, snapshot("10", "11")).isEmpty())
    }

    @Test fun offlineOrUnchangedSnapshotsProduceNoEvents() {
        val old = snapshot("10")
        assertTrue(events(old, old).isEmpty())
        assertTrue(events(old, old.copy(nextRefreshAt = 99)).isEmpty())
    }

    @Test fun confirmedChangeOnKnownFutureDayOpensSchedule() {
        val before = schedule(lesson(today.toString()))
        val after = schedule(lesson(today.toString(), "B"))
        val result = events(before, after, PortalSection.SCHEDULE).single()
        assertEquals(PortalEventCategory.SCHEDULE, result.category)
        assertEquals(NotificationDestination.SCHEDULE, result.category.destination)
        assertEquals(1, result.count)
        assertFalse(result.message.contains("отмен", true))
        assertFalse(result.message.contains("Private"))
        val restored = Gson().fromJson(Gson().toJson(after), PortalSnapshot::class.java)
        assertTrue(events(restored, after, PortalSection.SCHEDULE).isEmpty())
    }

    @Test fun newCoverageMissingDaysPastDatesAndOrderDoNotSignalChanges() {
        val before = schedule(lesson(today.toString()), lesson(today.plusDays(1).toString()))
        val more = schedule(*before.portalSchedule!!.value.items.toTypedArray(), lesson(today.plusDays(2).toString()))
        assertTrue(events(before, more, PortalSection.SCHEDULE).isEmpty())
        val less = schedule(lesson(today.toString()))
        assertTrue(events(before, less, PortalSection.SCHEDULE).isEmpty())
        val reordered = before.copy(portalSchedule = CachedSection(before.portalSchedule.value.copy(items = before.portalSchedule.value.items.reversed())))
        assertTrue(events(before, reordered, PortalSection.SCHEDULE).isEmpty())
        assertTrue(events(schedule(lesson("2026-10-11")), schedule(lesson("2026-10-11", "B")), PortalSection.SCHEDULE).isEmpty())
    }

    @Test fun explicitEmptyDayIsOnlyAnUpdateNotAnInferredCancellation() {
        val before = schedule(lesson(today.toString()))
        val after = before.copy(portalSchedule = CachedSection(ScheduleWindow(listOf(today.toString()), emptyList())))
        assertEquals(1, events(before, after, PortalSection.SCHEDULE).size)
    }

    @Test fun manualScheduleAndCourseCardsNeverInventPortalEvents() {
        val before = schedule(lesson(today.toString())).let {
            it.copy(portalSchedule = CachedSection(it.portalSchedule!!.value.copy(origin = "manual")))
        }
        assertTrue(events(before, schedule(lesson(today.toString(), "B")), PortalSection.SCHEDULE).isEmpty())
        assertTrue(events(snapshot("10"), snapshot("11"), PortalSection.COURSES).isEmpty())
        assertTrue(events(snapshot("10"), snapshot("11"), PortalSection.GRADES).isEmpty())
    }

    @Test fun missingPermissionAndDisabledCategoriesCannotPublish() {
        val pref = UiPreferences(notifications = true)
        for (category in PortalEventCategory.entries) {
            assertFalse(PortalNotifier.enabled(category, pref, false))
            assertFalse(PortalNotifier.enabled(category, pref.copy(notifications = false), true))
            assertTrue(PortalNotifier.enabled(category, pref, true))
        }
        assertFalse(PortalNotifier.enabled(PortalEventCategory.EIOS, pref.copy(eiosNotifications = false), true))
        assertFalse(PortalNotifier.enabled(PortalEventCategory.SCHEDULE, pref.copy(scheduleNotifications = false), true))
        assertFalse(PortalNotifier.enabled(PortalEventCategory.SCHEDULE, pref.copy(scheduleSource = ScheduleSource.MANUAL), true))
    }

    @Test fun deniedPermissionGoesToSettingsInsteadOfAnotherPrompt() {
        assertEquals(NotificationPermissionPolicy.Action.REQUEST, NotificationPermissionPolicy.action(true, false, false, false))
        assertEquals(NotificationPermissionPolicy.Action.SETTINGS, NotificationPermissionPolicy.action(true, false, true, false))
        assertEquals(NotificationPermissionPolicy.Action.ENABLE, NotificationPermissionPolicy.action(true, true, true, true))
        assertEquals(NotificationPermissionPolicy.Action.SETTINGS, NotificationPermissionPolicy.action(false, true, false, false))
    }
}
