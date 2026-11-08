package com.anton.smartulsu.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.google.gson.Gson
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Optional saved login, used only to sign in again after the portal ends the session.
 * AES-GCM with an Android Keystore key (same scheme as [CacheStore]), stored in
 * noBackupFilesDir. Deleted on logout. The MAX code is never stored.
 */
class CredentialStore(context: Context) {
    data class Credentials(val username: String, val password: String)

    private val file = File(context.noBackupFilesDir, "login-v1.enc")
    private val preferences = context.getSharedPreferences("session", Context.MODE_PRIVATE)
    private val alias = "smarttable.login.v1"
    private val gson = Gson()

    /** The user's choice on the login screen; on by default. */
    var enabled: Boolean
        get() = preferences.getBoolean("rememberLogin", true)
        set(value) {
            preferences.edit().putBoolean("rememberLogin", value).apply()
            if (!value) delete()
        }

    val hasCredentials: Boolean get() = file.exists()

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(
                KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build()
            )
        }.generateKey()
    }

    @Synchronized
    fun load(): Credentials? = runCatching {
        if (!file.exists()) return null
        val bytes = file.readBytes()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        gson.fromJson(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8), Credentials::class.java)
            ?.takeIf { !it.username.isNullOrBlank() && !it.password.isNullOrEmpty() }
    }.getOrNull()

    @Synchronized
    fun save(credentials: Credentials) {
        if (!enabled) return
        runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key())
            val sealed = cipher.iv + cipher.doFinal(gson.toJson(credentials).toByteArray(Charsets.UTF_8))
            val temp = File(file.parentFile, file.name + ".tmp")
            temp.writeBytes(sealed)
            if (!temp.renameTo(file)) { file.delete(); temp.renameTo(file) }
        }
    }

    @Synchronized
    fun delete() {
        file.delete()
    }
}
