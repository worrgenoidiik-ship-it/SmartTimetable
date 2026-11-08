package com.anton.smartulsu.core

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Cache writes and browser leases do not change the account session. Logout/replacement do. */
internal data class RefreshSessionToken(val account: String, val generation: Long)

internal suspend fun withRefreshSessionGuard(
    gate: Mutex,
    expected: RefreshSessionToken,
    current: () -> RefreshSessionToken?,
    action: suspend () -> Unit,
) {
    gate.withLock {
        currentCoroutineContext().ensureActive()
        if (current() == expected) action()
    }
}
