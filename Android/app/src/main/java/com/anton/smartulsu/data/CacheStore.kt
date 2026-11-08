package com.anton.smartulsu.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.core.util.AtomicFile
import java.io.FileOutputStream
import java.io.IOException
import com.anton.smartulsu.core.PortalSnapshot
import com.anton.smartulsu.core.PortalParser
import com.google.gson.Gson
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Called only on IO; AES-GCM + Android Keystore; atomic writes, excluded from backup. */
class CacheStore internal constructor(
    context: Context,
    private val syncData: (FileOutputStream) -> Unit = { it.fd.sync() },
    private val finishWrite: (AtomicFile, FileOutputStream) -> Unit = { file, stream -> file.finishWrite(stream) },
) {
    private val file = AtomicFile(File(context.noBackupFilesDir, "portal-v1.enc"))
    private val alias = "smarttable.cache.v1"
    private val gson = Gson()

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let {
            return it
        }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            .apply {
                init(
                    KeyGenParameterSpec.Builder(
                            alias,
                            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                        )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .build()
                )
            }
            .generateKey()
    }

    @Synchronized
    fun load(): PortalSnapshot {
        recoverLegacyBackup()
        val bytes = try {
            file.openRead().use { it.readBytes() }
        } catch (e: java.io.FileNotFoundException) {
            val backup = File(file.baseFile.path + ".bak")
            if (existsChecked(file.baseFile) || existsChecked(backup)) throw e
            return PortalSnapshot()
        }
        require(bytes.size > 30 && bytes[0] == 1.toByte())
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
        return gson
            .fromJson(
                String(c.doFinal(bytes.copyOfRange(13, bytes.size)), Charsets.UTF_8),
                PortalSnapshot::class.java,
            )
            .also { require(it.schemaVersion == 1) }
            .let { snapshot ->
                snapshot.copy(notifications = snapshot.notifications?.let { section ->
                    section.copy(value = PortalParser.mergeNotifications(emptyList(), section.value))
                })
            }
    }

    @Synchronized
    fun save(snapshot: PortalSnapshot) {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val bytes =
            byteArrayOf(1) + c.iv + c.doFinal(gson.toJson(snapshot).toByteArray(Charsets.UTF_8))
        recoverLegacyBackup()
        val stream = file.startWrite()
        try {
            stream.write(bytes)
            // AtomicFile logs some errors instead of throwing. Sync explicitly before
            // replacement, then verify that this exact inode became the committed file.
            syncData(stream)
            val written = android.system.Os.fstat(stream.fd)
            finishWrite(file, stream)
            val committed = android.system.Os.stat(file.baseFile.path)
            if (committed.st_dev != written.st_dev || committed.st_ino != written.st_ino ||
                committed.st_size != bytes.size.toLong() ||
                existsChecked(File(file.baseFile.path + ".new")))
                throw IOException("Encrypted cache commit was not confirmed.")
            syncDirectory()
        } catch (e: Exception) {
            file.failWrite(stream) // AndroidX removes only .new; the committed file is preserved.
            throw e
        }
    }

    private fun recoverLegacyBackup() {
        val backup = File(file.baseFile.path + ".bak")
        if (existsChecked(backup)) {
            // Do not let a silently failed AtomicFile recovery hide or overwrite a good backup.
            android.system.Os.rename(backup.path, file.baseFile.path)
            syncDirectory()
        }
    }

    private val logoutMarker = File(context.noBackupFilesDir, "logout.pending")

    private fun existsChecked(target: File): Boolean =
        try {
            android.system.Os.lstat(target.path)
            true
        } catch (e: android.system.ErrnoException) {
            if (e.errno == android.system.OsConstants.ENOENT) false
            else throw java.io.IOException("Cannot inspect local storage.", e)
        }

    @Synchronized
    fun hasPendingLogout(): Boolean = existsChecked(logoutMarker)

    @Synchronized
    fun beginLogout() {
        java.io.FileOutputStream(logoutMarker).use {
            it.write(1)
            it.fd.sync()
        }
        syncDirectory()
        check(hasPendingLogout()) { "Logout marker was not persisted." }
    }

    private fun syncDirectory() {
        val fd = android.system.Os.open(logoutMarker.parentFile!!.path,
            android.system.OsConstants.O_RDONLY, 0)
        try { android.system.Os.fsync(fd) } finally { android.system.Os.close(fd) }
    }

    @Synchronized
    fun finishLogout() {
        if (!logoutMarker.delete() && existsChecked(logoutMarker))
            throw java.io.IOException("Cannot remove the logout marker.")
        syncDirectory()
    }

    @Synchronized
    fun clear() {
        file.delete()
        val remaining = listOf(
            file.baseFile,
            File(file.baseFile.path + ".bak"),
            File(file.baseFile.path + ".new"),
        ).any { existsChecked(it) }
        if (remaining)
            throw java.io.IOException("Encrypted cache files remain.")
    }
}
