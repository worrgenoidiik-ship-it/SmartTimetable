package com.anton.smartulsu

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.*
import com.anton.smartulsu.core.DeadlineItem
import java.util.concurrent.TimeUnit

/**
 * Port of the iOS deadline reminders: 24 h and 3 h before every deadline whose exact
 * time the calendar exposes, nearest 12 only. WorkManager keeps them across reboots;
 * the whole set is rebuilt whenever the deadlines or the settings change.
 */
object DeadlineReminders {
    private const val TAG = "smarttable.deadline"
    private const val CHANNEL = "eios_deadlines"

    fun reschedule(context: Context, deadlines: List<DeadlineItem>, preferences: UiPreferences) {
        val work = WorkManager.getInstance(context.applicationContext)
        work.cancelAllWorkByTag(TAG)
        if (!preferences.notifications || !preferences.deadlineNotifications) return
        val now = System.currentTimeMillis()
        deadlines.asSequence()
            .mapNotNull { item -> item.due?.let { item to it } }
            .flatMap { (item, due) ->
                sequenceOf(24 to "через сутки", 3 to "через 3 часа").map { (hours, label) ->
                    Triple(item, due - hours * 3_600_000L, label)
                }
            }
            .filter { it.second > now }
            .sortedBy { it.second }
            .take(12)
            .forEach { (item, at, label) ->
                val request = OneTimeWorkRequestBuilder<DeadlineReminderWorker>()
                    .setInitialDelay(at - now, TimeUnit.MILLISECONDS)
                    .addTag(TAG)
                    .setInputData(workDataOf(
                        "title" to "${item.kindLabel}: срок $label",
                        "body" to item.title + if (item.course.isNotBlank()) " · ${item.course}" else "",
                        "id" to (item.id + label).hashCode(),
                    ))
                    .build()
                work.enqueue(request)
            }
    }

    internal fun post(context: Context, id: Int, title: String, body: String) {
        if (!PortalNotifier.allowed(context)) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "SmartTimetable · Дедлайны", NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(context, 102,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        // Same privacy rule as PortalNotifier: no course names on the lock screen.
        val public = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification).setContentTitle("SmartTimetable")
            .setContentText("Скоро срок сдачи").build()
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title).setContentText(body)
            .setContentIntent(open).setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE).setPublicVersion(public)
            .build()
        runCatching { manager.notify(id, notification) }
    }
}

class DeadlineReminderWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    override fun doWork(): Result {
        val app = applicationContext as SmartTableApplication
        val preferences = app.preferences.state.value
        if (preferences.notifications && preferences.deadlineNotifications)
            DeadlineReminders.post(applicationContext, inputData.getInt("id", 103),
                inputData.getString("title").orEmpty(), inputData.getString("body").orEmpty())
        return Result.success()
    }
}
