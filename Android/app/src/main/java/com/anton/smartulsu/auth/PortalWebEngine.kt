package com.anton.smartulsu.auth

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.net.http.SslError
import android.webkit.*
import com.anton.smartulsu.NetworkManager
import com.anton.smartulsu.core.*
import com.google.gson.Gson
import com.google.gson.JsonObject
import java.util.UUID
import kotlin.coroutines.resume
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class LoginForm {
    CREDENTIALS,
    CODE,
}

data class LoginState(
    val form: LoginForm = LoginForm.CREDENTIALS,
    val busy: Boolean = true,
    val prepared: Boolean = false,
    val pending: Boolean = false,
    val complete: Boolean = false,
    val message: String? = null,
    val hint: String = "Подготавливаем вход…",
    val path: String = "",
    val http: Int? = null,
    val codeReset: Long = 0,
)

class PortalLoginController(private val repository: NetworkManager, private val script: String) {
    private val mutable = MutableStateFlow(LoginState())
    val state = mutable.asStateFlow()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var view: WebView? = null
    private var lease: NetworkManager.BrowserLease? = null
    private var prepareJob: Job? = null
    private var work: Job? = null
    private var closeJob: Job? = null
    private var closed = false
    private var fatal = false
    private var navigation = 0
    private var submittedNavigation = 0
    private var lastSubmit: LoginForm? = null
    private var revision = -1L
    private var documentId = ""
    private var submittedDocument = ""
    private var documentReady = false
    private var pageLoadFailed = false

    fun attach(web: WebView) {
        if (view != null) return
        view = web
        configure(web)
        web.webChromeClient =
            object : WebChromeClient() {
                override fun onJsAlert(
                    v: WebView?,
                    u: String?,
                    m: String?,
                    result: JsResult,
                ): Boolean {
                    result.confirm()
                    return true
                }

                override fun onJsConfirm(
                    v: WebView?,
                    u: String?,
                    m: String?,
                    result: JsResult,
                ): Boolean {
                    result.cancel()
                    return true
                }

                override fun onJsPrompt(
                    v: WebView?,
                    u: String?,
                    m: String?,
                    d: String?,
                    result: JsPromptResult,
                ): Boolean {
                    result.cancel()
                    return true
                }
            }
        web.webViewClient =
            object : WebViewClient() {
                override fun shouldOverrideUrlLoading(v: WebView, r: WebResourceRequest): Boolean {
                    if (!r.isForMainFrame || PortalConfiguration.allowsBrowserURL(r.url.toString()))
                        return false
                    fail("ЭИОС перенаправила на неподдерживаемый адрес.")
                    return true
                }

                override fun onPageStarted(v: WebView, url: String?, icon: Bitmap?) {
                    if (closed || state.value.complete) return
                    navigation++
                    documentReady = false
                    pageLoadFailed = false
                    fatal = false
                    val path =
                        runCatching {
                                val u = java.net.URI(url.orEmpty())
                                "${u.host.orEmpty()}${u.path.orEmpty()}"
                            }
                            .getOrDefault("")
                    mutable.value = state.value.copy(path = path, prepared = false, busy = true,
                        http = null, message = null)
                }

                override fun onPageFinished(v: WebView, url: String?) {
                    if (closed || state.value.complete || url != v.url || pageLoadFailed) return
                    documentReady = true
                    if (work?.isActive != true) {
                        mutable.value = state.value.copy(busy = true)
                        work = scope.launch { inspectLoop(lastSubmit != null) }
                    }
                }

                override fun onReceivedError(
                    v: WebView,
                    r: WebResourceRequest,
                    e: WebResourceError,
                ) {
                    if (r.isForMainFrame && r.url.toString() == v.url) {
                        pageLoadFailed = true
                        fail("Не удалось подключиться к ЭИОС. Проверьте интернет или VPN. " +
                            if (lastSubmit != null) "Результат отправки неизвестен. Нажмите «Проверить результат»."
                            else "Нажмите «Обновить форму».")
                    }
                }

                override fun onReceivedHttpError(
                    v: WebView,
                    r: WebResourceRequest,
                    e: WebResourceResponse,
                ) {
                    if (r.isForMainFrame && r.url.toString() == v.url) {
                        pageLoadFailed = true
                        mutable.value = state.value.copy(http = e.statusCode)
                        fail("ЭИОС вернула HTTP ${e.statusCode}.")
                    }
                }

                override fun onReceivedSslError(v: WebView, h: SslErrorHandler, e: SslError) {
                    h.cancel()
                    if (e.url == v.url) {
                        pageLoadFailed = true
                        fail("Не удалось установить защищённое соединение с ЭИОС. Проверьте сеть и дату устройства.")
                    }
                }
            }
        prepareJob =
            scope.launch {
                try {
                    lease = repository.browserWillOpen()
                    if (!closed) restart()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    fail(e.message ?: "Не удалось подготовить вход.")
                }
            }
    }

