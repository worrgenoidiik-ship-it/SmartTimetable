package com.anton.smartulsu

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.anton.smartulsu.core.*

/** Presentation only. Event deduplication is backed by the existing encrypted repository snapshot. */
object PortalNotifier {
    const val DESTINATION_EXTRA = "notificationDestination"

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java)
        for (category in PortalEventCategory.entries) {
            val name = when (category) {
                PortalEventCategory.EIOS -> "SmartTimetable · Уведомления ЭИОС"
                PortalEventCategory.SCHEDULE -> "SmartTimetable · Изменения расписания"
            }
            manager.createNotificationChannel(NotificationChannel(category.channel, name, NotificationManager.IMPORTANCE_DEFAULT))
        }
    }

    fun runtimeGranted(context: Context) = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun allowed(context: Context) = runtimeGranted(context) && NotificationManagerCompat.from(context).areNotificationsEnabled()

    internal fun enabled(category: PortalEventCategory, preferences: UiPreferences, permission: Boolean) =
        permission && preferences.notifications && when (category) {
            PortalEventCategory.EIOS -> preferences.eiosNotifications
            PortalEventCategory.SCHEDULE -> preferences.scheduleNotifications && preferences.portalSchedule
        }

    internal fun intent(context: Context, destination: NotificationDestination) =
        Intent(context, MainActivity::class.java)
            .putExtra(DESTINATION_EXTRA, destination.name)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)

    fun destination(intent: Intent): NotificationDestination? =
        NotificationDestination.entries.firstOrNull { it.name == intent.getStringExtra(DESTINATION_EXTRA) }
            ?: if (intent.getBooleanExtra("openInbox", false)) NotificationDestination.INBOX else null

    fun publish(context: Context, events: List<PortalEvent>, preferences: UiPreferences) {
        if (events.isEmpty() || !allowed(context)) return
        createChannels(context)
        val manager = context.getSystemService(NotificationManager::class.java)
        for (event in events) {
            if (!enabled(event.category, preferences, true)) continue
            if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(event.category.channel)?.importance == NotificationManager.IMPORTANCE_NONE) continue
            val pending = PendingIntent.getActivity(context, event.category.notificationId,
                intent(context, event.category.destination), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val public = NotificationCompat.Builder(context, event.category.channel)
                .setSmallIcon(R.drawable.ic_notification).setContentTitle("SmartTimetable")
                .setContentText("В ЭИОС появились обновления").build()
            // No names, grades, subjects, or portal message bodies are put on the lock screen.
            val notification = NotificationCompat.Builder(context, event.category.channel)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle(event.title).setContentText(event.message)
                .setContentIntent(pending).setAutoCancel(true)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setPublicVersion(public)
                .build()
            // Permission can be revoked between the check and notify; cache remains valid.
            runCatching { manager.notify(event.category.notificationId, notification) }
        }
    }

    fun cancel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        PortalEventCategory.entries.forEach { manager.cancel(it.notificationId) }
    }
}
