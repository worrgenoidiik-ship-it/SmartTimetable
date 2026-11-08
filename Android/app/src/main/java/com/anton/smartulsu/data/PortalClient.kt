package com.anton.smartulsu.data

import android.webkit.CookieManager
import com.anton.smartulsu.core.*
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.CancellationException
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody

/** Request invalidation is separate from cancellation of the caller/WorkManager job. */
internal class PortalRequestCancelled(cause: IOException? = null) :
    CancellationException("Portal requests cancelled") {
    init { if (cause != null) initCause(cause) }
}

data class PortalPage(val html: String, val url: String)

class PortalClient internal constructor(
    private val cookies: CookieManager,
    userAgent: String,
    transport: Interceptor? = null,
) {
    private val cookieLock = Any()
    private var generation = 0L

    private data class Generation(val value: Long)

    private val client =
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(25, TimeUnit.SECONDS)
            .callTimeout(35, TimeUnit.SECONDS)
            .followRedirects(false)
            .followSslRedirects(false)
            .addInterceptor { chain ->
                val req = chain.request()
                val expected = req.tag(Generation::class.java)?.value
                val header =
                    synchronized(cookieLock) {
                        if (expected != generation) throw IOException("Request cancelled")
                        cookies.getCookie(req.url.toString())
                    }
                val builder =
                    req.newBuilder()
                        .header("User-Agent", userAgent)
                        .header("Accept", "text/html,application/json")
                if (!header.isNullOrBlank()) builder.header("Cookie", header)
                val response = chain.proceed(builder.build())
                synchronized(cookieLock) {
                    if (expected == generation) {
                        response.headers("Set-Cookie").forEach {
                            cookies.setCookie(req.url.toString(), it)
                        }
                        cookies.flush()
                    }
                }
                response
            }
            .apply { if (transport != null) addInterceptor(transport) }
            .build()

    fun cancelAll() {
        synchronized(cookieLock) {
            generation++
            client.dispatcher.cancelAll()
        }
    }

    private suspend fun execute(url: String, expected: Long, body: RequestBody? = null): Response =
        suspendCancellableCoroutine { continuation ->
            synchronized(cookieLock) {
                if (expected != generation) {
                    continuation.resumeWithException(PortalRequestCancelled())
                    return@suspendCancellableCoroutine
                }
                val request = Request.Builder().url(url)
                    .tag(Generation::class.java, Generation(expected))
                    .apply { if (body != null) post(body) else get() }
                    .build()
                val call = client.newCall(request)
                continuation.invokeOnCancellation { call.cancel() }
                call.enqueue(
                    object : Callback {
                        override fun onFailure(call: Call, e: IOException) {
                            if (continuation.isActive) continuation.resumeWithException(e)
                        }
    
                        override fun onResponse(call: Call, response: Response) {
                            if (continuation.isActive)
                                continuation.resume(response) { _, value, _ -> value.close() }
                            else response.close()
                        }
                    }
                )
            }
        }

    /**
     * Keep-alive call to Moodle's AJAX service (core_session_touch). Never follows redirects:
     * a redirect or 401 means the session is gone. Never carries credentials.
     */
    suspend fun postJson(url: String, json: String): String {
        val expected = synchronized(cookieLock) { generation }
        try {
            if (!PortalConfiguration.allowsDataURL(url)) throw PortalFailure.UnsafeURL()
            execute(url, expected, json.toRequestBody("application/json".toMediaType())).use { response ->
                if (response.code in 300..399 || response.code == 401) throw PortalFailure.LoginRequired()
                if (!response.isSuccessful) throw PortalFailure.Http(response.code)
                val text = response.body?.string() ?: throw PortalFailure.InvalidResponse()
                if (text.length > 100_000) throw PortalFailure.InvalidResponse()
                checkGeneration(expected)
                return text
            }
        } catch (e: IOException) {
            checkGeneration(expected, e)
            throw e
        }
    }

    /** POST of a portal form (application/x-www-form-urlencoded), sent once, no retry. */
    suspend fun postForm(url: String, fields: List<Pair<String, String>>): PortalPage {
        val expected = synchronized(cookieLock) { generation }
        try {
            if (!PortalConfiguration.allowsDataURL(url)) throw PortalFailure.UnsafeURL()
            val body = FormBody.Builder(Charsets.UTF_8).apply { fields.forEach { (k, v) -> add(k, v) } }.build()
            execute(url, expected, body).use { response ->
                if (response.code == 401) throw PortalFailure.LoginRequired()
                if (response.code in 300..399) {
                    val next = response.header("Location")?.let { response.request.url.resolve(it)?.toString() }
                        ?: throw PortalFailure.InvalidResponse()
                    if (PortalConfiguration.isAuthenticationURL(next)) throw PortalFailure.LoginRequired()
                    checkGeneration(expected)
                    return get(next) // the result page after a redirect is a plain read
                }
                if (!response.isSuccessful) throw PortalFailure.Http(response.code)
                val text = response.body?.string() ?: throw PortalFailure.InvalidResponse()
                checkGeneration(expected)
                return PortalPage(text, url)
            }
        } catch (e: IOException) {
            checkGeneration(expected, e)
            throw e
        }
    }

    suspend fun get(url: String): PortalPage {
        val expected = synchronized(cookieLock) { generation }
        return try {
            get(url, expected).also { checkGeneration(expected) }
        } catch (e: IOException) {
            // OkHttp cancellation, including body reads, is an IOException. Only our own
            // invalidated generation means cancellation; genuine IO errors remain errors.
            checkGeneration(expected, e)
            throw e
        }
    }

    private fun checkGeneration(expected: Long, cause: IOException? = null) {
        synchronized(cookieLock) {
            if (expected != generation)
                throw PortalRequestCancelled(cause)
        }
    }

    private suspend fun get(url: String, expected: Long): PortalPage {
        var target = url
        repeat(6) {
            checkGeneration(expected)
            if (!PortalConfiguration.allowsDataURL(target)) throw PortalFailure.UnsafeURL()
            if (PortalConfiguration.isAuthenticationURL(target)) throw PortalFailure.LoginRequired()
            execute(target, expected).use { response ->
                if (response.code in 300..399) {
                    val next =
                        response.header("Location")?.let {
                            response.request.url.resolve(it)?.toString()
                        } ?: throw PortalFailure.InvalidResponse()
                    if (PortalConfiguration.isAuthenticationURL(next))
                        throw PortalFailure.LoginRequired()
                    if (!PortalConfiguration.allowsDataURL(next)) throw PortalFailure.UnsafeURL()
                    target = next
                } else {
                    if (response.code == 401) throw PortalFailure.LoginRequired()
                    if (!response.isSuccessful) throw PortalFailure.Http(response.code)
                    val body = response.body ?: throw PortalFailure.InvalidResponse()
                    if (body.contentLength() > PortalConfiguration.MAX_BYTES)
                        throw PortalFailure.InvalidResponse()
                    val out = ByteArrayOutputStream()
                    body.byteStream().use { input ->
                        val buffer = ByteArray(8192)
                        while (true) {
                            val n = input.read(buffer)
                            if (n < 0) break
                            if (out.size() + n > PortalConfiguration.MAX_BYTES)
                                throw PortalFailure.InvalidResponse()
                            out.write(buffer, 0, n)
                        }
                    }
                    return PortalPage(
                        String(
                            out.toByteArray(),
                            body.contentType()?.charset(Charsets.UTF_8) ?: Charsets.UTF_8,
                        ),
                        target,
                    )
                }
            }
        }
        throw PortalFailure.InvalidResponse()
    }
}