    private fun fail(message: String) {
        if (closed || state.value.complete) return
        fatal = true
        work?.cancel()
        mutable.value =
            state.value.copy(
                busy = false,
                prepared = false,
                pending = lastSubmit != null,
                message = message,
                hint = "Соединение остановлено",
            )
    }

    fun restart() {
        if (closed || lease == null) return
        work?.cancel()
        fatal = false
        lastSubmit = null
        revision = -1
        documentId = ""
        submittedDocument = ""
        documentReady = false
        pageLoadFailed = false
        mutable.value = LoginState(codeReset = state.value.codeReset + 1)
        view?.loadUrl(PortalConfiguration.LOGIN)
        work = scope.launch { inspectLoop(false) }
    }

    fun checkResult() {
        if (closed || state.value.busy) return
        if (pageLoadFailed && lastSubmit == null && state.value.form == LoginForm.CREDENTIALS) {
            restart()
            return
        }
        work?.cancel()
        fatal = false
        mutable.value = state.value.copy(busy = true, message = null, hint = "Проверяем результат…")
        work = scope.launch { inspectLoop(lastSubmit != null) }
    }

    fun submit(username: String, password: String, code: String) {
        if (closed || state.value.busy || !state.value.prepared || state.value.pending) return
        val form = state.value.form
        if (
            (form == LoginForm.CREDENTIALS && (username.isBlank() || password.isEmpty())) ||
                (form == LoginForm.CODE && !code.matches(Regex("[0-9]{6}")))
        )
            return
        work?.cancel()
        fatal = false
        mutable.value =
            state.value.copy(
                busy = true,
                message = null,
                hint =
                    if (form == LoginForm.CODE) "MAX проверяет код. Обычно это занимает 3–5 секунд…"
                    else "Отправляем данные…",
            )
        work =
            scope.launch {
                lastSubmit = form
                submittedNavigation = navigation
                submittedDocument = documentId
                val started = System.currentTimeMillis()
                val result =
                    bridge(
                        if (form == LoginForm.CODE) "code" else "credentials",
                        username,
                        password,
                        code,
                    )
                if (closed || fatal) return@launch
                val error = result?.text("error").orEmpty()
                if (error.isNotEmpty() && result?.get("submitted")?.asBoolean != true &&
                    result?.get("pending")?.asBoolean != true) {
                    lastSubmit = null
                    mutable.value =
                        state.value.copy(
                            busy = false,
                            prepared = true,
                            pending = false,
                            message = error,
                        )
                    return@launch
                }
                // Keep the pre-submit revision even if the callback was lost during navigation.
                if (form == LoginForm.CODE)
                    delay((3500 - (System.currentTimeMillis() - started)).coerceAtLeast(0))
                inspectLoop(true)
            }
    }

