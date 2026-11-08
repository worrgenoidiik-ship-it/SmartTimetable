package com.anton.smartulsu.core

import com.anton.smartulsu.RefreshScheduler
import com.anton.smartulsu.data.PortalRequestCancelled
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class RefreshCycleTest {
    @Test fun intentionalBrowserCancellationKeepsNextRefreshWithoutRetryingHttp() = runBlocking {
        var requests = 0
        var schedules = 0
        RefreshScheduler.runRefreshCycle({ requests++; throw PortalRequestCancelled() }, { schedules++ })
        assertEquals(1, requests)
        assertEquals(1, schedules)
    }

    @Test fun cancelledWorkerCannotScheduleEvenWhenHttpWasInvalidated() = runBlocking {
        var scheduled = false
        val job = launch {
            RefreshScheduler.runRefreshCycle({
                currentCoroutineContext().cancel()
                throw PortalRequestCancelled()
            }, { scheduled = true })
        }
        job.join()
        assertTrue(job.isCancelled)
        assertFalse(scheduled)
    }

    @Test fun ordinaryCoroutineCancellationStillPropagates() = runBlocking {
        try {
            RefreshScheduler.runRefreshCycle({ throw CancellationException("Worker stopped") }, { fail() })
            fail("Cancellation must propagate")
        } catch (_: CancellationException) { }
    }

    @Test fun completedRefreshSchedulesExactlyOnce() = runBlocking {
        var completed = false
        var schedules = 0
        RefreshScheduler.runRefreshCycle({ completed = true }, { assertTrue(completed); schedules++ })
        assertEquals(1, schedules)
    }
}
