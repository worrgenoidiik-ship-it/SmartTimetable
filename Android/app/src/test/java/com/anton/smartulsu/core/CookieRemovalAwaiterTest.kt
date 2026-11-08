package com.anton.smartulsu.core

import java.io.IOException
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class CookieRemovalAwaiterTest {
    @Test fun acknowledgedRemovalCompletes() = runBlocking {
        CookieRemovalAwaiter(50).awaitRemoval { complete -> complete() }
    }

    @Test fun missingCallbackBoundsEachWaitWithoutOverlappingNativeRemoval() = runBlocking {
        val remover = CookieRemovalAwaiter(20)
        var calls = 0
        repeat(2) {
            try {
                remover.awaitRemoval { calls++ }
                fail("An unacknowledged removal must not succeed")
            } catch (_: IOException) { }
        }
        assertEquals(1, calls)
    }

    @Test fun lateCallbackAllowsRetryInTheSameProcess() = runBlocking {
        val remover = CookieRemovalAwaiter(20)
        var complete: (() -> Unit)? = null
        try { remover.awaitRemoval { complete = it }; fail() } catch (_: IOException) { }
        complete!!()
        remover.awaitRemoval { fail("Must acknowledge the existing operation") }
    }

    @Test fun cancelledCallerDoesNotCancelNativeAcknowledgement() = runBlocking {
        val remover = CookieRemovalAwaiter(1000)
        var complete: (() -> Unit)? = null
        val job = launch(start = CoroutineStart.UNDISPATCHED) { remover.awaitRemoval { complete = it } }
        job.cancelAndJoin()
        assertTrue(job.isCancelled)
        complete!!()
        remover.awaitRemoval { fail("Must not start overlapping cleanup") }
    }

    @Test fun oldCallbackCannotCompleteAnotherCleanup() = runBlocking {
        val remover = CookieRemovalAwaiter(20)
        var old: (() -> Unit)? = null
        remover.awaitRemoval { old = it; it() }
        try {
            remover.awaitRemoval { old!!() }
            fail("Old acknowledgement must not complete the new operation")
        } catch (_: IOException) { }
    }
}
