package com.anton.smartulsu.widget

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import com.anton.smartulsu.MainActivity
import com.anton.smartulsu.R
import com.anton.smartulsu.core.CampusDate
import com.anton.smartulsu.core.ScheduleWindow
import com.google.gson.Gson
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Small summary shared with the widgets; mirrors WidgetBridge.Payload on iOS. */
data class WidgetPayload(val lessons: List<Lesson>, val deadlines: List<Deadline>) {
    data class Lesson(val day: String, val start: String, val end: String, val subject: String, val type: String, val place: String)
    data class Deadline(val title: String, val kind: String, val due: Long)
}

/**
 * The app writes the summary after every data or setting change; widgets never contact the
 * portal. Only the next 14 days and 5 timed deadlines are kept, in private app storage.
 */
object WidgetBridge {
    private const val KEY = "payload"
    private val gson = Gson()

    fun payload(window: ScheduleWindow?, deadlines: List<com.anton.smartulsu.core.DeadlineItem>, now: Long = System.currentTimeMillis()): WidgetPayload {
        val today = Instant.ofEpochMilli(now).atZone(CampusDate.zone).toLocalDate()
        val limit = today.plusDays(14).toString()
        // Gson may leave lists null in caches written by older versions.
        val cancelled: Set<String> = window?.cancelledDays?.toSet() ?: emptySet()
        val lessons = window?.items.orEmpty()
            .filter { it.day >= today.toString() && it.day <= limit && it.day !in cancelled &&
                !it.requiresConfirmation && it.timeStart.isNotBlank() && it.timeEnd.isNotBlank() }
            .sortedWith(compareBy({ it.day }, { it.timeStart }))
            .take(80)
            .map { WidgetPayload.Lesson(it.day, it.timeStart, it.timeEnd, it.subject, it.type, it.place) }
        val timed = deadlines.mapNotNull { d -> d.due?.takeIf { it > now }?.let { WidgetPayload.Deadline(d.title, d.kindLabel, it) } }
            .sortedBy { it.due }.take(5)
        return WidgetPayload(lessons, timed)
    }

    fun publish(context: Context, payload: WidgetPayload?) {
        val preferences = context.getSharedPreferences("widget", Context.MODE_PRIVATE)
        val json = payload?.let(gson::toJson)
        if (json == preferences.getString(KEY, null)) return
        preferences.edit().apply { if (json == null) remove(KEY) else putString(KEY, json) }.apply()
        refreshAll(context)
    }

    fun load(context: Context): WidgetPayload? =
        context.getSharedPreferences("widget", Context.MODE_PRIVATE).getString(KEY, null)
            ?.let { runCatching { gson.fromJson(it, WidgetPayload::class.java) }.getOrNull() }

    fun refreshAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        for (provider in listOf(NextLessonWidget::class.java, TodayWidget::class.java)) {
            val ids = manager.getAppWidgetIds(ComponentName(context, provider))
            if (ids.isNotEmpty())
                context.sendBroadcast(Intent(context, provider).setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids))
        }
    }
}

/** Time helpers shared by both widgets. */
class WidgetClock(val now: LocalDateTime) {
    val today: LocalDate = now.toLocalDate()

    fun end(lesson: WidgetPayload.Lesson): LocalDateTime =
        LocalDateTime.of(LocalDate.parse(lesson.day), LocalTime.parse(lesson.end))

    fun start(lesson: WidgetPayload.Lesson): LocalDateTime =
        LocalDateTime.of(LocalDate.parse(lesson.day), LocalTime.parse(lesson.start))

    fun next(payload: WidgetPayload) = payload.lessons.firstOrNull { end(it) > now }

    fun todayLeft(payload: WidgetPayload) = payload.lessons.filter { it.day == today.toString() && end(it) > now }

    fun dayLabel(day: String): String = when (LocalDate.parse(day)) {
        today -> "Сегодня"
        today.plusDays(1) -> "Завтра"
        else -> LocalDate.parse(day).format(DateTimeFormatter.ofPattern("EE d MMM", Locale.forLanguageTag("ru")))
    }

    /** Next moment the picture changes: a lesson start/end within 36 h, else next midnight. */
    fun nextChange(payload: WidgetPayload?): LocalDateTime {
        val midnight = today.plusDays(1).atStartOfDay().plusMinutes(1)
        return payload?.lessons.orEmpty().flatMap { listOf(start(it), end(it)) }
            .filter { it > now && it < now.plusHours(36) }.minOrNull()?.takeIf { it < midnight } ?: midnight
    }
}

