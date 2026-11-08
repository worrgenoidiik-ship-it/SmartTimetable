package com.anton.smartulsu.core

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class NoteSaveStatus { PENDING, SAVED, FAILED }
data class NoteDraft(
    val account: String,
    val text: String,
    val status: NoteSaveStatus,
    internal val generation: Long,
    internal val revision: Long,
)

/** Repository-owned drafts outlive screens; only the current account/revision can acknowledge a save. */
internal class NoteDrafts(
    private val scope: CoroutineScope,
    private val debounceMillis: Long = 400,
    private val write: suspend (NoteDraft) -> Unit,
) {
    private val lock = Any()
    private var session: RefreshSessionToken? = null
    private var revision = 0L
    private var job: Job? = null
    private var saveNow = CompletableDeferred<Unit>()
    private val mutable = MutableStateFlow<NoteDraft?>(null)
    val state = mutable.asStateFlow()

    fun activate(next: RefreshSessionToken?) = synchronized(lock) {
        if (next != session) {
            job?.cancel()
            session = next
            mutable.value = null
        }
    }

    fun edit(text: String, account: String): Boolean = synchronized(lock) {
        val owner = session?.takeIf { it.account == account } ?: return@synchronized false
        job?.cancel()
        val draft = NoteDraft(account, text, NoteSaveStatus.PENDING, owner.generation, ++revision)
        mutable.value = draft
        start(draft)
        true
    }

    fun isCurrent(draft: NoteDraft): Boolean = synchronized(lock) {
        mutable.value?.let { it.revision == draft.revision && it.generation == draft.generation &&
            it.account == draft.account } == true
    }

    fun flush(): Job? = synchronized(lock) {
        val draft = mutable.value ?: return@synchronized null
        if (draft.status == NoteSaveStatus.SAVED) return@synchronized job
        if (draft.status == NoteSaveStatus.FAILED || job?.isActive != true) {
            job?.cancel()
            mutable.value = draft.copy(status = NoteSaveStatus.PENDING)
            start(draft)
        }
        saveNow.complete(Unit)
        job
    }

    private fun start(draft: NoteDraft) {
        val signal = CompletableDeferred<Unit>()
        saveNow = signal
        job = scope.launch(start = CoroutineStart.LAZY) {
            withTimeoutOrNull(debounceMillis) { signal.await() }
            val result = try {
                write(draft)
                NoteSaveStatus.SAVED
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                NoteSaveStatus.FAILED
            }
            synchronized(lock) {
                if (isCurrent(draft)) mutable.value = draft.copy(status = result)
            }
        }.also { it.start() }
    }
}
