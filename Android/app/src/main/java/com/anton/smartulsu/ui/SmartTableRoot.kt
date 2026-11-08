package com.anton.smartulsu.ui

import android.Manifest
import android.app.DatePickerDialog
import android.content.Intent
import android.content.Context
import android.net.Uri
import kotlinx.coroutines.launch
import com.anton.smartulsu.core.AppUpdates
import com.anton.smartulsu.core.AppRelease
import android.provider.Settings
import androidx.lifecycle.LifecycleEventObserver
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.activity.result.PickVisualMediaRequest
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.anton.smartulsu.*
import com.anton.smartulsu.core.*
import com.anton.smartulsu.data.ProfilePhotoCodec
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.TemporalAdjusters
import java.util.Locale
import kotlinx.coroutines.*
import android.graphics.Bitmap


@Composable
fun SmartTableRoot(
    app: SmartTableApplication,
    locked: Boolean,
    unlock: () -> Unit,
    setLock: (Boolean) -> Boolean,
    didSignOut: () -> Unit,
    requestedDestination: NotificationDestination?,
    consumeDestination: () -> Unit,
) {
    val repo = app.repository
    val context = LocalContext.current
    val state by repo.state.collectAsState()
    val noteDraft by repo.noteDraft.collectAsState()
    val pref by app.preferences.state.collectAsState()
    var navigationPhoto by remember { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(state.snapshot.profile?.accountKey, state.snapshot.profilePhoto) {
        navigationPhoto = null
        navigationPhoto = withContext(Dispatchers.IO) {
            ProfilePhotoCodec.decode(state.snapshot.profilePhoto)
        }
    }
    val scope = rememberCoroutineScope()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var login by remember { mutableStateOf(false) }
    var initialRouteResolved by remember { mutableStateOf(false) }
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var inbox by rememberSaveable { mutableStateOf(false) }
    var notificationSchedule by rememberSaveable { mutableStateOf(false) }
    var explainNotifications by remember { mutableStateOf(false) }
    var notificationsAllowed by remember { mutableStateOf(PortalNotifier.allowed(context)) }
    fun openNotificationSettings() {
        val intent = if (Build.VERSION.SDK_INT >= 26)
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
        else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
        context.startActivity(intent)
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) notificationsAllowed = PortalNotifier.allowed(context)
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    var importer by remember { mutableStateOf<PortalSection?>(null) }
    val manualPlan by repo.manualScheduleState.collectAsState()
    val activeAccount = state.snapshot.profile?.accountKey
    var browser by remember(activeAccount) { mutableStateOf<String?>(null) }
    var browserTitle by remember(activeAccount) { mutableStateOf("") }
    var notesOpen by rememberSaveable(activeAccount) { mutableStateOf(false) }
    var portalPage by remember(activeAccount) { mutableStateOf<PortalPageKind?>(null) }
    var courseDetail by remember(activeAccount) { mutableStateOf<Course?>(null) }
    // Native messenger and forms (iOS 1.5–1.7 port).
    var chat by remember(activeAccount) { mutableStateOf<Triple<Int?, String, ChatUser?>?>(null) }
    var newChat by remember(activeAccount) { mutableStateOf<String?>(null) }
    var coursePicker by remember(activeAccount) { mutableStateOf(false) }
    var questionOpen by remember(activeAccount) { mutableStateOf(false) }
    var inquiryOpen by remember(activeAccount) { mutableStateOf(false) }
    var coursesOpen by remember(activeAccount) { mutableStateOf(false) }
    var quiz by remember(activeAccount) { mutableStateOf<Pair<String, String>?>(null) }
    // With a saved login the sign-in screen opens by itself when the portal ends the session;
    // it submits automatically, so only a MAX code (if asked) is left for the user.
    var lastAutoLogin by remember { mutableLongStateOf(0L) }
    LaunchedEffect(state.session, locked) {
        if (state.session == SessionState.NEEDS_LOGIN && !locked && !login && browser == null &&
            state.snapshot.profile != null && repo.credentials.hasCredentials &&
            System.currentTimeMillis() - lastAutoLogin > 10 * 60_000L
        ) {
            lastAutoLogin = System.currentTimeMillis()
            login = true
        }
    }
    fun openBrowser(title: String, url: String) {
        if (browser == null && !locked) {
            browserTitle = title
            browser = url
        }
    }
    val coursesListState = key(activeAccount) { rememberLazyListState() }
    var welcome by remember { mutableStateOf(false) }
    var lockError by remember { mutableStateOf(false) }
    val logoutPending by repo.logoutPending.collectAsState()
    val logoutRunning by repo.logoutRunning.collectAsState()
    var logoutWaiting by remember { mutableStateOf(false) }

    fun requestLogout() {
        if (logoutWaiting) return
        logoutWaiting = true
        Messenger.reset()
        browser = null
        importer = null
        notesOpen = false
        portalPage = null
        courseDetail = null
        welcome = false
        inbox = false
        scope.launch {
            try {
                repo.logout() // Completion is observed below, independently of this caller.
            } finally {
                logoutWaiting = false
            }
        }
    }

    val permission =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            app.preferences.update { it.copy(notifications = granted) }
            notificationsAllowed = PortalNotifier.allowed(context)
        }
    LaunchedEffect(requestedDestination, locked, login, browser, importer, state.ready,
        state.snapshot.profile?.accountKey, logoutPending) {
        // Do not close a login/import WebView or bypass the app lock to handle a tap.
        if (requestedDestination != null && !locked && !login && browser == null && importer == null &&
            state.ready && state.snapshot.profile != null && !logoutPending) {
            notesOpen = false
            welcome = false
            inbox = requestedDestination == NotificationDestination.INBOX
            if (requestedDestination == NotificationDestination.SCHEDULE) {
                tab = 1
                notificationSchedule = true
            }
            consumeDestination()
        }
    }
    // Keep the login screen alive until the controller releases the cookie lease.
    LaunchedEffect(state.ready, state.snapshot.profile?.accountKey, logoutPending) {
        if (state.ready) {
            if (state.snapshot.profile == null) {
                login = true
                if (!logoutPending && state.message == null) {
                    // Also runs after late cleanup completion or recreation of this screen.
                    if (app.preferences.state.value.appLock)
                        app.preferences.update { it.copy(appLock = false) }
                    didSignOut()
                }
            }
            initialRouteResolved = true
        }
    }
    LaunchedEffect(repo, pref.autoRefresh) {
        repo.prepare()
        var firstRefresh = true
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            if (pref.autoRefresh) RefreshScheduler.runForegroundLoop({
                repo.refresh(force = firstRefresh)
                firstRefresh = false
            })
        }
    } // val photoPicker
    Box(
        Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).systemBarsPadding()
    ) {
        when {
            logoutPending ->
                Column(
                    Modifier.fillMaxSize().padding(24.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        if (logoutRunning) "Выполняется выход…" else "Выход из аккаунта не завершён",
                        style = MaterialTheme.typography.titleLarge,
                    )
                    Text(
                        state.message ?: "Очистка данных ещё не подтверждена.",
                        Modifier.padding(vertical = 16.dp),
                    )
                    Text(
                        "Вход заблокирован до успешного завершения очистки."
                    )
                    Button(
                        onClick = { requestLogout() },
                        enabled = !logoutWaiting && !logoutRunning,
                        modifier = Modifier.padding(top = 16.dp),
                    ) {
                        Text(
                            if (logoutWaiting || logoutRunning) "Подождите…"
                            else "Повторить очистку"
                        )
                    }
                }

            !state.ready || !initialRouteResolved ->
                Box(
                    Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator()
                }

            login || state.snapshot.profile == null ->
                NativeLoginScreen(
                    repo,
                    if (state.snapshot.profile != null) ({ login = false }) else null,
                ) {
                    login = false
                    welcome = true
                    scope.launch { RefreshScheduler.ensure(app) }
                    RefreshScheduler.ensureKeepAlive(app)
                    scope.launch { repo.refresh(true) }
                }
        browser != null ->
                PortalBrowserScreen(
                    repo,
                    browser!!,
                    browserTitle,
                    {
                        browser = null
                        login = true
                    },
                ) {
                    browser = null
                }
            importer != null -> ImportScreen(repo, importer!!) { importer = null }
            else ->
                Scaffold(
                    containerColor = MaterialTheme.colorScheme.background,
                    bottomBar = {
                        NavigationBar(containerColor = MaterialTheme.colorScheme.surface) {
                            listOf(
                                "Профиль" to Icons.Outlined.AccountCircle,
                                "Расписание" to Icons.Outlined.CalendarMonth,
                                "Сообщения" to Icons.Outlined.Forum,
                                "ЭИОС" to Icons.Outlined.Apps,
                                "Настройки" to Icons.Outlined.Settings,
                            )
                                .forEachIndexed { index, (label, icon) ->
                                    NavigationBarItem(
                                        selected = tab == index && !inbox,
                                        onClick = {
                                            tab = index
                                            inbox = false
                                            portalPage = null
                                            courseDetail = null
                                            chat = null; newChat = null; coursePicker = false; quiz = null
                                            questionOpen = false; inquiryOpen = false; coursesOpen = false
                                            notesOpen = false
                                            notificationSchedule = false
                                        },
                                        icon = {
                                            val photo = navigationPhoto
                                            if (index == 0 && photo != null) {
                                                Image(
                                                    photo.asImageBitmap(), label,
                                                    Modifier.size(28.dp).clip(CircleShape),
                                                    contentScale = ContentScale.Crop,
                                                )
                                            } else Icon(icon, label)
                                        },
                                        label = { Text(label, fontSize = 10.sp) },
                                    )
                                }
                        }
                    },
                ) { padding ->
                    Column(Modifier.padding(padding).fillMaxSize()) {
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                "SmartTimetable" + if (pref.christmas) " ❄" else "",
                                fontSize = 25.sp,
                                fontWeight = FontWeight.Black,
                                color = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.weight(1f),
                            )
                            IconButton(
                                onClick = { scope.launch { repo.refresh(true) } },
                                enabled = !state.loading,
                            ) {
                                Icon(Icons.Outlined.Refresh, "Обновить данные")
                            }
                            BadgedBox(
                                badge = {
                                    val count =
                                        state.snapshot.notifications?.value.orEmpty().count {
                                            it.isUnread
                                        }
                                    if (count > 0) Badge { Text(count.toString()) }
                                }
                            ) {
                                IconButton(onClick = { notesOpen = false; inbox = true }) {
                                    Icon(Icons.Outlined.Notifications, "Уведомления")
                                }
                            }
                        }
                        if (state.loading) LinearProgressIndicator(Modifier.fillMaxWidth())
                        if (state.session == SessionState.NEEDS_LOGIN)
                            Row(
                                Modifier.padding(horizontal = 20.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    "Сессия завершена. Сохранённые данные доступны.",
                                    Modifier.weight(1f),
                                    style = MaterialTheme.typography.bodySmall,
                                )
                                TextButton(onClick = { login = true }) { Text("Войти") }
                            }
                        else state.message?.let { Hint(it, Modifier.padding(horizontal = 20.dp)) }
                        if (notesOpen) {
                            NotesScreen(state.snapshot, noteDraft, repo::flushNotes,
                                { text -> activeAccount?.let { repo.queueNotes(text, it) } },
                                { notesOpen = false })
                        } else if (inbox) {
                            BackHandler { inbox = false }
                            InboxScreen(
                                state,
                                { importer = PortalSection.NOTIFICATIONS },
                                { inbox = false },
                            )
                        } else if (portalPage != null) {
                            PortalDocumentScreen(repo, state, portalPage!!, ::openBrowser) { portalPage = null }
                        } else if (quiz != null) {
                            QuizScreen(repo, quiz!!.first, quiz!!.second, ::openBrowser) { quiz = null }
                        } else if (chat != null) {
                            val (id, title, partner) = chat!!
                            ChatScreen(repo, title, id, partner) { chat = null; scope.launch { Messenger.load(repo) } }
                        } else if (newChat != null) {
                            NewChatScreen(repo, newChat!!, { user -> chat = Triple(null, user.fullname, user); newChat = null }) { newChat = null }
                        } else if (courseDetail != null) {
                            CourseDetailScreen(repo, state, courseDetail!!, ::openBrowser,
                                writeTeacher = { newChat = it }, openQuiz = { title, url -> quiz = title to url }) { courseDetail = null }
                        } else if (coursePicker) {
                            CoursePickerScreen(state.snapshot.courses?.value.orEmpty(),
                                { course -> coursePicker = false; newChat = CourseTitle(course.title).teacher.orEmpty() }) { coursePicker = false }
                        } else if (questionOpen) {
                            QuestionScreen(repo) { questionOpen = false }
                        } else if (inquiryOpen) {
                            InquiryScreen(repo) { inquiryOpen = false }
                        } else if (coursesOpen) {
                            BackHandler { coursesOpen = false }
                            Column {
                                TextButton(onClick = { coursesOpen = false }, Modifier.padding(horizontal = 12.dp)) { Text("Назад") }
                                CoursesScreen(state, { importer = PortalSection.COURSES },
                                    { selected -> if (!locked) courseDetail = selected }, coursesListState)
                            }
                        } else
                            when (tab) {
                                0 -> key(activeAccount, locked) {
                                    ProfileScreen(
                                        state, pref,
                                        {
                                            app.preferences.update {
                                                it.copy(cardStyle = (it.cardStyle + 1) % 4)
                                            }
                                        },
                                        { importer = PortalSection.GRADES },
                                        savePhoto = { value, account -> repo.saveProfilePhoto(value, account) },
                                        attestation = {
                                            PortalDocumentContent(state, PortalPageKind.ATTESTATION, ::openBrowser, maxRows = 20)
                                        },
                                    )
                                }
                                1 -> ScheduleScreen(manualPlan, state,
                                    if (notificationSchedule) ScheduleSource.PORTAL else pref.scheduleSource) {
                                    scope.launch { repo.refresh(true) }
                                }
                                2 -> MessagesTab(repo, state, { id, title -> chat = Triple(id, title, null) }, { newChat = it },
                                    { coursePicker = true }, { questionOpen = true }, { notesOpen = false; inbox = true })
                                3 -> ServicesScreen(state, ::openBrowser, { portalPage = it }, openQuiz = { title, url -> quiz = title to url },
                                    openCourses = { coursesOpen = true }, question = { questionOpen = true }, inquiry = { inquiryOpen = true })
                                else ->
                                    SettingsScreen(
                                        pref,
                                        !locked,
                                        { next ->
                                            val enablePortal = next.portalSchedule && !pref.portalSchedule
                                            app.preferences.update { next }
                                            if (enablePortal) scope.launch { repo.refresh(true) }
                                        },
                                        { if (!setLock(it)) lockError = true },
                                        { enabled ->
                                            app.preferences.update {
                                                it.copy(autoRefresh = enabled)
                                            }
                                            if (enabled) scope.launch { RefreshScheduler.ensure(app) }
                                            else scope.launch { RefreshScheduler.cancelIfDisabled(app) }
                                        },
                                        { enabled ->
                                            if (!enabled) app.preferences.update { it.copy(notifications = false) }
                                            else when (NotificationPermissionPolicy.action(
                                                Build.VERSION.SDK_INT >= 33, PortalNotifier.runtimeGranted(context),
                                                pref.notificationPermissionAsked, PortalNotifier.allowed(context),
                                            )) {
                                                NotificationPermissionPolicy.Action.ENABLE ->
                                                    app.preferences.update { it.copy(notifications = true) }
                                                NotificationPermissionPolicy.Action.REQUEST -> explainNotifications = true
                                                NotificationPermissionPolicy.Action.SETTINGS -> openNotificationSettings()
                                            }
                                        },
                                        notificationsAllowed,
                                        ::openNotificationSettings,
                                        { notesOpen = true },
                                        { login = true },
                                        {
                                            requestLogout()
                                        },
                                    )
                            }
                    }
                }
        }
        if (explainNotifications && !locked)
            AlertDialog(
                onDismissRequest = { explainNotifications = false },
                title = { Text("Уведомления SmartTimetable") },
                text = { Text("Сообщим о новых уведомлениях ЭИОС и изменениях расписания. " +
                    "Имена, оценки и тексты сообщений не появятся на экране блокировки. Категории можно отключить в настройках.") },
                confirmButton = { TextButton(onClick = {
                    explainNotifications = false
                    app.preferences.update { it.copy(notificationPermissionAsked = true) }
                    permission.launch(Manifest.permission.POST_NOTIFICATIONS)
                }) { Text("Продолжить") } },
                dismissButton = { TextButton(onClick = { explainNotifications = false }) { Text("Не сейчас") } },
            )
        if (locked)
            Surface(
                Modifier.fillMaxSize().clickable {},
                color = MaterialTheme.colorScheme.background,
            ) {
                Column(
                    Modifier.fillMaxSize().padding(24.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(
                        Icons.Outlined.Lock,
                        null,
                        Modifier.size(48.dp),
                        tint = MaterialTheme.colorScheme.primary,
                    )
                    Text(
                        "SmartTimetable заблокирован",
                        Modifier.padding(20.dp),
                        style = MaterialTheme.typography.titleLarge,
                    )
                    Button(onClick = unlock) { Text("Разблокировать") }
                }
            }
    }
    if (welcome && !locked)
        AlertDialog(
            onDismissRequest = { welcome = false },
            title = { Text("Вход выполнен") },
            text = {
                Text(
                    "Загрузим карточки курсов через текущую сессию. Зачётку и уведомления можно обновить в их разделах."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        welcome = false
                        importer = PortalSection.COURSES
                    }
                ) {
                    Text("Загрузить курсы")
                }
            },
            dismissButton = { TextButton(onClick = { welcome = false }) { Text("Позже") } },
        )
    AppUpdatePrompt(locked)
    if (lockError && !locked)
        AlertDialog(
            onDismissRequest = { lockError = false },
            title = { Text("Настройте защиту устройства") },
            text = { Text("Добавьте отпечаток пальца или код блокировки в настройках Android.") },
            confirmButton = { TextButton(onClick = { lockError = false }) { Text("Понятно") } },
        )
}