abstract class SmartWidgetProvider : AppWidgetProvider() {
    protected abstract fun render(context: Context, payload: WidgetPayload?, clock: WidgetClock): RemoteViews

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val clock = WidgetClock(LocalDateTime.now(CampusDate.zone))
        val payload = WidgetBridge.load(context)
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        for (id in ids) {
            val views = render(context, payload, clock)
            views.setOnClickPendingIntent(R.id.widget_root, open)
            manager.updateAppWidget(id, views)
        }
        scheduleNext(context, clock.nextChange(payload), ids)
    }

    /** Inexact alarm (no special permission): enough to move «следующая пара» forward. */
    private fun scheduleNext(context: Context, at: LocalDateTime, ids: IntArray) {
        val intent = Intent(context, javaClass).setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
            .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
        val pending = PendingIntent.getBroadcast(context, javaClass.name.hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        context.getSystemService(AlarmManager::class.java)
            ?.set(AlarmManager.RTC, at.atZone(CampusDate.zone).toInstant().toEpochMilli(), pending)
    }

    override fun onDisabled(context: Context) {
        val intent = Intent(context, javaClass).setAction(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
        PendingIntent.getBroadcast(context, javaClass.name.hashCode(), intent,
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
            ?.let { context.getSystemService(AlarmManager::class.java)?.cancel(it) }
    }

    protected fun empty(context: Context, layout: Int): RemoteViews =
        RemoteViews(context.packageName, layout).apply {
            setTextViewText(R.id.widget_title, "SMARTTIMETABLE")
            setTextViewText(R.id.widget_line1, "Откройте приложение, чтобы загрузить расписание")
            setViewVisibility(R.id.widget_line2, View.GONE)
            setViewVisibility(R.id.widget_line3, View.GONE)
        }
}

/** 2×2: the next lesson with its day, time and room. */
class NextLessonWidget : SmartWidgetProvider() {
    override fun render(context: Context, payload: WidgetPayload?, clock: WidgetClock): RemoteViews {
        if (payload == null) return empty(context, R.layout.widget_next)
        return RemoteViews(context.packageName, R.layout.widget_next).apply {
            val lesson = clock.next(payload)
            setTextViewText(R.id.widget_title, if (clock.todayLeft(payload).isEmpty()) "СЛЕДУЮЩАЯ ПАРА" else "СЕЙЧАС И ДАЛЕЕ")
            if (lesson == null) {
                setTextViewText(R.id.widget_line1, "Пар в ближайшие дни нет")
                setViewVisibility(R.id.widget_line2, View.GONE)
                setViewVisibility(R.id.widget_line3, View.GONE)
            } else {
                setTextViewText(R.id.widget_line1, "${clock.dayLabel(lesson.day)} ${lesson.start}–${lesson.end}")
                setTextViewText(R.id.widget_line2, lesson.subject)
                setTextViewText(R.id.widget_line3, lesson.place)
                setViewVisibility(R.id.widget_line2, View.VISIBLE)
                setViewVisibility(R.id.widget_line3, if (lesson.place.isBlank()) View.GONE else View.VISIBLE)
            }
        }
    }
}

/** 4×2: today's remaining lessons (or the next ones) and the nearest deadline. */
class TodayWidget : SmartWidgetProvider() {
    override fun render(context: Context, payload: WidgetPayload?, clock: WidgetClock): RemoteViews {
        if (payload == null) return empty(context, R.layout.widget_today).apply {
            setViewVisibility(R.id.widget_deadline_box, View.GONE)
        }
        return RemoteViews(context.packageName, R.layout.widget_today).apply {
            val today = clock.todayLeft(payload)
            val lessons = if (today.isEmpty()) listOfNotNull(clock.next(payload)) else today.take(3)
            setTextViewText(R.id.widget_title, if (today.isEmpty()) "БЛИЖАЙШИЕ ПАРЫ" else "СЕГОДНЯ")
            val lines = listOf(R.id.widget_line1, R.id.widget_line2, R.id.widget_line3)
            lines.forEachIndexed { index, view ->
                val lesson = lessons.getOrNull(index)
                if (lesson == null) setViewVisibility(view, if (index == 0) View.VISIBLE else View.GONE)
                else setViewVisibility(view, View.VISIBLE)
                setTextViewText(view, when {
                    lesson == null && index == 0 -> "Пар нет"
                    lesson == null -> ""
                    today.isEmpty() -> "${clock.dayLabel(lesson.day)} ${lesson.start}  ${lesson.subject}"
                    else -> "${lesson.start}  ${lesson.subject}"
                })
            }
            val deadline = payload.deadlines.firstOrNull { it.due > System.currentTimeMillis() }
            if (deadline == null) setViewVisibility(R.id.widget_deadline_box, View.GONE)
            else {
                setViewVisibility(R.id.widget_deadline_box, View.VISIBLE)
                setTextViewText(R.id.widget_deadline_title, deadline.title)
                val due = Instant.ofEpochMilli(deadline.due).atZone(CampusDate.zone)
                    .format(DateTimeFormatter.ofPattern("d MMM, HH:mm", Locale.forLanguageTag("ru")))
                setTextViewText(R.id.widget_deadline_when, "${deadline.kind} · $due")
            }
        }
    }
}