    private suspend fun inspectLoop(afterSubmit: Boolean) {
        val deadline = System.currentTimeMillis() + 30_000
        var missing = 0
        var lastProbe = 0L
        while (!closed && !fatal && System.currentTimeMillis() < deadline) {
            delay(500)
            val result = bridge("inspect") ?: if (pageLoadFailed && afterSubmit)
                JsonObject().apply { addProperty("kind", "web") } else continue
            val kind = result.text("kind")
            val error = result.text("error")
            if (
                kind == "authenticated" || result.text("reason") == "max_accepted" ||
                    (afterSubmit && pageLoadFailed) ||
                    (afterSubmit &&
                        lastSubmit == LoginForm.CODE &&
                        result.text("reason") == "code_form_missing" &&
                        ++missing >= 3)
            ) {
                if (System.currentTimeMillis() - lastProbe < 2500) continue
                lastProbe = System.currentTimeMillis()
                mutable.value = state.value.copy(hint = "Проверяем сессию…")
                try {
                    if (withTimeout(38_000) { lease?.let { repository.verifyLogin(it) } == true }) {
                        mutable.value =
                            state.value.copy(
                                complete = true,
                                busy = false,
                                pending = false,
                                message = null,
                                hint = "Вход выполнен",
                            )
                        return
                    }
                } catch (e: CancellationException) {
                    if (e !is TimeoutCancellationException) throw e
                } catch (_: Exception) {}
            }
            if (kind == "code" || kind == "credentials") {
                missing = 0
                val form = if (kind == "code") LoginForm.CODE else LoginForm.CREDENTIALS
                val nextRevision = result.get("responseRevision")?.asLong ?: -1
                val decision = LoginRecovery.decide(
                    submitted = if (afterSubmit) lastSubmit else null,
                    observed = form,
                    pending = result.get("pending")?.asBoolean == true,
                    error = error,
                    outcome = result.text("outcome"),
                    sameDocument = result.text("documentId") == submittedDocument,
                    navigated = navigation != submittedNavigation,
                    freshResponse = nextRevision > revision,
                )
                if (decision != LoginRecovery.Decision.WAIT) {
                    documentId = result.text("documentId")
                    revision = nextRevision
                    lastSubmit = null
                    mutable.value =
                        state.value.copy(
                            form = form,
                            codeReset = state.value.codeReset +
                                if (decision == LoginRecovery.Decision.REJECTED || form != state.value.form) 1 else 0,
                            busy = false,
                            prepared = true,
                            pending = false,
                            message = error.ifBlank { null },
                            hint =
                                if (form == LoginForm.CODE) "Введите 6 цифр из MAX"
                                else "Войдите через учётную запись ЭИОС",
                        )
                    return
                }
            }
            if (result.text("outcome") == "expired") {
                mutable.value = state.value.copy(busy = false, prepared = false, pending = true,
                    message = error, hint = "Подтверждение MAX завершено")
                return
            }
            if (error.isNotBlank()) mutable.value = state.value.copy(message = error)
        }
        if (!closed && !fatal)
            mutable.value =
                state.value.copy(
                    busy = false,
                    pending = afterSubmit,
                    prepared = false,
                    message =
                        state.value.message ?: if (afterSubmit)
                            "Результат отправки пока неизвестен. Нажмите «Проверить результат»."
                        else
                            "Не удалось подготовить форму ЭИОС. Проверьте соединение и обновите форму.",
                    hint = "Ожидание завершено",
                )
    }

    private suspend fun bridge(
        mode: String,
        username: String = "",
        password: String = "",
        code: String = "",
    ): JsonObject? {
        val web = view ?: return null
        if (!documentReady || pageLoadFailed) return null
        val inspectedNavigation = navigation
        if (!PortalConfiguration.allowsDataURL(web.url.orEmpty())) return null
        val gson = Gson()
        val key = gson.toJson("__smarttable_" + UUID.randomUUID().toString().replace("-", ""))
        val args = listOf(mode, username, password, code).joinToString(",") { gson.toJson(it) }
        val js =
            "(function(){window[$key]=null;(async function(mode,username,password,code){\n$script\n})($args).then(v=>{window[$key]=v},()=>{window[$key]=JSON.stringify({kind:'web',reason:'bridge_error'})});return true;})()"
        return try {
            withTimeout(3500) {
                web.evaluate(js)
                while (true) {
                    val result = LoginBridgeCodec.decode(web.evaluate("window[$key] || null"))
                    if (navigation != inspectedNavigation || !documentReady || pageLoadFailed) return@withTimeout null
                    if (result != null) return@withTimeout result
                    delay(100)
                }
                @Suppress("UNREACHABLE_CODE") null
            }
        } catch (_: TimeoutCancellationException) {
            null
        } finally {
            if (!closed) web.evaluateJavascript("delete window[$key]", null)
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

private fun JsonObject.text(key: String) =
    get(key)?.takeIf { it.isJsonPrimitive }?.asString.orEmpty()

suspend fun WebView.evaluate(script: String): String = suspendCancellableCoroutine { continuation ->
    evaluateJavascript(script) { if (continuation.isActive) continuation.resume(it ?: "null") }
}

@SuppressLint("SetJavaScriptEnabled")
fun configure(web: WebView) {
    web.settings.javaScriptEnabled = true
    web.settings.domStorageEnabled = true
    web.settings.allowFileAccess = false
    web.settings.allowContentAccess = false
    web.settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
    web.settings.javaScriptCanOpenWindowsAutomatically = false
    CookieManager.getInstance().setAcceptThirdPartyCookies(web, false)
    web.isFocusable = false
    web.importantForAccessibility =
        android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
}
