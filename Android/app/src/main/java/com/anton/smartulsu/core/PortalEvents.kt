package com.anton.smartulsu.core

import java.time.LocalDate

/** Only facts from successfully parsed, committed portal snapshots become events. */
enum class NotificationDestination { INBOX, SCHEDULE }

enum class PortalEventCategory(val channel: String, val notificationId: Int, val destination: NotificationDestination) {
    EIOS("eios", 100, NotificationDestination.INBOX),
    SCHEDULE("eios_schedule", 101, NotificationDestination.SCHEDULE),
}

data class PortalEvent(val category: PortalEventCategory, val count: Int) {
    val title: String get() = when (category) {
        PortalEventCategory.EIOS -> "SmartTimetable · ЭИОС"
        PortalEventCategory.SCHEDULE -> "SmartTimetable · Расписание"
    }
    val message: String get() = when (category) {
        PortalEventCategory.EIOS -> "Новых уведомлений: $count. Откройте приложение."
        PortalEventCategory.SCHEDULE -> "ЭИОС обновила расписание. Дней с изменениями: $count."
    }
}

object PortalEvents {
    fun detect(before: PortalSnapshot, after: PortalSnapshot, section: PortalSection,
               today: LocalDate = CampusDate.today()): List<PortalEvent> {
        if (before.profile == null || before.profile.accountKey != after.profile?.accountKey) return emptyList()
        return when (section) {
            PortalSection.NOTIFICATIONS -> {
                val previous = before.notifications?.value ?: return emptyList()
                val current = after.notifications?.value ?: return emptyList()
                val known = previous.map { it.id }.toSet()
                // Older pages of history must not look like new messages. Portal IDs are numeric.
                val newest = previous.maxOfOrNull { it.id.toLongOrNull() ?: 0L } ?: 0L
                val count = current.distinctBy { it.id }.count {
                    it.isUnread && it.id !in known && (it.id.toLongOrNull() ?: 0L) > newest
                }
                if (count > 0) listOf(PortalEvent(PortalEventCategory.EIOS, count)) else emptyList()
            }
            PortalSection.SCHEDULE -> {
                val previous = before.portalSchedule?.value ?: return emptyList()
                val current = after.portalSchedule?.value ?: return emptyList()
                if (previous.origin != "portal" || current.origin != "portal") return emptyList()
                val dates = previous.days.toSet().intersect(current.days.toSet()).filter {
                    runCatching { !LocalDate.parse(it).isBefore(today) }.getOrDefault(false)
                }
                val count = dates.count { day -> fingerprint(previous, day) != fingerprint(current, day) }
                // New coverage and missing days are not cancellations. Never infer a cancellation label.
                if (count > 0) listOf(PortalEvent(PortalEventCategory.SCHEDULE, count)) else emptyList()
            }
            else -> emptyList() // A course card or changed grade is not evidence of a new announcement.
        }
    }

    private fun fingerprint(window: ScheduleWindow, day: String) = window.items.filter { it.day == day }.map {
        StableID.make(it.timeStart, it.timeEnd, it.type, it.subject, it.teacher, it.place, it.subgroup)
    }.sorted()
}

object NotificationPermissionPolicy {
    enum class Action { ENABLE, REQUEST, SETTINGS }
    fun action(runtimeRequired: Boolean, runtimeGranted: Boolean, asked: Boolean, systemEnabled: Boolean) = when {
        runtimeRequired && !runtimeGranted -> if (asked) Action.SETTINGS else Action.REQUEST
        !systemEnabled -> Action.SETTINGS
        else -> Action.ENABLE
    }
}
