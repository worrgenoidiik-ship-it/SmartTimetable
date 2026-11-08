package com.anton.smartulsu.core

import com.anton.smartulsu.RefreshScheduler
import com.anton.smartulsu.data.PortalRequestCancelled
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.junit.Assert.*
import org.junit.Test

class RefreshSchedulingRegressionTest {
    @Test fun foregroundLoopContinuesAfterBrowserCancellationAndKeepsInterval() = runBlocking {
        var calls = 0
        var pauses = 0
        val job = launch(start = CoroutineStart.UNDISPATCHED) {
            RefreshScheduler.runForegroundLoop({
                calls++
                if (calls == 1) throw PortalRequestCancelled()
            }, {
                pauses++
                if (pauses == 3) throw CancellationException("End synthetic lifecycle")
                yield()
            })
        }
        job.join()
        assertEquals(3, calls)
        assertEquals(3, pauses)
    }

    @Test fun foregroundLoopDoesNotSwallowLifecycleCancellation() = runBlocking {
        var calls = 0
        val job = launch {
            RefreshScheduler.runForegroundLoop({
                calls++
                throw CancellationException("Lifecycle stopped")
            }, { fail("Cancelled lifecycle must not continue") })
        }
        job.join()
        assertTrue(job.isCancelled)
        assertEquals(1, calls)
    }

    @Test fun cacheReplacementWhileSchedulingWaitsStillUsesLatestSnapshot() = runBlocking {
        val gate = Mutex(locked = true)
        val session = RefreshSessionToken("account", 7)
        var snapshot = PortalSnapshot(profile = StudentProfile("account", "Test"), nextRefreshAt = 10)
        var scheduled: PortalSnapshot? = null
        val job = launch(start = CoroutineStart.UNDISPATCHED) {
            withRefreshSessionGuard(gate, session, { session }) { scheduled = snapshot }
        }
        snapshot = snapshot.copy(notes = "Unrelated save", nextRefreshAt = 20)
        gate.unlock()
        job.join()
        assertSame(snapshot, scheduled)
        assertEquals(20L, scheduled!!.nextRefreshAt)
    }

    @Test fun logoutAccountReplacementAndSameAccountNewSessionRejectWaitingWork() = runBlocking {
        val old = RefreshSessionToken("account", 7)
        for (replacement in listOf(null, RefreshSessionToken("other", 7), RefreshSessionToken("account", 8))) {
            val gate = Mutex(locked = true)
            var current: RefreshSessionToken? = old
            var scheduled = false
            val job = launch(start = CoroutineStart.UNDISPATCHED) {
                withRefreshSessionGuard(gate, old, { current }) { scheduled = true }
            }
            current = replacement
            gate.unlock()
            job.join()
            assertFalse("Invalidated account/session must not schedule", scheduled)
        }
    }

    @Test fun schedulingActionStaysInsideRepositoryGateAndCancelledWaiterCannotRun() = runBlocking {
        val gate = Mutex()
        val token = RefreshSessionToken("account", 1)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val scheduling = launch(start = CoroutineStart.UNDISPATCHED) {
            withRefreshSessionGuard(gate, token, { token }) {
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()
        var logoutEntered = false
        val logout = launch(start = CoroutineStart.UNDISPATCHED) {
            gate.withLock { logoutEntered = true }
        }
        val cancelled = launch(start = CoroutineStart.UNDISPATCHED) {
            withRefreshSessionGuard(gate, token, { token }) { fail("Cancelled worker") }
        }
        cancelled.cancelAndJoin()
        assertFalse(logoutEntered)
        release.complete(Unit)
        scheduling.join()
        logout.join()
        assertTrue(logoutEntered)
    }

    @Test fun contendedSchedulingDoesNotBlockUiAndLatestToggleWins() = runBlocking {
        Executors.newSingleThreadExecutor().asCoroutineDispatcher().use { ui ->
            for (lastEnabled in listOf(true, false)) {
                val entered = CompletableDeferred<Unit>()
                val release = CountDownLatch(1)
                val holder = launch {
                    RefreshScheduler.schedulingOperation {
                        entered.complete(Unit)
                        check(release.await(5, TimeUnit.SECONDS))
                    }
                }
                entered.await()
                val enabled = AtomicBoolean(false)
                val scheduled = AtomicBoolean(true)
                val disable = launch(ui) {
                    RefreshScheduler.cancelIfDisabled(enabled::get) { scheduled.set(false) }
                }
                val enable = launch(ui) {
                    RefreshScheduler.schedulingOperation { if (enabled.get()) scheduled.set(true) }
                }
                try {
                    // Both scheduler calls must yield the UI executor even while the lock is held.
                    withTimeout(2_000) { withContext(ui) { enabled.set(lastEnabled) } }
                } finally { release.countDown() }
                joinAll(holder, disable, enable)
                assertEquals(lastEnabled, scheduled.get())
            }
        }
    }
}
