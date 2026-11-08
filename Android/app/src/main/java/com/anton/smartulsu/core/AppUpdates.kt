package com.anton.smartulsu.core

import com.google.gson.JsonArray
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/** A new Android build published on GitHub Releases (tag "android-v2.0.2", APK attached). */
data class AppRelease(val version: String, val pageUrl: String, val apkUrl: String?, val notes: String)

/**
 * Update check without our own server: the public GitHub repository's releases. Only reads
 * public JSON; nothing about the user is sent. The APK is opened in the browser, Android
 * installs it over the current version because both are signed with the same release key.
 */
object AppUpdates {
    const val REPOSITORY = "worrgenoidiik-ship-it/SmartUlSU-ios"
    const val TAG_PREFIX = "android-v"
    const val RELEASES_PAGE = "https://github.com/$REPOSITORY/releases"
    private const val API = "https://api.github.com/repos/$REPOSITORY/releases?per_page=30"

    /** The newest published (not draft, not pre-release) Android release in the API answer. */
    fun latest(json: String): AppRelease? {
        val array = runCatching { JsonParser.parseString(json) }.getOrNull()
            ?.takeIf { it.isJsonArray }?.asJsonArray ?: return null
        return releases(array).maxWithOrNull { a, b -> compare(a.version, b.version) }
    }

    private fun JsonObject.text(name: String): String? =
        get(name)?.takeIf { it.isJsonPrimitive }?.asString

    private fun JsonObject.flag(name: String): Boolean =
        get(name)?.takeIf { it.isJsonPrimitive }?.asBoolean == true

    private fun releases(array: JsonArray): List<AppRelease> = array.mapNotNull { element ->
        val item = element.takeIf { it.isJsonObject }?.asJsonObject ?: return@mapNotNull null
        val tag = item.text("tag_name") ?: return@mapNotNull null
        if (!tag.startsWith(TAG_PREFIX) || item.flag("draft") || item.flag("prerelease")) return@mapNotNull null
        val version = tag.removePrefix(TAG_PREFIX)
        if (parts(version).isEmpty()) return@mapNotNull null
        val page = item.text("html_url")?.takeIf { isGitHub(it) } ?: RELEASES_PAGE
        val assets = item.get("assets")?.takeIf { it.isJsonArray }?.asJsonArray
        val apk = assets?.mapNotNull { asset -> asset.takeIf { it.isJsonObject }?.asJsonObject?.text("browser_download_url") }
            ?.firstOrNull { it.endsWith(".apk") && isGitHub(it) }
        AppRelease(version, page, apk, item.text("body").orEmpty().take(600))
    }

    /** True when [candidate] is a later version than [current] ("2.0.10" > "2.0.9"). */
    fun isNewer(candidate: String, current: String): Boolean = compare(candidate, current) > 0

    private fun compare(a: String, b: String): Int {
        val x = parts(a)
        val y = parts(b)
        for (i in 0 until maxOf(x.size, y.size)) {
            val diff = (x.getOrElse(i) { 0 }).compareTo(y.getOrElse(i) { 0 })
            if (diff != 0) return diff
        }
        return 0
    }

    private fun parts(version: String): List<Int> =
        version.trim().split('.').map { it.toIntOrNull() ?: return emptyList() }

    private fun isGitHub(url: String): Boolean = url.startsWith("https://github.com/")

    /** One request; any failure (offline, repository private, rate limit) is just "no update". */
    suspend fun fetchLatest(): AppRelease? = withContext(Dispatchers.IO) {
        runCatching {
            val connection = URL(API).openConnection() as HttpURLConnection
            connection.connectTimeout = 10_000
            connection.readTimeout = 10_000
            connection.setRequestProperty("Accept", "application/vnd.github+json")
            connection.setRequestProperty("User-Agent", "SmartTimetable-Android")
            try {
                if (connection.responseCode != 200) return@runCatching null
                latest(connection.inputStream.bufferedReader().use { it.readText().take(2_000_000) })
            } finally {
                connection.disconnect()
            }
        }.getOrNull()
    }
}