@Composable
internal fun ProfileScreen(
    state: PortalState,
    pref: UiPreferences,
    changeCard: () -> Unit,
    importGrades: () -> Unit,
    savePhoto: suspend (String?, String) -> Unit,
    attestation: @Composable () -> Unit = {},
) {
    var expanded by rememberSaveable { mutableStateOf(true) }
    var assessmentsExpanded by rememberSaveable { mutableStateOf(false) }
    var semester by rememberSaveable { mutableStateOf("") }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val accountKey = state.snapshot.profile?.accountKey
    var avatar by remember(accountKey) { mutableStateOf<Bitmap?>(null) }
    var photoBusy by remember(accountKey) { mutableStateOf(false) }
    var photoError by remember(accountKey) { mutableStateOf<String?>(null) }
    var photoAccount by rememberSaveable(accountKey) { mutableStateOf<String?>(null) }
    LaunchedEffect(accountKey, state.snapshot.profilePhoto) {
        avatar = withContext(Dispatchers.IO) {
            ProfilePhotoCodec.decode(state.snapshot.profilePhoto)
        }
    }
    val onPhotoSelected: (android.net.Uri?) -> Unit = { uri ->
        val targetAccount = photoAccount
        photoAccount = null
        if (uri != null && targetAccount != null && targetAccount == accountKey) {
            scope.launch {
                photoBusy = true
                photoError = null // Icon
                try {
                    val encoded = withContext(Dispatchers.IO) {
                        ProfilePhotoCodec.encodeSelection(context.contentResolver, uri)
                    }
                    savePhoto(encoded, targetAccount)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    photoError = if (e is IllegalArgumentException) e.message else
                        "Не удалось сохранить фото. Попробуйте другое изображение."
                } finally {
                    photoBusy = false
                }
            }
        } //scope.launch
    }
    val photoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(), onPhotoSelected,
    )
    val fallbackPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.GetContent(), onPhotoSelected,
    )

    fun choosePhoto() {
        if (!photoBusy && accountKey != null) {
            photoAccount = accountKey
            photoError = null
            try {
                photoPicker.launch(
                    PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                )
            } catch (_: Exception) {
                try {
                    fallbackPicker.launch("image/*")
                } catch (e: Exception) {
                    photoAccount = null
                    photoError =
                        "Не удалось открыть выбор фото: ${e.javaClass.simpleName}: ${e.message.orEmpty()}"
                }
            }
        } // добавить фото
    }


    val profileListState = rememberLazyListState()
    var showGradebook by remember { mutableStateOf(false) }
    val grades = state.snapshot.grades?.value.orEmpty()
    val semesters = grades.map { it.semester }.distinct()
    // The gradebook opens on the current semester: the portal's active tab is always the last one.
    var semesterChosen by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(semesters) {
        if (semester.isNotEmpty() && semester !in semesters) semester = ""
        if (!semesterChosen && semesters.isNotEmpty()) { semester = semesters.last(); semesterChosen = true }
    }
    LazyColumn(
        state = profileListState,
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            val end =
                listOf(Color(0xFF138454), Color(0xFF484D5B), Color(0xFF1059C0), Color(0xFF9D233F))[
                    pref.cardStyle.coerceIn(0, 3)]
            StudentProfileCard(state.snapshot, end, openGradebook = {
                showGradebook = true
                expanded = true
                scope.launch {
                    withFrameNanos { } // The gradebook may just have become visible.
                    profileListState.animateScrollToItem(1)
                }
            }, front = {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(
                        "СТУДЕНЧЕСКИЙ",
                        color = Color.White.copy(alpha = .7f),
                        fontSize = 11.sp,
                        letterSpacing = 2.sp,
                    )
                    Text("ЭИОС", color = Color(0xFFFFBB5C), fontWeight = FontWeight.Black)
                }
                Spacer(Modifier.height(10.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier.size(88.dp).clip(CircleShape)
                            .background(Color.White.copy(alpha = .12f)),
                        contentAlignment = Alignment.Center
                    ) {
                        val photo = avatar
                        if (photo != null) Image(
                            photo.asImageBitmap(), "Фото профиля",
                            Modifier.fillMaxSize(), contentScale = ContentScale.Crop
                        )
                        else Icon(
                            Icons.Outlined.AccountCircle, "Фото профиля",
                            Modifier.size(44.dp), tint = Color.White
                        )
                    }
                    Text(
                        state.snapshot.profile?.name.orEmpty(),
                        Modifier.weight(1f).padding(start = 14.dp),
                        color = Color.White,
                        fontSize = 21.sp,
                        fontWeight = FontWeight.Bold,
                    )
                    if (photoBusy) CircularProgressIndicator(
                        Modifier.size(20.dp),
                        color = Color.White
                    )
                }
                if (state.snapshot.profilePhoto != null) TextButton(
                    enabled = !photoBusy,
                    onClick = {
                        val account = accountKey ?: return@TextButton
                        scope.launch {
                            photoBusy = true
                            photoError = null
                            try {
                                savePhoto(null, account)
                            } catch (e: CancellationException) {
                                throw e
                            } catch (_: Exception) {
                                photoError = "Не удалось удалить фото. Повторите попытку."
                            } finally {
                                photoBusy = false
                            }
                        }
                    },
                ) { Text("Удалить фото", color = Color.White.copy(alpha = .8f)) }
                photoError?.let {
                    Text(
                        it,
                        color = Color.White,
                        style = MaterialTheme.typography.bodySmall
                    )
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Студент УлГУ · Перевернуть", Modifier.weight(1f), color = Color.White.copy(alpha = .7f),
                        style = MaterialTheme.typography.bodySmall)
                    IconButton(enabled = !photoBusy, onClick = ::choosePhoto) {
                        Icon(Icons.Outlined.Edit, "Изменить фото", tint = Color.White)
                    }
                    IconButton(onClick = changeCard) {
                        Icon(Icons.Outlined.Palette, "Цвет карточки", tint = Color.White)
                    }
                }
            })
        }
        if (pref.showGradeBook || showGradebook) item {
            Row(
                Modifier.fillMaxWidth().clickable { expanded = !expanded },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Зачётная книжка",
                    Modifier.weight(1f),
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                )
                Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null)
            }
        }
        if ((pref.showGradeBook || showGradebook) && expanded) {
            item {
                OutlinedButton(
                    onClick = importGrades,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(14.dp),
                ) {
                    Text(
                        if (state.snapshot.grades == null) "Загрузить зачётку"
                        else "Обновить зачётку"
                    )
                }
                Updated(state.snapshot.grades?.fetchedAt)
                state.errors[PortalSection.GRADES]?.let { Hint(it) }
            }
            if (semesters.isNotEmpty())
                item {
                    Row(
                        Modifier.horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        (listOf("") + semesters).forEach { label ->
                            FilterChip(
                                semester == label,
                                { semester = label },
                                label = { Text(label.ifBlank { "Все семестры" }) },
                            )
                        }
                    }
                }
            if (grades.isEmpty())
                item { EmptyCard("Сохранённых оценок пока нет.", "Нажмите «Загрузить зачётку».") }
            items(
                grades.filter { semester.isBlank() || it.semester == semester },
                key = { it.id },
            ) {
                GradeCard(it)
            }
        }
        if (pref.showAssessments) item {
            SectionCard {
                Row(Modifier.fillMaxWidth().clickable { assessmentsExpanded = !assessmentsExpanded },
                    verticalAlignment = Alignment.CenterVertically) {
                    Text("Аттестация", Modifier.weight(1f), fontWeight = FontWeight.Bold)
                    Icon(if (assessmentsExpanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null)
                }
                // Source: «Текущая успеваемость» (CDO/academic_progress_inside.php), read by the parser.
                if (assessmentsExpanded) attestation()
            }
        }
    }
}
@Composable
private fun GradeCard(g: GradeItem) {
    val bad = g.grade.lowercase().let { it.contains("не зач") || it.contains("неуд") || it == "2" }
    val color = if (bad) Color(0xFFFF6174) else Color(0xFF35BA84)
    SectionCard {
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                Text(g.subject, fontWeight = FontWeight.SemiBold)
                Text(
                    g.teacher.ifBlank { "Преподаватель не указан на сайте" },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    listOf(g.type, g.date, g.semester)
                        .filter { it.isNotBlank() }
                        .joinToString(" · "),
                    style = MaterialTheme.typography.labelSmall,
                )
                g.retake
                    ?.takeIf { it.isNotBlank() }
                    ?.let { Text("Пересдача: $it", style = MaterialTheme.typography.labelSmall) }
            }
            Surface(color = color.copy(alpha = .15f), shape = RoundedCornerShape(10.dp)) {
                Text(
                    g.grade.ifBlank { "—" },
                    Modifier.padding(10.dp),
                    color = color,
                    fontWeight = FontWeight.Bold,
                    fontSize = 12.sp,
                )
            }
        }
    }
}
// план на семестр
@Composable
private fun ScheduleScreen(manual: ManualSchedule, state: PortalState, source: String, refresh: () -> Unit) {
    var selected by rememberSaveable { mutableStateOf(CampusDate.today().toString()) }
    val date = LocalDate.parse(selected)
    val context = LocalContext.current
    val window = ScheduleSource.window(state.snapshot, manual, source)
    // Whether the selected day comes from the group's plan (labels and hints below).
    val planned = ScheduleSource.isPlanned(selected, manual, source, state.snapshot)
    val portal = source != ScheduleSource.MANUAL
    val lessons = window?.items.orEmpty().filter { it.day == selected }
    val monday = date.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
    LazyColumn(
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
        modifier = Modifier.imePadding(),
    ) {
        item {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Расписание",
                    Modifier.weight(1f),
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                )
                TextButton(onClick = { selected = CampusDate.today().toString() }) {
                    Text("Сегодня")
                }
            }
            Hint(
                when {
                    source == ScheduleSource.AUTO && planned -> "Авто: план группы ${manual.plan.group} · ${manual.periodLabel}"
                    source == ScheduleSource.AUTO -> "Авто: вне плана группы — расписание из ЭИОС"
                    portal -> "Данные ЭИОС и сохранённая история"
                    else -> "План на семестр · ${manual.plan.group}"
                }
            )
            if (portal) OutlinedButton(
                onClick = refresh,
                enabled = !state.loading,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Обновить расписание из ЭИОС")
            }
        }
        item {
            SectionCard {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { selected = date.minusWeeks(1).toString() }) {
                        Icon(Icons.Outlined.ChevronLeft, "Предыдущая неделя")
                    }
                    Text(
                        date.format(
                            DateTimeFormatter.ofPattern("d MMMM yyyy", Locale.forLanguageTag("ru"))
                        ),
                        Modifier.weight(1f).clickable {
                            DatePickerDialog(
                                context,
                                { _, year, month, day ->
                                    selected = LocalDate.of(year, month + 1, day).toString()
                                },
                                date.year,
                                date.monthValue - 1,
                                date.dayOfMonth,
                            )
                                .show()
                        },
                        fontWeight = FontWeight.SemiBold,
                    )
                    IconButton(onClick = { selected = date.plusWeeks(1).toString() }) {
                        Icon(Icons.Outlined.ChevronRight, "Следующая неделя")
                    }
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    repeat(7) { index ->
                        val d = monday.plusDays(index.toLong())
                        val active = d == date
                        Column(
                            Modifier.weight(1f)
                                .background(
                                    if (active) MaterialTheme.colorScheme.primary
                                    else Color.Transparent,
                                    RoundedCornerShape(12.dp),
                                )
                                .clickable { selected = d.toString() }
                                .padding(vertical = 10.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Text(
                                listOf("ПН", "ВТ", "СР", "ЧТ", "ПТ", "СБ", "ВС")[index],
                                fontSize = 10.sp,
                                color =
                                    if (active) Color.White
                                    else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Text(
                                d.dayOfMonth.toString(),
                                fontWeight = FontWeight.Bold,
                                color =
                                    if (active) Color.White else MaterialTheme.colorScheme.onSurface,
                            )
                        }
                    }
                }
            }
        }
        item {
            if (planned)
                manual.weekNumber(date)?.let { Text("$it-я неделя", fontWeight = FontWeight.Bold) }
            window?.dayNotes?.get(selected)?.let { Hint(it) }
            if (portal) {
                Updated(state.snapshot.portalSchedule?.fetchedAt)
                state.errors[PortalSection.SCHEDULE]?.let { Hint(it) }
            }
        }
        if (lessons.isEmpty())
            item {
                EmptyCard(
                    if (selected in window?.days.orEmpty()) "В этот день пар нет"
                    else "На эту дату данных пока нет",
                    if (!planned) "Обновите данные или выберите другую дату."
                    else "План группы: ${manual.periodLabel}. Новый план можно загрузить в настройках.",
                )
            } // lesson.timeStart.ifBlank
        items(lessons, key = { it.id }) { lesson ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Column(
                    Modifier.widthIn(min = 68.dp).padding(top = 12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    lesson.lessonNumber?.let {
                        Text(
                            "$it-я пара",
                            fontSize = 10.sp,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Text(
                        lesson.timeStart.ifBlank { "—" },
                        fontWeight = FontWeight.Bold,
                        fontSize = 14.sp,
                        softWrap = false,
                        maxLines = 1,
                    )
                    Text(
                        lesson.timeEnd.ifBlank { "уточн." },
                        softWrap = false,
                        maxLines = 1,
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                SectionCard(Modifier.weight(1f)) {
                    Text(
                        lesson.type.ifBlank { "Вид занятия не указан" }.uppercase(),
                        color =
                            if (lesson.type.contains("Лаб", true)) MaterialTheme.colorScheme.primary
                            else Color(0xFF35BA84),
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                    )
                    Text(lesson.subject, fontWeight = FontWeight.SemiBold)
                    if (lesson.requiresConfirmation) Hint("Требует уточнения")
                    Text(
                        lesson.teacher.ifBlank { "Преподаватель уточняется" },
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Text(
                        lesson.place.ifBlank { "Место уточняется" },
                        style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
        }
    }
}

@Composable
internal fun CoursesScreen(state: PortalState, load: () -> Unit, choose: (Course) -> Unit,
    listState: LazyListState = rememberLazyListState()) {
    LazyColumn(
        state = listState,
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Text(
                "Мои курсы",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
            )
            Hint("Материалы и тесты ЭИОС внутри приложения.")
            OutlinedButton(onClick = load, modifier = Modifier.fillMaxWidth()) {
                Text("Загрузить карточки курсов")
            }
            Updated(state.snapshot.courses?.fetchedAt)
            state.errors[PortalSection.COURSES]?.let { Hint(it) }
        }
        if (state.snapshot.courses?.value.isNullOrEmpty())
            item { EmptyCard("Курсы ещё не загружены", "Нажмите кнопку загрузки выше.") }
        items(state.snapshot.courses?.value.orEmpty(), key = { it.id }) { course ->
            SectionCard(Modifier.clickable { choose(course) }) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Surface(
                        color = MaterialTheme.colorScheme.primary.copy(alpha = .15f),
                        shape = RoundedCornerShape(14.dp),
                    ) {
                        Icon(
                            Icons.AutoMirrored.Outlined.MenuBook,
                            null,
                            Modifier.padding(14.dp),
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    }
                    val title = CourseTitle(course.title)
                    Column(Modifier.weight(1f)) {
                        Text(title.subject, fontWeight = FontWeight.SemiBold)
                        if (title.detailLine.isNotBlank()) Hint(title.detailLine)
                    }
                    Icon(
                        Icons.Outlined.ChevronRight,
                        null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun InboxScreen(state: PortalState, load: () -> Unit, close: () -> Unit) {
    LazyColumn(
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            TextButton(onClick = close) { Text("Назад") }
            Text(
                "Уведомления",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
            )
            OutlinedButton(onClick = load, modifier = Modifier.fillMaxWidth()) {
                Text("Загрузить уведомления")
            }
            Updated(state.snapshot.notifications?.fetchedAt)
            state.errors[PortalSection.NOTIFICATIONS]?.let { Hint(it) }
        }
        if (state.snapshot.notifications?.value.isNullOrEmpty())
            item { EmptyCard("Сохранённых уведомлений пока нет", "Загрузите их из ЭИОС.") }
        items(state.snapshot.notifications?.value.orEmpty(), key = { it.id }) { item ->
            SectionCard {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (item.isUnread)
                        Box(
                            Modifier.size(7.dp)
                                .background(MaterialTheme.colorScheme.primary, CircleShape)
                        )
                    Text(
                        item.sourceTimeLabel,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Text(item.message, style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

@Composable
private fun SettingsScreen(
    pref: UiPreferences,
    unlocked: Boolean,
    onUpdate: (UiPreferences) -> Unit,
    onLock: (Boolean) -> Unit,
    onAutoRefresh: (Boolean) -> Unit,
    onNotifications: (Boolean) -> Unit,
    notificationsAllowed: Boolean,
    onSystemNotifications: () -> Unit,
    onNotes: () -> Unit,
    onLogin: () -> Unit,
    onLogout: () -> Unit,
) {
    var confirm by remember { mutableStateOf(false) }
    LazyColumn(
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Text(
                "Настройки",
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
            )
        }
        item {
            SectionCard(Modifier.clickable(onClick = onNotes)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Outlined.EditNote, null, Modifier.padding(end = 12.dp))
                    Text("Заметки", Modifier.weight(1f), fontWeight = FontWeight.Bold)
                    Icon(Icons.Outlined.ChevronRight, null)
                }
            }
        }
        item {
            SectionCard {
                Text("Внешний вид", fontWeight = FontWeight.Bold)
                SettingSwitch("Зачетная книжка в профиле", pref.showGradeBook) {
                    onUpdate(pref.copy(showGradeBook = it))
                }
                SettingSwitch("Аттестация в профиле", pref.showAssessments) {
                    onUpdate(pref.copy(showAssessments = it))
                }
                SettingSwitch("Тёмная тема", pref.dark) { onUpdate(pref.copy(dark = it)) }
                SettingSwitch("Новогоднее оформление", pref.christmas) {
                    onUpdate(pref.copy(christmas = it))
                }
            }
        }
        item {
            SectionCard {
                Text("Данные и обновления", fontWeight = FontWeight.Bold)
                SettingSwitch("Автообновление", pref.autoRefresh, onAutoRefresh)
                Hint(
                    "Запрос через случайные 30–60 минут. Android может откладывать фоновые задачи."
                )
                SchedulePlanSettings(pref) { onUpdate(pref.copy(scheduleSource = it)) }
                SettingSwitch("Уведомления на устройстве", pref.notifications, onNotifications)
                if (pref.notifications) {
                    SettingSwitch("Сообщения и объявления ЭИОС", pref.eiosNotifications) {
                        onUpdate(pref.copy(eiosNotifications = it))
                    }
                    SettingSwitch("Изменения расписания ЭИОС", pref.scheduleNotifications) {
                        onUpdate(pref.copy(scheduleNotifications = it))
                    }
                    SettingSwitch("Дедлайны тестов и заданий", pref.deadlineNotifications) {
                        onUpdate(pref.copy(deadlineNotifications = it))
                    }
                }
                Hint("Появляются после обновления, в том числе при открытом приложении. " +
                    "Расписание проверяется при включённом источнике ЭИОС. Серверные push не подключены.")
                if (!notificationsAllowed)
                    Hint("Системные уведомления отключены. Разрешите их в настройках Android, затем включите здесь.")
                TextButton(onClick = onSystemNotifications) { Text("Настройки уведомлений Android") }
            }
        }
        item {
            SectionCard {
                Text("Безопасность", fontWeight = FontWeight.Bold)
                SettingSwitch("Биометрия / код устройства", pref.appLock, onLock)
                TextButton(onClick = onLogin) { Text("Войти в ЭИОС снова") }
                TextButton(onClick = { confirm = true }) {
                    Text("Выйти и удалить данные аккаунта", color = MaterialTheme.colorScheme.error)
                }
            }
        }
        item { AppUpdateCard() }
        item { Hint("SmartTimetable для Android · ${appVersion(LocalContext.current)}\nАвтор проекта — Антон Борисов") }
    }
    if (confirm && unlocked)
        AlertDialog(
            onDismissRequest = { confirm = false },
            title = { Text("Выйти из аккаунта?") },
            text = {
                Text(
                    "Сессия, оценки, уведомления и личные заметки будут удалены с этого устройства."
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirm = false
                        onLogout()
                    }
                ) {
                    Text("Выйти")
                }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text("Отмена") } },
        )
}

@Composable
private fun SettingSwitch(text: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(text, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Switch(checked, onChange)
    }
}

@Composable
internal fun SectionCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.surface,
    ) {
        Column(
            Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            content = content,
        )
    }
}

@Composable
internal fun Hint(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        modifier.padding(vertical = 4.dp),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
internal fun EmptyCard(title: String, subtitle: String) {
    SectionCard {
        Text(title, fontWeight = FontWeight.SemiBold)
        Hint(subtitle)
    }
}

@Composable
internal fun Updated(time: Long?) {
    if (time != null)
        Hint(
            "Обновлено: " +
                    Instant.ofEpochMilli(time)
                        .atZone(CampusDate.zone)
                        .format(
                            DateTimeFormatter.ofPattern("d MMM, HH:mm", Locale.forLanguageTag("ru"))
                        )
        )
}

/** Schedule source (Auto / plan / portal) and the semester plan file: import, save as template, reset. */
@Composable
private fun SchedulePlanSettings(pref: UiPreferences, choose: (String) -> Unit) {
    val context = LocalContext.current
    val repo = (context.applicationContext as SmartTableApplication).repository
    val manual by repo.manualScheduleState.collectAsState()
    var message by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            message = withContext(Dispatchers.IO) {
                runCatching {
                    val json = context.contentResolver.openInputStream(uri)!!.bufferedReader().use { it.readText() }
                    val plan = repo.importPlan(json)
                    "Загружен план ${plan.group}: ${plan.firstDay} — ${plan.lastDay}."
                }.getOrElse { "Файл не принят: ${it.message ?: "неверный формат"}. Текущий план не изменён." }
            }
        }
    }
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch(Dispatchers.IO) {
            runCatching { context.contentResolver.openOutputStream(uri)!!.use { it.write(repo.currentPlanJson().toByteArray()) } }
        }
    }
    Text("Источник расписания", fontWeight = FontWeight.SemiBold)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        listOf(ScheduleSource.AUTO to "Авто", ScheduleSource.MANUAL to "План группы", ScheduleSource.PORTAL to "Из ЭИОС")
            .forEach { (value, label) ->
                FilterChip(selected = pref.scheduleSource == value, onClick = { choose(value) }, label = { Text(label) })
            }
    }
    Hint("«Авто»: пока идёт план группы — он, после его окончания — расписание из ЭИОС. Новый семестр не требует переустановки.")
    Hint("План группы: ${manual.plan.group} · ${manual.periodLabel}")
    TextButton(onClick = { importer.launch(arrayOf("application/json", "text/plain", "application/octet-stream")) }) {
        Text("Загрузить план нового семестра…")
    }
    TextButton(onClick = { exporter.launch("manual_schedule.json") }) { Text("Сохранить текущий план (шаблон)") }
    if (repo.planImported)
        TextButton(onClick = { repo.resetPlan(); message = "Встроенный план восстановлен." }) { Text("Вернуть встроенный план") }
    message?.let { Hint(it) }
}

internal fun appVersion(context: Context): String =
    runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "0"

private fun openLink(context: Context, url: String) {
    runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
}

/** Twice a day at most: asks GitHub Releases whether a newer Android build exists. */
@Composable
private fun AppUpdatePrompt(locked: Boolean) {
    val context = LocalContext.current
    var release by remember { mutableStateOf<AppRelease?>(null) }
    LaunchedEffect(Unit) {
        val prefs = context.getSharedPreferences("app_updates", Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        if (now - prefs.getLong("lastCheck", 0) < 12 * 3_600_000L) return@LaunchedEffect
        prefs.edit().putLong("lastCheck", now).apply()
        val latest = AppUpdates.fetchLatest() ?: return@LaunchedEffect
        if (AppUpdates.isNewer(latest.version, appVersion(context)) && prefs.getString("dismissed", null) != latest.version)
            release = latest
    }
    val update = release
    if (update != null && !locked)
        AlertDialog(
            onDismissRequest = { release = null },
            title = { Text("Доступна версия ${update.version}") },
            text = {
                Text(
                    (update.notes.takeIf { it.isNotBlank() }?.let { it + "\n\n" } ?: "") +
                        "Скачайте APK и установите его поверх текущей версии: вход и данные сохранятся."
                )
            },
            confirmButton = {
                TextButton(onClick = { openLink(context, update.apkUrl ?: update.pageUrl); release = null }) { Text("Скачать") }
            },
            dismissButton = {
                TextButton(onClick = {
                    context.getSharedPreferences("app_updates", Context.MODE_PRIVATE).edit()
                        .putString("dismissed", update.version).apply()
                    release = null
                }) { Text("Позже") }
            },
        )
}

/** Settings: the installed version and a manual check. */
@Composable
private fun AppUpdateCard() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var status by remember { mutableStateOf<String?>(null) }
    var release by remember { mutableStateOf<AppRelease?>(null) }
    var checking by remember { mutableStateOf(false) }
    SectionCard {
        Text("Обновления приложения", fontWeight = FontWeight.Bold)
        Hint("Установлена версия ${appVersion(context)}. Новые версии выходят на GitHub.")
        status?.let { Hint(it) }
        val found = release
        if (found != null)
            TextButton(onClick = { openLink(context, found.apkUrl ?: found.pageUrl) }) { Text("Скачать ${found.version}") }
        else
            TextButton(enabled = !checking, onClick = {
                checking = true
                scope.launch {
                    val latest = AppUpdates.fetchLatest()
                    checking = false
                    when {
                        latest == null -> status = "Не удалось проверить: нет связи с GitHub."
                        AppUpdates.isNewer(latest.version, appVersion(context)) -> {
                            release = latest
                            status = "Доступна версия ${latest.version}."
                        }
                        else -> status = "У вас последняя версия."
                    }
                }
            }) { Text(if (checking) "Проверяем…" else "Проверить обновления") }
        TextButton(onClick = { openLink(context, AppUpdates.RELEASES_PAGE) }) { Text("Все версии на GitHub") }
    }
}
