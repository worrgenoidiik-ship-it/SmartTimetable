package com.anton.smartulsu.core

import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/** Single-flight callback acknowledgement. Called serially on the main dispatcher.
 * A timeout ends the wait, not the native deletion. Keep its acknowledgement until
 * it arrives: otherwise old deletion could erase a subsequently created session.
 */
internal class CookieRemovalAwaiter(private val timeoutMillis: Long = 5_000L) {
    private var pending: CompletableDeferred<Unit>? = null

    suspend fun awaitRemoval(start: (() -> Unit) -> Unit) {
        val confirmed = withTimeoutOrNull(timeoutMillis) {
            val completion = pending ?: CompletableDeferred<Unit>().also { operation ->
                pending = operation
                start { operation.complete(Unit) }
            }
            completion.await()
            pending = null
            true
        }
        if (confirmed != true)
            throw IOException("Удаление сессии пока не подтверждено.")
    }
}
