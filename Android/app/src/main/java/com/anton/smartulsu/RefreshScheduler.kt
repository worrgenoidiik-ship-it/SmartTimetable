package com.anton.smartulsu

import android.content.Context
import androidx.work.*
import com.anton.smartulsu.core.PortalConfiguration
import com.anton.smartulsu.core.RefreshSessionToken
import java.util.concurrent.TimeUnit
import com.anton.smartulsu.data.PortalRequestCancelled
import kotlinx.coroutines.*

object RefreshScheduler {
    private val schedulingLock = Any()
    private const val NAME = "smarttable.eios.refresh"
    private const val KEEP_ALIVE = "smarttable.eios.keepalive"

    /**
     * Keeps the portal session from idling out: WorkManager's shortest period (15 min),
     * network required, survives reboots and app kills. Doze may batch runs into its
     * maintenance windows; that is the most Android allows without a foreground service.
     */
    fun ensureKeepAlive(context: Context) {
        val request = PeriodicWorkRequestBuilder<SessionKeepAliveWorker>(15, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniquePeriodicWork(KEEP_ALIVE, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    internal suspend fun ensure(context: Context, afterWorker: Boolean = false, session: RefreshSessionToken? = null) {
        val app = context.applicationContext as SmartTableApplication
        ensure(app.repository, session, { app.preferences.state.value.autoRefresh }) { delay ->
            enqueue(app, afterWorker, delay)
        }
    }

    internal suspend fun ensure(
        repository: NetworkManager,
        session: RefreshSessionToken? = null,
        enabled: () -> Boolean,
        enqueue: (Long) -> Unit,
    ) {
        withContext(Dispatchers.IO) {
            val expected = session ?: repository.refreshSession() ?: return@withContext
            repository.withRefreshSession(expected) { snapshot ->
                schedulingOperation {
                    if (enabled()) {
                        val remaining = snapshot.nextRefreshAt - System.currentTimeMillis()
                        val delay = (if (remaining > 0) remaining else PortalConfiguration.randomRefreshDelay())
                            .coerceAtLeast(TimeUnit.MINUTES.toMillis(15))
                        enqueue(delay)
                    }
                }
            }
        }
    }

    private fun enqueue(app: SmartTableApplication, afterWorker: Boolean, delay: Long) {
        val request =
            OneTimeWorkRequestBuilder<PortalRefreshWorker>()
                .setInitialDelay(delay, TimeUnit.MILLISECONDS)
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
                )
                .build()
        WorkManager.getInstance(app)
            .enqueueUniqueWork(
                NAME,
                if (afterWorker) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.KEEP,
                request,
            )
    }

    internal suspend fun runRefreshCycle(refresh: suspend () -> Unit, reschedule: suspend () -> Unit) {
        try {
            refresh()
        } catch (_: PortalRequestCancelled) {
            // Opening a browser defers HTTP refresh. Keep the next scheduled cycle alive;
            // cancelling the WorkManager job itself must still propagate below.
        }
        currentCoroutineContext().ensureActive()
        reschedule()
    }

    internal suspend fun runForegroundLoop(
        refresh: suspend () -> Unit,
        pause: suspend () -> Unit = { delay(60_000) },
    ) {
        while (currentCoroutineContext().isActive) runRefreshCycle(refresh, pause)
    }

    internal suspend fun schedulingOperation(action: () -> Unit) = withContext(Dispatchers.IO) {
        val caller = currentCoroutineContext()
        synchronized(schedulingLock) {
            caller.ensureActive()
            action()
        }
    }

    suspend fun cancel(context: Context) = schedulingOperation {
        WorkManager.getInstance(context).cancelUniqueWork(NAME)
        WorkManager.getInstance(context).cancelUniqueWork(KEEP_ALIVE)
        Unit
    }

    internal suspend fun cancelIfDisabled(enabled: () -> Boolean, cancel: () -> Unit) = schedulingOperation {
        // UI callbacks may reach IO out of order. The latest setting always wins.
        if (!enabled()) cancel()
    }

    suspend fun cancelIfDisabled(context: Context) {
        val app = context.applicationContext as SmartTableApplication
        cancelIfDisabled({ app.preferences.state.value.autoRefresh }) {
            WorkManager.getInstance(app).cancelUniqueWork(NAME)
        }
    }

}

class PortalRefreshWorker(context: Context, parameters: WorkerParameters) :
    CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val app = applicationContext as SmartTableApplication
        val repo = app.repository
        repo.prepare()
        if (!app.preferences.state.value.autoRefresh || repo.state.value.snapshot.profile == null)
            return Result.success()
        val session = repo.refreshSession() ?: return Result.success()
        RefreshScheduler.runRefreshCycle({ repo.refresh() }) {
            RefreshScheduler.ensure(applicationContext, true, session)
        }
        return Result.success()
    }

}

/** Light session touch between full refreshes; does nothing without an account. */
class SessionKeepAliveWorker(context: Context, parameters: WorkerParameters) :
    CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val repo = (applicationContext as SmartTableApplication).repository
        repo.prepare()
        if (repo.state.value.snapshot.profile == null) return Result.success()
        repo.keepAliveIfNeeded()
        return Result.success()
    }
}
