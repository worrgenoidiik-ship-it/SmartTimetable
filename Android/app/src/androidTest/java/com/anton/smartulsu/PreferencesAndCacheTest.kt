package com.anton.smartulsu

import android.content.Context
import android.content.ContextWrapper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.anton.smartulsu.core.PortalSnapshot
import com.anton.smartulsu.core.StudentProfile
import com.anton.smartulsu.core.CachedSection
import com.anton.smartulsu.core.PortalNotification
import com.anton.smartulsu.data.CacheStore
import java.io.IOException
import java.io.File
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PreferencesAndCacheTest {
    // Only synthetic data in unique test-owned directories/preferences; no real account files.
    private fun context(): Context {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val id = "regression-${UUID.randomUUID()}"
        val directory = File(base.cacheDir, id).apply { mkdirs() }
        return object : ContextWrapper(base) {
            override fun getNoBackupFilesDir() = directory
            override fun getSharedPreferences(name: String, mode: Int) =
                base.getSharedPreferences("$id-$name", mode)
        }
    }

    @Test fun newInstallationDefaultsToEios() {
        assertTrue(UiPreferences().portalSchedule)
        assertTrue(AppPreferences(context()).state.value.portalSchedule)
    }

    @Test fun explicitlySavedManualPreferenceSurvivesRecreation() {
        val context = context()
        context.getSharedPreferences("appearance", Context.MODE_PRIVATE).edit()
            .putBoolean("portalSchedule", false).commit()
        val preferences = AppPreferences(context)
        assertFalse(preferences.state.value.portalSchedule)
        preferences.update { it.copy(dark = !it.dark) }
        assertFalse(AppPreferences(context).state.value.portalSchedule)
    }

    @Test fun explicitlySavedEiosPreferenceSurvivesRecreation() {
        val context = context()
        context.getSharedPreferences("appearance", Context.MODE_PRIVATE).edit()
            .putBoolean("portalSchedule", true).commit()
        assertTrue(AppPreferences(context).state.value.portalSchedule)
    }

    @Test fun encryptedSnapshotSurvivesRepositoryStorageRecreation() {
        val context = context()
        val snapshot = PortalSnapshot(profile = StudentProfile("synthetic", "Test"), notes = "Test note", profilePhoto = "synthetic-photo")
        CacheStore(context).save(snapshot)
        assertEquals(snapshot, CacheStore(context).load())
        assertFalse(File(context.noBackupFilesDir, "portal-v1.enc").readBytes().toString(Charsets.ISO_8859_1).contains("Test note"))
    }

    @Test fun backupOnlySnapshotIsRecovered() {
        val context = context()
        val snapshot = PortalSnapshot(notes = "Backup note")
        val store = CacheStore(context)
        store.save(snapshot)
        val base = File(context.noBackupFilesDir, "portal-v1.enc")
        assertTrue(base.renameTo(File(base.path + ".bak")))
        assertEquals(snapshot, store.load())
    }

    @Test fun corruptCiphertextIsRejectedWithoutDeletingIt() {
        val context = context()
        val store = CacheStore(context)
        store.save(PortalSnapshot(notes = "Do not silently erase"))
        val base = File(context.noBackupFilesDir, "portal-v1.enc")
        val bytes = base.readBytes()
        bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
        base.writeBytes(bytes)
        assertThrows(Exception::class.java) { store.load() }
        assertTrue(base.exists())
    }

    @Test fun pendingLogoutSurvivesRecreationAndIsSeparateFromCacheDeletion() {
        val context = context()
        val store = CacheStore(context)
        store.save(PortalSnapshot(notes = "Synthetic"))
        store.beginLogout()
        assertTrue(CacheStore(context).hasPendingLogout())
        store.clear()
        assertTrue(store.hasPendingLogout())
        for (suffix in listOf("", ".bak", ".new")) assertFalse(File(context.noBackupFilesDir, "portal-v1.enc$suffix").exists())
        store.finishLogout()
        assertFalse(CacheStore(context).hasPendingLogout())
    }
    @Test fun legacyUnboundedCacheLoadsOfflineWithItsHighestIdAndOtherDataIntact() {
        val context = context()
        val snapshot = PortalSnapshot(profile = StudentProfile("synthetic", "Test"), notes = "Keep",
            notifications = CachedSection((1..2000).map { PortalNotification(it.toString(), "Test", "", true) }))
        val store = CacheStore(context)
        store.save(snapshot)
        val restored = CacheStore(context).load()
        assertEquals(snapshot.profile, restored.profile)
        assertEquals(snapshot.notes, restored.notes)
        assertEquals(500, restored.notifications!!.value.size)
        assertEquals("2000", restored.notifications.value.first().id)
        assertEquals(snapshot.notifications!!.fetchedAt, restored.notifications.fetchedAt)
        store.save(restored)
        assertEquals(restored, CacheStore(context).load())
    }

    @Test fun syncFailureBeforeCommitPreservesPreviousEncryptedSnapshot() {
        val context = context()
        val original = PortalSnapshot(notes = "Last good")
        CacheStore(context).save(original)
        val failing = CacheStore(context, syncData = { throw IOException("Synthetic sync failure") })
        assertThrows(IOException::class.java) { failing.save(original.copy(notes = "Not saved")) }
        assertEquals(original, CacheStore(context).load())
    }

    @Test fun silentlyUncommittedWriteIsDetectedAndPreviousSnapshotSurvives() {
        val context = context()
        val original = PortalSnapshot(notes = "Last good")
        CacheStore(context).save(original)
        val failing = CacheStore(context, finishWrite = { _, stream -> stream.close() })
        assertThrows(IOException::class.java) { failing.save(original.copy(notes = "Not committed")) }
        assertEquals(original, CacheStore(context).load())
        assertFalse(File(context.noBackupFilesDir, "portal-v1.enc.new").exists())
    }

    @Test fun thrownFinalizationFailurePreservesPreviousSnapshot() {
        val context = context()
        val original = PortalSnapshot(notes = "Last good")
        CacheStore(context).save(original)
        val failing = CacheStore(context, finishWrite = { _, _ -> throw IOException("Synthetic rename failure") })
        assertThrows(IOException::class.java) { failing.save(original.copy(notes = "New")) }
        assertEquals(original, CacheStore(context).load())
    }

    @Test fun interruptedReplacementRecoversOldSnapshotAndIgnoresIncompleteFirstWrite() {
        val context = context()
        val original = PortalSnapshot(notes = "Last good")
        CacheStore(context).save(original)
        File(context.noBackupFilesDir, "portal-v1.enc.new").writeBytes(byteArrayOf(1, 2, 3))
        assertEquals(original, CacheStore(context).load())
        val first = context()
        File(first.noBackupFilesDir, "portal-v1.enc.new").writeBytes(byteArrayOf(1, 2, 3))
        assertEquals(PortalSnapshot(), CacheStore(first).load())
    }

    @Test fun failedLegacyRecoveryCannotOverwriteLastGoodBackup() {
        val context = context()
        val store = CacheStore(context)
        store.save(PortalSnapshot(notes = "Last good backup"))
        val base = File(context.noBackupFilesDir, "portal-v1.enc")
        val backup = File(base.path + ".bak")
        assertTrue(base.renameTo(backup))
        val encrypted = backup.readBytes()
        assertTrue(base.mkdir())
        val obstruction = File(base, "synthetic").apply { writeText("test") }
        assertThrows(Exception::class.java) { store.load() }
        assertThrows(Exception::class.java) { store.save(PortalSnapshot(notes = "Must not overwrite")) }
        assertArrayEquals(encrypted, backup.readBytes())
        assertTrue(obstruction.delete())
        assertTrue(base.delete())
        assertEquals("Last good backup", store.load().notes)
    }

}
