package com.anton.smartulsu.core

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class BrowserLeaseLifecycleTest {
    @Test fun cancellationBeforeAcquireNeverTakesLease() = runBlocking {
        var acquired = false
        val job = launch {
            withBrowserLease({ acquired = true }, { fail("No lease to release") }, {})
        }
        job.cancelAndJoin()
        assertFalse(acquired)
    }

    @Test fun cancellationWhileWaitingForAcquireNeverReleasesAnotherLease() = runBlocking {
        val job = launch(start = CoroutineStart.UNDISPATCHED) {
            withBrowserLease({ awaitCancellation() }, { fail("Not acquired") }, {})
        }
        job.cancelAndJoin()
    }

    @Test fun cancellationImmediatelyAfterAcquireReleasesBeforeUse() = runBlocking {
        var released = 0
        val job = launch(start = CoroutineStart.UNDISPATCHED) {
            withBrowserLease({ currentCoroutineContext().cancel(); 42 }, {
                assertEquals(42, it)
                yield() // Cleanup must be allowed to suspend after cancellation.
                released++
            }, { fail("Cancelled lease must not initialize a browser") })
        }
        job.join()
        assertEquals(1, released)
    }

    @Test fun normalCompletionAndInitializationFailureBothRelease() = runBlocking {
        var releases = 0
        withBrowserLease({ 1 }, { releases++ }, {})
        try {
            withBrowserLease({ 2 }, { releases++ }, { error("Synthetic init failure") })
            fail()
        } catch (_: IllegalStateException) { }
        assertEquals(2, releases)
    }

    @Test fun repeatedCloseAndRapidReopenReleaseEachLeaseExactlyOnce() = runBlocking {
        var held = false
        var releases = 0
        repeat(100) {
            val job = launch(start = CoroutineStart.UNDISPATCHED) {
                withBrowserLease({ assertFalse(held); held = true; it }, {
                    yield()
                    held = false
                    releases++
                }, { awaitCancellation() })
            }
            job.cancel()
            job.cancelAndJoin()
            assertFalse(held)
        }
        assertEquals(100, releases)
    }
}
