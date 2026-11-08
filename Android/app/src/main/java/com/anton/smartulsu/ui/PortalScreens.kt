package com.anton.smartulsu.ui

import android.net.http.SslError
import android.webkit.*
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import kotlinx.coroutines.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.anton.smartulsu.NetworkManager
import com.anton.smartulsu.auth.*
import com.anton.smartulsu.core.*
import com.anton.smartulsu.data.CredentialStore

@Composable
internal fun MaxCodeField(
    value: String,
    onValueChange: (String) -> Unit,
    enabled: Boolean,
) {
    OutlinedTextField(
        value = value,
        onValueChange = {
            onValueChange(it.filter { c -> c in '0'..'9' }.take(6))
        },
        label = { Text("Код MAX") },
        singleLine = true,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        keyboardOptions = KeyboardOptions(
            keyboardType = KeyboardType.NumberPassword
        ),
    )
}

@Composable
fun NativeLoginScreen(repository: NetworkManager, onClose: (() -> Unit)?, onComplete: () -> Unit) {
    val context = LocalContext.current
    val controller =
        remember(repository) {
            PortalLoginController(
                repository,
                context.assets.open("portal_login_bridge.js").bufferedReader().use { it.readText() },
            )
        }
    val state by controller.state.collectAsState()
    val scope = rememberCoroutineScope()
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var code by remember { mutableStateOf("") }
    var rememberLogin by remember { mutableStateOf(repository.credentials.enabled) }
    // A saved login is filled in and submitted once per screen; a changed password stops at the error.
    var autoSubmit by remember { mutableStateOf(false) }
    var sent by remember { mutableStateOf<CredentialStore.Credentials?>(null) }
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) { repository.credentials.load() }?.let {
            username = it.username
            password = it.password
            autoSubmit = true
        }
    }
    LaunchedEffect(state.prepared, state.busy, state.form, autoSubmit) {
        if (autoSubmit && state.prepared && !state.busy && !state.pending && state.form == LoginForm.CREDENTIALS &&
            username.isNotBlank() && password.isNotEmpty()) {
            autoSubmit = false
            sent = CredentialStore.Credentials(username.trim(), password)
            controller.submit(username.trim(), password, code)
        }
    }
    DisposableEffect(controller) { onDispose { controller.close() } }
    LaunchedEffect(state.complete) {
        if (state.complete) {
            // Saved only after the portal confirmed the account.
            val confirmed = sent
            if (rememberLogin && confirmed != null) withContext(Dispatchers.IO) { repository.credentials.save(confirmed) }
            sent = null
            password = ""
            code = ""
            controller.close().join()
            onComplete()
        }
    }
    LaunchedEffect(state.codeReset) { code = "" }
    LaunchedEffect(state.form) { if (state.form == LoginForm.CODE) password = "" }
    BackHandler(onClose != null) {
        scope.launch {
            controller.close().join()
            onClose?.invoke()
        }
    }
    Box(Modifier.fillMaxSize()) {
        AndroidView(
            factory = { WebView(it).apply { controller.attach(this) } },
            modifier = Modifier.fillMaxSize(),
        )
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(
                Modifier.fillMaxSize()
                    .imePadding()
                    .verticalScroll(rememberScrollState())
                    .padding(24.dp),
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    "SmartTimetable",
                    fontSize = 38.sp,
                    fontWeight = FontWeight.Black,
                    color = MaterialTheme.colorScheme.primary,
                )
                Text(
                    if (state.form == LoginForm.CODE) "Подтверждение MAX"
                    else "Твой университет рядом",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(30.dp))
                if (state.form == LoginForm.CREDENTIALS) {
                    OutlinedTextField(
                        username,
                        { username = it },
                        label = { Text("Логин ЭИОС") },
                        singleLine = true,
                        enabled = !state.busy,
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(16.dp),
                    )
                    Spacer(Modifier.height(12.dp))
                    OutlinedTextField(
                        password,
                        { password = it },
                        label = { Text("Пароль") },
                        singleLine = true,
                        enabled = !state.busy,
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(16.dp),
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(rememberLogin, { value ->
                            rememberLogin = value
                            scope.launch(Dispatchers.IO) { repository.credentials.enabled = value }
                        })
                        Column {
                            Text("Входить автоматически", fontWeight = FontWeight.Medium)
                            Text("Когда ЭИОС завершит сессию, приложение войдёт само. Логин и пароль зашифрованы на телефоне, код MAX не сохраняется.",
                                style = MaterialTheme.typography.bodySmall)
                        }
                    }
                } else {
                    Text("Введите шесть цифр из сообщения MAX")
                    Spacer(Modifier.height(16.dp))
                    MaxCodeField(code, { code = it }, enabled = state.prepared && !state.busy && !state.pending)
                }
                Spacer(Modifier.height(20.dp))
                Button(
                    onClick = {
                        if (state.form == LoginForm.CREDENTIALS) sent = CredentialStore.Credentials(username.trim(), password)
                        controller.submit(username.trim(), password, code)
                    },
                    enabled =
                        state.prepared &&
                            !state.busy &&
                            !state.pending &&
                            (if (state.form == LoginForm.CODE) code.length == 6
                            else username.isNotBlank() && password.isNotEmpty()),
                    modifier = Modifier.fillMaxWidth().height(54.dp),
                    shape = RoundedCornerShape(16.dp),
                ) {
                    Text(
                        if (state.form == LoginForm.CODE) "Подтвердить" else "Войти",
                        fontWeight = FontWeight.Bold,
                    )
                }
                Spacer(Modifier.height(14.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (state.busy)
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Text(state.hint, style = MaterialTheme.typography.bodySmall)
                }
                state.message?.let {
                    Text(it, Modifier.padding(top = 12.dp), color = MaterialTheme.colorScheme.error)
                }
                if (!state.busy && (state.pending || state.message != null)) {
                    if (state.pending || state.form == LoginForm.CODE)
                        TextButton(onClick = controller::checkResult) {
                            Text(if (state.pending) "Проверить результат" else "Проверить форму")
                        }
                    if (state.form == LoginForm.CREDENTIALS && !state.pending)
                        TextButton(onClick = controller::restart) { Text("Обновить форму") }
                    if (state.pending || (state.form == LoginForm.CODE && !state.prepared))
                        TextButton(onClick = {
                            code = ""
                            controller.restart()
                        }) { Text("Начать новый вход") }
                    if (state.path.isNotBlank())
                        Text(
                            state.path + (state.http?.let { " · HTTP $it" } ?: ""),
                            style = MaterialTheme.typography.labelSmall,
                        )
                }
                if (onClose != null)
                    TextButton(
                        onClick = {
                            scope.launch {
                                controller.close().join()
                                onClose()
                            }
                        }
                    ) {
                        Text("К сохранённым данным")
                    }
            }
        }
    }
}

