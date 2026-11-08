package com.anton.smartulsu.core

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Acquisition must return in its caller's context, with no suspension after taking the lease. */
internal suspend fun <T> withBrowserLease(
    acquire: suspend () -> T,
    release: suspend (T) -> Unit,
    use: suspend (T) -> Unit,
) {
    currentCoroutineContext().ensureActive()
    val lease = acquire()
    try {
        currentCoroutineContext().ensureActive()
        use(lease)
    } finally {
        // Only resource cleanup survives screen/caller cancellation.
        withContext(NonCancellable) { release(lease) }
    }
}
