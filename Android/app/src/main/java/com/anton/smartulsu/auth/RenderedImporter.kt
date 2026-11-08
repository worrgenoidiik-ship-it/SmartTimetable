package com.anton.smartulsu.auth

import android.net.http.SslError
import android.webkit.*
import com.anton.smartulsu.NetworkManager
import com.anton.smartulsu.core.*
import com.google.gson.JsonParser
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

data class ImportState(
    val busy: Boolean = true,
    val complete: Boolean = false,
    val error: String? = null,
)

class RenderedImporter(private val repository: NetworkManager, private val section: PortalSection) {
    private val mutable = MutableStateFlow(ImportState())
    val state = mutable.asStateFlow()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var view: WebView? = null
    private var lease: NetworkManager.BrowserLease? = null
    private var prepareJob: Job? = null
    private var work: Job? = null
    private var closeJob: Job? = null
    private var closed = false

    fun attach(web: WebView) {
        if (view != null) return
        view = web
        configure(web)
        web.webViewClient =
            object : WebViewClient() {
                override fun shouldOverrideUrlLoading(v: WebView, r: WebResourceRequest) =
                    r.isForMainFrame && !PortalConfiguration.allowsBrowserURL(r.url.toString())

                override fun onReceivedError(
                    v: WebView,
                    r: WebResourceRequest,
                    e: WebResourceError,
                ) {
                    if (r.isForMainFrame)
                        fail("${section.title}: не удалось загрузить страницу. Проверьте интернет или VPN. Сохранённые данные доступны.")
                }

                override fun onReceivedHttpError(
                    v: WebView,
                    r: WebResourceRequest,
                    e: WebResourceResponse,
                ) {
                    if (r.isForMainFrame) fail("ЭИОС вернула HTTP ${e.statusCode}.")
                }

                override fun onReceivedSslError(v: WebView, h: SslErrorHandler, e: SslError) {
                    h.cancel()
                    fail("${section.title}: не удалось установить защищённое соединение с ЭИОС.")
                }
            }
        prepareJob =
            scope.launch {
                try {
                    lease = repository.browserWillOpen()
                    if (!closed) retry()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    fail(e.message ?: "Не удалось начать загрузку.")
                }
            }
    }

    private fun fail(message: String) {
        if (!closed && !state.value.complete) {
            mutable.value = ImportState(busy = false, error = message)
            work?.cancel()
        }
    }

    fun retry() {
        val web = view ?: return
        if (closed || lease == null) return
        work?.cancel()
        mutable.value = ImportState()
        web.loadUrl(section.url)
        work =
            scope.launch {
                var error: Exception? = null
                repeat(40) {
                    delay(500)
                    try {
                        val raw =
                            withTimeout(3000) {
                                web.evaluate(
                                    "JSON.stringify({url:location.href,html:document.documentElement.outerHTML})"
                                )
                            }
                        val outer = JsonParser.parseString(raw)
                        if (!outer.isJsonPrimitive) return@repeat
                        val page = JsonParser.parseString(outer.asString).asJsonObject
                        val url = page.get("url").asString
                        val html = page.get("html").asString
                        if (!PortalConfiguration.allowsDataURL(url)) return@repeat
                        if (PortalConfiguration.isAuthenticationURL(url))
                            throw PortalFailure.LoginRequired()
                        if (html.toByteArray().size > PortalConfiguration.MAX_BYTES)
                            throw PortalFailure.InvalidResponse()
                        repository.importRendered(section, html, url, lease!!)
                        mutable.value = ImportState(busy = false, complete = true)
                        return@launch
                    } catch (e: TimeoutCancellationException) {
                        error = e
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: PortalFailure.LoginRequired) {
                        fail(e.message.orEmpty())
                        return@launch
                    } catch (e: Exception) {
                        error = e
                    }
                }
                fail(error?.let { PortalErrors.sectionMessage(section, it) } ?: "${section.title}: ЭИОС пока не загрузила данные.")
            }
    }

    fun close(): Job {
        closeJob?.let {
            return it
        }
        closed = true
        view?.stopLoading()
        scope.cancel()
        val cleanup = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        return cleanup
            .launch {
                try {
                    prepareJob?.join()
                    lease?.let { repository.browserDidClose(it) }
                } finally {
                    view?.destroy()
                    view = null
                    cleanup.cancel()
                }
            }
            .also { closeJob = it }
    }
}