@Composable
fun ImportScreen(repository: NetworkManager, section: PortalSection, onClose: () -> Unit) {
    val controller = remember(repository, section) { RenderedImporter(repository, section) }
    val state by controller.state.collectAsState()
    val scope = rememberCoroutineScope()
    DisposableEffect(controller) { onDispose { controller.close() } }
    LaunchedEffect(state.complete) {
        if (state.complete) {
            controller.close().join()
            onClose()
        }
    }
    BackHandler {
        scope.launch {
            controller.close().join()
            onClose()
        }
    }
    Box(Modifier.fillMaxSize()) {
        AndroidView(
            factory = { WebView(it).apply { controller.attach(this) } },
            modifier = Modifier.fillMaxSize(),
        )
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(
                Modifier.fillMaxSize().padding(24.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                if (state.busy) CircularProgressIndicator()
                Text(
                    section.title,
                    Modifier.padding(top = 20.dp),
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                )
                Text(state.error ?: "Загружаем данные из ЭИОС…", Modifier.padding(vertical = 14.dp))
                if (!state.busy) Button(onClick = controller::retry) { Text("Повторить") }
                TextButton(
                    onClick = {
                        scope.launch {
                            controller.close().join()
                            onClose()
                        }
                    }
                ) {
                    Text("Закрыть")
                }
            }
        }
    }
}

