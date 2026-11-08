package com.anton.smartulsu.core

import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.junit.Assert.*
import org.junit.Test

class NoteDraftsTest {
    private val account = RefreshSessionToken("A", 1)

    @Test fun reopenedEditorKeepsPendingTextDespiteUnrelatedSnapshotUpdates() = runBlocking {
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val release = CompletableDeferred<Unit>()
        var persisted = "old"
        val drafts = NoteDrafts(owner, 60_000) { release.await(); persisted = it.text }
        try {
            drafts.activate(account)
            drafts.edit("latest", "A")
            drafts.flush() // Screen disposal requests persistence, but does not own/cancel it.
            val snapshot = PortalSnapshot(notes = "old").copy(nextRefreshAt = 999)
            assertEquals("latest", drafts.state.value?.text ?: snapshot.notes)
            assertEquals(NoteSaveStatus.PENDING, drafts.state.value!!.status)
            release.complete(Unit)
            drafts.flush()!!.join()
            assertEquals("latest", persisted)
            assertEquals(NoteSaveStatus.SAVED, drafts.state.value!!.status)
        } finally { owner.cancel() }
    }

    @Test fun burstWithinDebouncePersistsOnlyLatestEdit() = runBlocking {
        val writes = mutableListOf<String>()
        val drafts = NoteDrafts(this, 60_000) { writes += it.text }
        drafts.activate(account)
        repeat(50) { drafts.edit("edit-$it", "A") }
        assertTrue(writes.isEmpty())
        drafts.flush()!!.join()
        assertEquals(listOf("edit-49"), writes)
    }

    @Test fun cancellingNavigationWaitDoesNotCancelOwnedSave() = runBlocking {
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val drafts = NoteDrafts(owner, 60_000) { started.complete(Unit); release.await() }
        try {
            drafts.activate(account)
            drafts.edit("keep", "A")
            val waiter = launch { drafts.flush()!!.join() }
            started.await()
            waiter.cancelAndJoin()
            assertEquals(NoteSaveStatus.PENDING, drafts.state.value!!.status)
            release.complete(Unit)
            drafts.flush()!!.join()
            assertEquals(NoteSaveStatus.SAVED, drafts.state.value!!.status)
        } finally { owner.cancel() }
    }

    @Test fun cancelledOlderSaveCannotOverwriteOrAcknowledgeNewDraft() = runBlocking {
        val gate = Mutex(locked = true)
        val writes = mutableListOf<String>()
        lateinit var drafts: NoteDrafts
        drafts = NoteDrafts(this, 60_000) { draft ->
            gate.withLock {
                currentCoroutineContext().ensureActive()
                if (drafts.isCurrent(draft)) writes += draft.text
            }
        }
        drafts.activate(account)
        drafts.edit("old pending", "A")
        drafts.flush()
        yield()
        drafts.edit("new pending", "A")
        drafts.flush()
        gate.unlock()
        drafts.flush()!!.join()
        assertEquals(listOf("new pending"), writes)
        assertEquals("new pending", drafts.state.value!!.text)
        assertEquals(NoteSaveStatus.SAVED, drafts.state.value!!.status)
    }

    @Test fun accountSwitchAndLogoutDiscardPendingEditsIncludingSameAccountNewSession() = runBlocking {
        val writes = mutableListOf<String>()
        val drafts = NoteDrafts(this, 60_000) { writes += it.text }
        for (next in listOf(null, RefreshSessionToken("B", 2), RefreshSessionToken("A", 3))) {
            drafts.activate(account)
            drafts.edit("must not cross session", "A")
            drafts.activate(next)
            assertNull(drafts.state.value)
            assertNull(drafts.flush())
        }
        yield()
        assertTrue(writes.isEmpty())
        drafts.activate(RefreshSessionToken("B", 4))
        assertFalse(drafts.edit("wrong account", "A"))
        assertTrue(drafts.edit("B note", "B"))
        drafts.flush()!!.join()
        assertEquals(listOf("B note"), writes)
    }

    @Test fun failedSaveRetainsDraftAndRetryCanAcknowledgeIt() = runBlocking {
        var fail = true
        val drafts = NoteDrafts(this, 60_000) { if (fail) throw IOException("synthetic") }
        drafts.activate(account)
        drafts.edit("retain", "A")
        drafts.flush()!!.join()
        assertEquals("retain", drafts.state.value!!.text)
        assertEquals(NoteSaveStatus.FAILED, drafts.state.value!!.status)
        fail = false
        drafts.flush()!!.join()
        assertEquals(NoteSaveStatus.SAVED, drafts.state.value!!.status)
    }

    @Test fun sameSessionActivationDoesNotReplaceLiveEditorWithPersistedText() = runBlocking {
        val drafts = NoteDrafts(this, 60_000) {}
        drafts.activate(account)
        drafts.edit("live", "A")
        drafts.activate(account.copy())
        assertEquals("live", drafts.state.value!!.text)
        drafts.flush()!!.join()
    }
}
