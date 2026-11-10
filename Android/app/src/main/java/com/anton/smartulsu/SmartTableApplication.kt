package com.anton.smartulsu

import android.app.Application
import android.content.Context
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map

class SmartTableApplication : Application() {
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    lateinit var repository: NetworkManager
        private set

    lateinit var preferences: AppPreferences
        private set

    /** What happened to the portal session; shown in Settings, never sent anywhere by itself. */
    lateinit var journal: com.anton.smartulsu.core.SessionJournal
        private set
    private val diagnostics by lazy { getSharedPreferences("session_journal", Context.MODE_PRIVATE) }
    val lastCrash: String? get() = diagnostics.getString("lastCrash", null)

    override fun onCreate() {
        super.onCreate()
        preferences = AppPreferences(this)
        journal = com.anton.smartulsu.core.SessionJournal(
            read = { diagnostics.getString("entries", null) },
            write = { value -> diagnostics.edit().apply { if (value == null) remove("entries") else putString("entries", value) }.apply() },
        )
        recordCrashes()
        PortalNotifier.createChannels(this)
        repository = NetworkManager(this)
        applicationScope.launch { RefreshScheduler.ensure(this@SmartTableApplication) }
        RefreshScheduler.ensureKeepAlive(this)
        watchSession()
        // Deadline reminders follow the cached calendar and the notification settings.
        applicationScope.launch {
            combine(
                repository.state.map { it.snapshot.deadlines?.value.orEmpty() }.distinctUntilChanged(),
                preferences.state.map { it.notifications to it.deadlineNotifications }.distinctUntilChanged(),
            ) { deadlines, _ -> deadlines }
                .collect { DeadlineReminders.reschedule(this@SmartTableApplication, it, preferences.state.value) }
        }
        // Widgets show a small summary rebuilt on every relevant change; cleared on logout.
        applicationScope.launch {
            combine(
                repository.state.map { it.snapshot }.distinctUntilChanged { a, b ->
                    a.profile == b.profile && a.portalSchedule == b.portalSchedule && a.deadlines == b.deadlines
                },
                repository.manualScheduleState,
                preferences.state.map { it.scheduleSource }.distinctUntilChanged(),
            ) { snapshot, manual, source ->
                if (snapshot.profile == null) null
                else com.anton.smartulsu.widget.WidgetBridge.payload(
                    com.anton.smartulsu.core.ScheduleSource.window(snapshot, manual, source),
                    snapshot.deadlines?.value.orEmpty(),
                )
            }.collect { com.anton.smartulsu.widget.WidgetBridge.publish(this@SmartTableApplication, it) }
        }
    }

    private fun watchSession() {
        applicationScope.launch {
            var last: com.anton.smartulsu.core.SessionState? = null
            repository.state.map { it.session }.distinctUntilChanged().collect { session ->
                com.anton.smartulsu.core.SessionJournal.describe(last, session)?.let(journal::add)
                last = session
            }
        }
        applicationScope.launch {
            var signedIn: Boolean? = null
            repository.state.map { it.snapshot.profile != null }.distinctUntilChanged().collect { now ->
                if (signedIn == true && !now) journal.add("Выход из аккаунта: данные удалены с телефона")
                signedIn = now
            }
        }
    }

    /** A short summary of the last crash (exception and our own code lines, no user data) for
     *  «Сообщить о проблеме». Then Android shows its usual «приложение остановлено». */
    private fun recordCrashes() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            runCatching {
                val time = java.text.SimpleDateFormat("dd.MM.yyyy HH:mm", java.util.Locale.ROOT).format(java.util.Date())
                val version = packageManager.getPackageInfo(packageName, 0).versionName ?: "?"
                diagnostics.edit().putString("lastCrash", com.anton.smartulsu.core.ProblemReport.crashSummary(time, version, error)).commit()
            }
            previous?.uncaughtException(thread, error)
        }
    }

    /** Moodle's idle timer restarts at the last request: touch once when the user leaves. */
    fun touchSessionOnLeaving() {
        applicationScope.launch { runCatching { repository.keepAliveIfNeeded(60_000) } }
    }
}

data class UiPreferences(
    val dark: Boolean = true,
    val christmas: Boolean = false,
    val autoRefresh: Boolean = true,
    val notifications: Boolean = false,
    val eiosNotifications: Boolean = true,
    val scheduleNotifications: Boolean = true,
    val deadlineNotifications: Boolean = true,
    val notificationPermissionAsked: Boolean = false,
    val appLock: Boolean = false,
    val cardStyle: Int = 0,
    val scheduleSource: String = com.anton.smartulsu.core.ScheduleSource.AUTO,
    val showGradeBook: Boolean = true,
    val showAssessments: Boolean = true,
) {
    /** Portal schedule data is in use (for change notifications and refresh prompts). */
    val portalSchedule: Boolean get() = scheduleSource != com.anton.smartulsu.core.ScheduleSource.MANUAL
}

class AppPreferences(context: Context) {
    private val preferences = context.getSharedPreferences("appearance", Context.MODE_PRIVATE)
    private val mutable =
        MutableStateFlow(
            UiPreferences(
                dark = preferences.getBoolean("dark", true),
                christmas = preferences.getBoolean("christmas", false),
                autoRefresh = preferences.getBoolean("autoRefresh", true),
                notifications = preferences.getBoolean("notifications", false),
                eiosNotifications = preferences.getBoolean("eiosNotifications", true),
                scheduleNotifications = preferences.getBoolean("scheduleNotifications", true),
                deadlineNotifications = preferences.getBoolean("deadlineNotifications", true),
                notificationPermissionAsked = preferences.getBoolean("notificationPermissionAsked", false),
                appLock = preferences.getBoolean("appLock", false),
                cardStyle = preferences.getInt("cardStyle", 0),
                // 1.x stored an on/off switch; keep that choice, new installs start in Auto.
                scheduleSource = preferences.getString("scheduleSource", null)
                    ?: if (!preferences.contains("portalSchedule")) com.anton.smartulsu.core.ScheduleSource.AUTO
                    else if (preferences.getBoolean("portalSchedule", true)) com.anton.smartulsu.core.ScheduleSource.PORTAL
                    else com.anton.smartulsu.core.ScheduleSource.MANUAL,
                showGradeBook = preferences.getBoolean("showGradeBook", true),
                showAssessments = preferences.getBoolean("showAssessments", true),
            )
        )
    val state = mutable.asStateFlow()

    fun update(transform: (UiPreferences) -> UiPreferences) {
        val v = transform(mutable.value)
        preferences
            .edit()
            .putBoolean("dark", v.dark)
            .putBoolean("christmas", v.christmas)
            .putBoolean("autoRefresh", v.autoRefresh)
            .putBoolean("notifications", v.notifications)
            .putBoolean("eiosNotifications", v.eiosNotifications)
            .putBoolean("scheduleNotifications", v.scheduleNotifications)
            .putBoolean("deadlineNotifications", v.deadlineNotifications)
            .putBoolean("notificationPermissionAsked", v.notificationPermissionAsked)
            .putBoolean("appLock", v.appLock)
            .putInt("cardStyle", v.cardStyle)
            .putString("scheduleSource", v.scheduleSource)
            .putBoolean("showGradeBook", v.showGradeBook)
            .putBoolean("showAssessments", v.showAssessments)
            .apply()
        mutable.value = v
    }
}
