package com.anton.smartulsu.core

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * A short local log of what happened to the portal session (port of the iOS SessionJournal):
 * when it was active, lost, offline, signed out. Shown in Settings and added to «Сообщить о
 * проблеме». Never holds cookies, sesskeys, passwords, names or page text.
 */
class SessionJournal(private val read: () -> String?, private val write: (String?) -> Unit, private val now: () -> Long = System::currentTimeMillis) {
    data class Entry(val time: Long, val text: String)

    @Synchronized fun add(text: String) {
        val values = (entries() + Entry(now(), text.take(300))).takeLast(LIMIT)
        write(gson.toJson(values))
    }

    @Synchronized fun entries(): List<Entry> = runCatching {
        gson.fromJson<List<Entry>>(read() ?: return emptyList(), type).orEmpty().filter { it.text != null }
    }.getOrDefault(emptyList())

    @Synchronized fun clear() = write(null)

    /** Newest first, one line per event, for copying and for the problem report. */
    fun text(): String = entries().reversed().joinToString("\n") { format.format(Instant.ofEpochMilli(it.time)) + "  " + it.text }

    companion object {
        const val LIMIT = 250
        private val gson = Gson()
        private val type = object : TypeToken<List<Entry>>() {}.type
        private val format = DateTimeFormatter.ofPattern("dd.MM HH:mm:ss").withZone(ZoneId.of("Europe/Samara"))

        /** What a change of the session state means, in words; null when nothing worth noting. */
        fun describe(old: SessionState?, new: SessionState): String? = when {
            old == new -> null
            new == SessionState.ACTIVE -> if (old == SessionState.NEEDS_LOGIN) "Вход выполнен, сессия ЭИОС активна"
                else if (old == SessionState.OFFLINE) "Связь с ЭИОС восстановлена" else "Сессия ЭИОС активна"
            new == SessionState.NEEDS_LOGIN -> if (old == null || old == SessionState.UNCHECKED) "При запуске ЭИОС попросила войти"
                else "ЭИОС завершила сессию: нужен вход"
            new == SessionState.OFFLINE -> "Нет связи с ЭИОС"
            else -> null
        }
    }
}

/** «Сообщить о проблеме»: a text the student sends themselves; same rules as on iOS. */
object ProblemReport {
    const val PROJECT_URL = "https://github.com/worrgenoidiik-ship-it/SmartTimetable/issues"
    const val JOURNAL_LINES = 40

    fun text(version: String, system: String, device: String, group: String?, errors: Map<String, String>,
             journal: String, crash: String?): String = buildList {
        add("SmartTimetable $version · $system · $device")
        add("Группа: ${group ?: "не определена"}")
        if (errors.isEmpty()) add("Ошибок загрузки нет")
        else { add("Ошибки загрузки:"); errors.toSortedMap().forEach { (k, v) -> add("  $k: $v") } }
        if (!crash.isNullOrBlank()) { add("Последнее падение:"); add(crash) }
        val recent = journal.lines().filter { it.isNotBlank() }.take(JOURNAL_LINES)
        if (recent.isNotEmpty()) { add("Журнал сессии (последние ${recent.size}):"); addAll(recent) }
        add("")
        add("Что случилось (допишите своими словами): ")
    }.joinToString("\n")

    /** Crash summary without user data: exception class, message start and our own frames. */
    fun crashSummary(time: String, version: String, error: Throwable): String {
        val frames = error.stackTrace.filter { it.className.startsWith("com.anton.smartulsu") }.take(8)
            .joinToString(" < ") { "${it.className.substringAfterLast('.')}.${it.methodName}:${it.lineNumber}" }
        return listOf("$time · версия $version · ${error.javaClass.name}", error.message.orEmpty().take(200), frames)
            .filter { it.isNotBlank() }.joinToString("\n")
    }
}