@Composable
fun PortalBrowserScreen(
    repository: NetworkManager,
    url: String,
    title: String,
    onLoginRequired: () -> Unit,
    onClose: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var web by remember { mutableStateOf<WebView?>(null) }
    var ready by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var owner by remember(repository) { mutableStateOf<Job?>(null) }
    var closing by remember(repository) { mutableStateOf(false) }
    var progress by remember { mutableIntStateOf(0) }
    LaunchedEffect(repository) {
        if (closing) return@LaunchedEffect
        owner = currentCoroutineContext().job
        try {
            withBrowserLease(repository::browserWillOpen, { lease ->
                // Stop WebView callbacks before releasing the repository to HTTP refreshes.
                ready = false
                try {
                    web?.stopLoading()
                    web?.destroy()
                } finally {
                    web = null
                    repository.browserDidClose(lease)
                }
            }) { lease ->
                repository.verifyBrowserAccount(lease)
                ready = true
                awaitCancellation()
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e.message
        }
    }
    fun finish(relogin: Boolean = false) {
        if (closing) return
        closing = true
        scope.launch {
            owner?.cancelAndJoin()
            if (relogin) onLoginRequired() else onClose()
        }
    }
    BackHandler { if (web?.canGoBack() == true) web?.goBack() else finish() }
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { finish() }) { Text("Закрыть") }
            Text(title.ifBlank { "Мои курсы · ЭИОС" }, modifier = Modifier.weight(1f),
                maxLines = 2, fontWeight = FontWeight.Bold)
        }
        error?.let {
            Text(it, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error)
            TextButton(onClick = { finish(true) }) { Text("Войти в ЭИОС") }
        }
        if (ready && error == null && progress < 100)
            LinearProgressIndicator(progress = { progress / 100f }, modifier = Modifier.fillMaxWidth())
        if (ready)
            AndroidView(
                factory = { context ->
                    WebView(context).apply {
                        web = this
                        configure(this)
                        isFocusable = true
                        isFocusableInTouchMode = true
                        importantForAccessibility =
                            android.view.View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
                        webChromeClient = object : WebChromeClient() {
                            override fun onProgressChanged(view: WebView, newProgress: Int) {
                                progress = newProgress
                                // Course activities look like part of the app: the site's header, side
                                // drawer, blocks and footer are hidden; the content and its controls stay,
                                // so tests are still taken and saved by ЭИОС itself.
                                if (newProgress >= 60) view.evaluateJavascript(CLEAN_PORTAL_PAGE, null)
                            }
                        }
                        webViewClient =
                            object : WebViewClient() {
                                override fun shouldOverrideUrlLoading(
                                    v: WebView,
                                    r: WebResourceRequest,
                                ): Boolean {
                                    if (
                                        r.isForMainFrame &&
                                            PortalConfiguration.isAuthenticationURL(
                                                r.url.toString()
                                            )
                                    ) {
                                        finish(true)
                                        return true
                                    }
                                    if (
                                        r.isForMainFrame &&
                                            !PortalConfiguration.allowsBrowserURL(r.url.toString())
                                    ) {
                                        error = "Ссылка ведёт за пределы университетского портала."
                                        return true
                                    }
                                    return false
                                }

                                override fun onReceivedSslError(
                                    v: WebView,
                                    h: SslErrorHandler,
                                    e: SslError,
                                ) {
                                    h.cancel()
                                    error = "Unable to establish a secure connection to EIOS."
                                }

                                override fun onReceivedError(
                                    v: WebView,
                                    r: WebResourceRequest,
                                    e: WebResourceError,
                                ) {
                                    if (r.isForMainFrame) error = "Unable to connect to EIOS."
                                }
                            }
                        if (PortalConfiguration.allowsBrowserURL(url)) loadUrl(url)
                    }
                },
                update = { /* Never reload an active test during recomposition. */ },
                modifier = Modifier.fillMaxSize(),
            )
        else if (error == null) CircularProgressIndicator(Modifier.padding(24.dp))
    }
}
//

private const val CLEAN_PORTAL_PAGE = """
(function(){ if (document.getElementById('smarttable-clean')) return;
var s=document.createElement('style'); s.id='smarttable-clean';
s.textContent='nav.navbar,.navbar.fixed-top,#nav-drawer,[data-region="drawer"],#page-header .breadcrumbs,#page-footer,footer,'+
'#block-region-side-pre,#block-region-side-post,[data-region="blocks-column"],.block-region,.message-drawer,'+
'[data-region="message-drawer"],#customAlert,.customAlert,.btn-footer-popover,#goto-top-link,.drawer-toggle'+
'{display:none!important} body,#page,#page-wrapper{padding-top:0!important;margin-top:0!important;margin-left:0!important}'+
'#region-main,#region-main-box{padding:10px!important;border:none!important;box-shadow:none!important}';
(document.head||document.documentElement).appendChild(s); })();
"""
