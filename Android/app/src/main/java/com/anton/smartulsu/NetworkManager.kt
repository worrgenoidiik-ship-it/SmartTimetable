package com.anton.smartulsu

import android.content.Context
import android.webkit.CookieManager
import android.webkit.WebSettings
import com.anton.smartulsu.core.*
import com.anton.smartulsu.data.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import com.anton.smartulsu.ui.Messenger

/** Shared repository. Browser leases prevent a background refresh from disturbing a test/MAX. */
class NetworkManager internal constructor(
    context: Context,
    private val cookies: CookieManager,
    private val pageLoader: (suspend (String) -> PortalPage)? = null,
    private val cancelRefresh: suspend () -> Unit = { RefreshScheduler.cancel(context.applicationContext) },
    private val clearNotification: () -> Unit = {
        PortalNotifier.cancel(context.applicationContext)
    },
    private val publishEvents: (List<PortalEvent>) -> Unit = {},
    private val restoreSnapshot: (() -> PortalSnapshot)? = null,
    private val cache: CacheStore = CacheStore(context),
    private val client: PortalClient = PortalClient(cookies, WebSettings.getDefaultUserAgent(context)),
) {
    constructor(context: Context) : this(
        context,
        CookieManager.getInstance().apply { setAcceptCookie(true) },
        publishEvents = { events ->
            (context.applicationContext as? SmartTableApplication)?.let { app ->
                PortalNotifier.publish(app, events, app.preferences.state.value)
            }
        },
    )
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val gate = Mutex()
    private val mutable = MutableStateFlow(PortalState())
    val state = mutable.asStateFlow()
    // Built-in plan from assets; a plan imported in Settings replaces it without an app update.
    private val builtInPlan = context.assets.open("manual_schedule.json").bufferedReader().use { it.readText() }
    private val planFile = java.io.File(context.filesDir, "manual_plan.json")
    private val manualMutable = MutableStateFlow(
        runCatching { if (planFile.exists()) ManualSchedule(planFile.readText()) else null }.getOrNull()
            ?: ManualSchedule(builtInPlan)
    )
    val manualScheduleState = manualMutable.asStateFlow()
    val manualSchedule: ManualSchedule get() = manualMutable.value
    val planImported: Boolean get() = planFile.exists()

    /** Validates first; a wrong file leaves the current plan untouched. */
    fun importPlan(json: String): ManualPlan {
        val schedule = ManualSchedule(json)
        val temp = java.io.File(planFile.parentFile, planFile.name + ".tmp")
        temp.writeText(json)
        if (!temp.renameTo(planFile)) { planFile.delete(); temp.renameTo(planFile) }
        manualMutable.value = schedule
        return schedule.plan
    }

    fun resetPlan() {
        planFile.delete()
        manualMutable.value = ManualSchedule(builtInPlan)
    }

    fun currentPlanJson(): String =
        if (planFile.exists()) planFile.readText() else builtInPlan
    private var generation = 0L
    private var accountGeneration = 0L
    private var browserOpen = false
    private val logoutTaskLock = Any()
    private var logoutTask: Deferred<Boolean>? = null
    private val logoutPendingMutable = MutableStateFlow(false)
    val logoutPending = logoutPendingMutable.asStateFlow()

    private val logoutRunningMutable = MutableStateFlow(false)
    val logoutRunning = logoutRunningMutable.asStateFlow()

    private val cookieRemoval = CookieRemovalAwaiter()
    private val notes: NoteDrafts = NoteDrafts(scope, write = ::persistNoteDraft)
    val noteDraft = notes.state

    private val initialized =
        scope.async {
            gate.withLock {
                try {
                    val pending = try {
                        cache.hasPendingLogout()
                    } catch (_: Exception) {
                        true
                    }

                    val restored =
                        if (pending || logoutPendingMutable.value) PortalSnapshot()
                        else restoreSnapshot?.invoke() ?: cache.load()

                    synchronized(logoutTaskLock) {
                        if (pending) logoutPendingMutable.value = true

                        mutable.value = PortalState(
                            snapshot =
                                if (logoutPendingMutable.value) PortalSnapshot()
                                else restored,
                            ready = true,
                            message =
                                if (logoutPendingMutable.value)
                                    "Выход был прерван. Повторите очистку перед входом в другой аккаунт."
                                else null,
                        )
                    }
                    notes.activate(currentRefreshSession())
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    mutable.value =
                        PortalState(
                            ready = true,
                            message =
                                "Не удалось прочитать сохранённые данные. Войдите для повторной загрузки.",
                        )
                }
            }
        }


    suspend fun prepare() {
        initialized.await()
    }

    private fun commit(snapshot: PortalSnapshot) {
        if (logoutPendingMutable.value)
            throw CancellationException("Logout is pending.")
        cache.save(snapshot)
        synchronized(logoutTaskLock) {
            if (logoutPendingMutable.value)
                throw CancellationException("Logout is pending.")
            mutable.value = state.value.copy(snapshot = snapshot)
        }
    }

    private suspend fun getPage(url: String): PortalPage =
        (pageLoader?.invoke(url) ?: client.get(url)).also { page ->
            PortalPagesParser.sesskey(page.html)?.let { sesskey = it }
            PortalExtrasParser.moodleUserId(page.html)?.let { moodleUserId = it }
        }

    // ---- Moodle web services: messenger, timeline, forms (iOS 1.5–1.7 port) ----

    @Volatile private var moodleUserId: Int? = null

    private suspend fun callAjax(method: String, args: com.google.gson.JsonObject): com.google.gson.JsonElement {
        val key = sesskey ?: throw PortalFailure.LoginRequired()
        val request = com.google.gson.JsonArray().apply {
            add(com.google.gson.JsonObject().apply { addProperty("index", 0); addProperty("methodname", method); add("args", args) })
        }
        return PortalExtrasParser.ajaxResult(
            client.postJson("${PortalConfiguration.BASE}/lib/ajax/service.php?sesskey=$key&info=$method", request.toString()))
    }

    private suspend fun verifiedPage(url: String): PortalPage {
        val account = state.value.snapshot.profile?.accountKey ?: throw PortalFailure.LoginRequired()
        val page = getPage(url)
        if (PortalParser.authenticatedProfile(page.html, page.url).accountKey != account) throw PortalFailure.LoginRequired()
        return page
    }

    /** A rejected session/sesskey means nothing was done: one protected page refreshes both, then one more call. */
    suspend fun ajax(method: String, args: com.google.gson.JsonObject): com.google.gson.JsonElement = withContext(Dispatchers.IO) {
        prepare()
        if (state.value.snapshot.profile == null || logoutRunningMutable.value || logoutPendingMutable.value)
            throw PortalFailure.LoginRequired()
        try {
            callAjax(method, args)
        } catch (e: PortalFailure.LoginRequired) {
            verifiedPage(PortalConfiguration.GRADES)
            callAjax(method, args)
        }
    }

    suspend fun userId(): Int = withContext(Dispatchers.IO) {
        moodleUserId ?: run { verifiedPage(PortalConfiguration.GRADES); moodleUserId } ?: throw PortalFailure.Parse("идентификатор пользователя")
    }

    suspend fun questionForm(): QuestionForm = withContext(Dispatchers.IO) {
        PortalExtrasParser.questionForm(verifiedPage(PortalConfiguration.QUESTION).html)
    }

    /** Same request as the site's «Отправить» button; never retried. */
    suspend fun sendQuestion(category: String, subject: String, message: String, email: String) = withContext(Dispatchers.IO) {
        fun e(v: String) = java.net.URLEncoder.encode(v, "UTF-8")
        val page = client.get("${PortalConfiguration.BASE}/CDO/lib.php?API=sendQ&subject=${e(subject)}&message=${e(message)}" +
            "&reply_type=${e(email)}&message_type=${e(category)}")
        val answer = page.html.trim()
        if (answer.isEmpty() || answer == "0" || answer.equals("false", true)) throw PortalFailure.Parse("ответ на отправку вопроса")
    }

    suspend fun loadForms(url: String): Pair<List<PortalForm>, PortalPage> = withContext(Dispatchers.IO) {
        val page = verifiedPage(url)
        PortalExtrasParser.forms(page.html, page.url) to page
    }

    suspend fun openForm(form: PortalForm, values: Map<String, String>): Pair<List<PortalForm>, PortalPage> = withContext(Dispatchers.IO) {
        fun e(v: String) = java.net.URLEncoder.encode(v, "UTF-8")
        val query = form.payload(values).joinToString("&") { (k, v) -> e(k) + "=" + e(v) }
        val page = verifiedPage(form.action + (if ('?' in form.action) "&" else "?") + query)
        PortalExtrasParser.forms(page.html, page.url) to page
    }

    suspend fun submitForm(form: PortalForm, values: Map<String, String>): PortalPage = withContext(Dispatchers.IO) {
        if (!form.isPost) throw PortalFailure.UnsafeURL()
        val account = state.value.snapshot.profile?.accountKey ?: throw PortalFailure.LoginRequired()
        val page = client.postForm(form.action, form.payload(values))
        if (PortalParser.authenticatedProfile(page.html, page.url).accountKey != account) throw PortalFailure.LoginRequired()
        page
    }

    // ---- Quiz (iOS 1.8 port) ----

    suspend fun quizPage(url: String): QuizContent = withContext(Dispatchers.IO) {
        val page = verifiedPage(url)
        QuizParser.parse(page.html, page.url)
    }

    /** Only the quiz's own endpoints, only on an explicit tap (or the timer, as the site's script does). */
    suspend fun quizSubmit(url: String, items: List<Pair<String, String>>): QuizContent = withContext(Dispatchers.IO) {
        val path = PortalConfiguration.path(url)
        if (path != "/mod/quiz/processattempt.php" && path != "/mod/quiz/startattempt.php") throw PortalFailure.UnsafeURL()
        val account = state.value.snapshot.profile?.accountKey ?: throw PortalFailure.LoginRequired()
        val page = client.postForm(url, items)
        if (PortalParser.authenticatedProfile(page.html, page.url).accountKey != account) throw PortalFailure.LoginRequired()
        QuizParser.parse(page.html, page.url)
    }

    private suspend fun overdueViaTimeline(): List<DeadlineItem> {
        val now = System.currentTimeMillis()
        return PortalExtrasParser.actionEvents(ajax("core_calendar_get_action_events_by_timesort", com.google.gson.JsonObject().apply {
            addProperty("timesortfrom", now / 1000 - 183L * 86_400)
            addProperty("timesortto", now / 1000)
            addProperty("limittononsuspendedevents", true)
            addProperty("limitnum", 50)
        })).filter { (it.due ?: Long.MAX_VALUE) <= now }.sortedByDescending { it.due ?: 0 }
    }

    /** The portal has no «upcoming events» page; the timeline block's service has the data. */
    private suspend fun deadlinesViaTimeline(): List<DeadlineItem> =
        PortalExtrasParser.actionEvents(ajax("core_calendar_get_action_events_by_timesort", com.google.gson.JsonObject().apply {
            addProperty("timesortfrom", System.currentTimeMillis() / 1000 - 86_400)
            addProperty("limittononsuspendedevents", true)
            addProperty("limitnum", 50)
        }))

    // ---- Long-lived session (iOS 1.3 port) ----

    /** Moodle CSRF token of the current session, from the last loaded page. */
    @Volatile private var sesskey: String? = null
    private val sessionPreferences = context.getSharedPreferences("session", Context.MODE_PRIVATE)
    val credentials = CredentialStore(context)

    /** A third of the server's idle timeout (reported by Moodle), 5 min – 6 h; 15 min until known. */
    val keepAliveIntervalMs: Long
        get() {
            val timeout = sessionPreferences.getLong("serverTimeoutSec", 0)
            return if (timeout > 0) (timeout * 1000 / 3).coerceIn(5 * 60_000L, 6 * 3_600_000L) else 15 * 60_000L
        }
    val lastServerContact: Long get() = sessionPreferences.getLong("lastContact", 0)
    val serverTimeoutSec: Long get() = sessionPreferences.getLong("serverTimeoutSec", 0)
    private fun markContact() = sessionPreferences.edit().putLong("lastContact", System.currentTimeMillis()).apply()

    suspend fun keepAliveIfNeeded(withinMs: Long = keepAliveIntervalMs): Boolean =
        if (System.currentTimeMillis() - lastServerContact < withinMs) true else keepAlive()

    private suspend fun touch(): Long? {
        val key = sesskey ?: throw PortalFailure.LoginRequired()
        val url = "${PortalConfiguration.BASE}/lib/ajax/service.php?sesskey=$key" +
            "&info=core_session_touch,core_session_time_remaining"
        return PortalPagesParser.sessionTouchResult(client.postJson(url, TOUCH_BODY))
    }

    /**
     * One light request that resets Moodle's idle timer. Falls back to a page load (which also
     * extends the session) when there is no sesskey yet or the touch is refused. Same rules as
     * [refresh]: never while a test/login browser is open or a logout runs.
     */
    suspend fun keepAlive(): Boolean = withContext(Dispatchers.IO) {
        prepare()
        if (!gate.tryLock()) return@withContext false
        try {
            val account = state.value.snapshot.profile?.accountKey
            if (browserOpen || logoutRunningMutable.value || logoutPendingMutable.value || account == null ||
                state.value.session == SessionState.NEEDS_LOGIN)
                return@withContext false
            val remaining = try {
                touch()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                val page = getPage(PortalConfiguration.GRADES)
                if (PortalParser.authenticatedProfile(page.html, page.url).accountKey != account)
                    throw PortalFailure.LoginRequired()
                try { touch() } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
            }
            // Right after a touch the remaining time equals the full server timeout.
            remaining?.let { sessionPreferences.edit().putLong("serverTimeoutSec", it).apply() }
            markContact()
            runCatching { cookies.flush() }
            mutable.value = state.value.copy(session = SessionState.ACTIVE)
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            mutable.value = when (e) {
                is PortalFailure.LoginRequired -> state.value.copy(session = SessionState.NEEDS_LOGIN)
                is java.io.IOException -> if (e is PortalFailure) state.value else state.value.copy(session = SessionState.OFFLINE)
                else -> state.value
            }
            false
        } finally {
            gate.unlock()
        }
    }

    private fun friendly(e: Exception) = PortalErrors.message(e)

    private fun sectionError(section: PortalSection, e: Exception) {
        val message =
            if (
                section == PortalSection.GRADES &&
                    state.value.snapshot.grades == null &&
                    e is PortalFailure.Parse
            )
                "Оценки ещё не загружены. Нажмите «Загрузить зачётку»."
            else PortalErrors.sectionMessage(section, e)
        mutable.value =
            state.value.copy(
                errors = state.value.errors + (section to message),
                session =
                    if (e is PortalFailure.LoginRequired) SessionState.NEEDS_LOGIN
                    else state.value.session,
            )
    }
    suspend fun refresh(force: Boolean = false) =
        withContext(Dispatchers.IO) {
            prepare()
            if (!gate.tryLock()) return@withContext
            try {
                val before = state.value.snapshot
                if (
                    browserOpen || logoutRunningMutable.value || logoutPendingMutable.value ||
                        before.profile == null ||
                        (!force && System.currentTimeMillis() < before.nextRefreshAt)
                )
                    return@withContext
                mutable.value = state.value.copy(loading = true, message = null)
                val probe = getPage(PortalConfiguration.GRADES)
                val profile = PortalParser.authenticatedProfile(probe.html, probe.url)
                if (profile.accountKey != before.profile.accountKey)
                    throw PortalFailure.LoginRequired()
                markContact()
                mutable.value = state.value.copy(session = SessionState.ACTIVE)
                for (section in PortalSection.entries) {
                    currentCoroutineContext().ensureActive()
                    if (section == PortalSection.DEADLINES) {
                        val timeline = try { deadlinesViaTimeline() } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
                        // Overdue work: same service for the last half year up to now; submitted items are gone.
                        val overdue = try { overdueViaTimeline() } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
                        if (overdue != null) commit(state.value.snapshot.copy(overdue = CachedSection(overdue)))
                        if (timeline != null) {
                            commit(state.value.snapshot.copy(deadlines = CachedSection(timeline)))
                            mutable.value = state.value.copy(errors = state.value.errors - section)
                            continue
                        }
                    }
                    try {
                        val page =
                            if (section == PortalSection.GRADES) probe else getPage(section.url)
                        if (
                            section != PortalSection.SCHEDULE &&
                                PortalParser.authenticatedProfile(page.html, page.url).accountKey !=
                                    profile.accountKey
                        )
                            throw PortalFailure.LoginRequired()
                        importPage(section, page.html, page.url)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        sectionError(section, e)
                        if (e is PortalFailure.LoginRequired) break
                    }
                }
                commit(
                    state.value.snapshot.copy(
                        nextRefreshAt =
                            System.currentTimeMillis() + PortalConfiguration.randomRefreshDelay()
                    )
                )
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutable.value =
                    state.value.copy(
                        session =
                            if (e is PortalFailure.LoginRequired) SessionState.NEEDS_LOGIN
                            else SessionState.OFFLINE,
                        message = friendly(e),
                    )
                runCatching {
                    commit(
                        state.value.snapshot.copy(
                            nextRefreshAt =
                                System.currentTimeMillis() +
                                    if (e is PortalFailure.LoginRequired)
                                        PortalConfiguration.randomRefreshDelay()
                                    else 60_000L
                        )
                    )
                }
            } finally {
                mutable.value = state.value.copy(loading = false)
                gate.unlock()
            }
        }

    private suspend fun importPage(section: PortalSection, html: String, source: String) {
        if (
            !PortalConfiguration.allowsDataURL(source) ||
                PortalConfiguration.path(source) != PortalConfiguration.path(section.url)
        )
            throw PortalFailure.UnsafeURL()
        // The dashboard also carries the news block; keep it even if the course cards fail to parse.
        if (section == PortalSection.COURSES)
            runCatching { PortalPagesParser.news(html, source) }.getOrNull()
                ?.let { commit(state.value.snapshot.copy(news = CachedSection(it))) }
        val old = state.value.snapshot
        val observedNotifications = if (section == PortalSection.NOTIFICATIONS)
            PortalParser.notifications(html, source) else null
        val next =
            when (section) {
                PortalSection.GRADES ->
                    old.copy(grades = CachedSection(PortalParser.academicProgress(html, source)))
                PortalSection.COURSES ->
                    old.copy(
                        courses =
                            CachedSection(
                                PortalParser.mergeCourses(
                                    PortalParser.courses(html, source),
                                    old.courses?.value.orEmpty(),
                                )
                            )
                    )
                PortalSection.NOTIFICATIONS ->
                    old.copy(
                        notifications =
                            CachedSection(
                                PortalParser.mergeNotifications(
                                    observedNotifications!!,
                                    old.notifications?.value.orEmpty(),
                                )
                            )
                    )
                PortalSection.ATTESTATION -> old.withPage(PortalPageKind.ATTESTATION, PortalPagesParser.document(html, source))
                PortalSection.DEBTS -> old.withPage(PortalPageKind.DEBTS, PortalPagesParser.document(html, source))
                PortalSection.DEADLINES -> old.copy(deadlines = CachedSection(PortalPagesParser.deadlines(html, source)))
                PortalSection.SCHEDULE ->
                    old.copy(
                        portalSchedule =
                            CachedSection(
                                PortalParser.preserveScheduleHistory(
                                    PortalParser.parseAjaxSchedule(html, source),
                                    old.portalSchedule?.value,
                                )
                            )
                    )
            }
        currentCoroutineContext().ensureActive()
        commit(next) // Persist the new baseline before publishing; restart must not replay it.
        currentCoroutineContext().ensureActive()
        synchronized(logoutTaskLock) {
            if (!logoutPendingMutable.value && state.value.snapshot === next) {
                val eventSnapshot = if (observedNotifications != null)
                    next.copy(notifications = CachedSection(observedNotifications)) else next
                val events = PortalEvents.detect(old, eventSnapshot, section)
                if (events.isNotEmpty()) runCatching { publishEvents(events) }
            }
        }
        mutable.value = state.value.copy(errors = state.value.errors - section)
    }

    private fun PortalSnapshot.withPage(kind: PortalPageKind, document: PortalDocument) =
        copy(pages = pages.orEmpty() + (kind.name to CachedSection(document)))

    // ---- Pages loaded on demand (iOS 1.1 port) ----

    suspend fun loadPage(kind: PortalPageKind) =
        loadExtra(kind.key, kind.url) { html, url ->
            val document = PortalPagesParser.document(html, url)
            ({ snapshot: PortalSnapshot -> snapshot.withPage(kind, document) })
        }

    suspend fun loadCourseContents(course: Course) =
        loadExtra("course.${course.id}", CourseNavigation.destination(course)) { html, url ->
            val sections = PortalPagesParser.courseContents(html, url)
            ({ snapshot: PortalSnapshot ->
                snapshot.copy(courseContents = snapshot.courseContents.orEmpty() + (course.id to CachedSection(sections)))
            })
        }

    /** Same rules as [refresh]: never while a test/login browser is open or a logout runs. */
    private suspend fun loadExtra(
        key: String,
        url: String,
        parse: (String, String) -> (PortalSnapshot) -> PortalSnapshot,
    ) = withContext(Dispatchers.IO) {
        prepare()
        if (!gate.tryLock()) return@withContext
        try {
            val before = state.value.snapshot
            val account = before.profile?.accountKey
            if (browserOpen || logoutRunningMutable.value || logoutPendingMutable.value || account == null)
                return@withContext
            mutable.value = state.value.copy(extraLoading = state.value.extraLoading + key)
            val page = getPage(url)
            if (PortalParser.authenticatedProfile(page.html, page.url).accountKey != account)
                throw PortalFailure.LoginRequired()
            val apply = parse(page.html, page.url)
            currentCoroutineContext().ensureActive()
            commit(apply(state.value.snapshot))
            mutable.value = state.value.copy(extraErrors = state.value.extraErrors - key)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            mutable.value = state.value.copy(
                extraErrors = state.value.extraErrors + (key to friendly(e)),
                session = if (e is PortalFailure.LoginRequired) SessionState.NEEDS_LOGIN else state.value.session,
            )
        } finally {
            mutable.value = state.value.copy(extraLoading = state.value.extraLoading - key)
            gate.unlock()
        }
    }

    data class BrowserLease(val generation: Long, val account: String?)

    suspend fun browserWillOpen(): BrowserLease {
        prepare()
        // Cookie flushing holds the client's lock. Await cancellation off Main before
        // acquiring the lease; acquisition itself must not cross a dispatcher boundary.
        withContext(Dispatchers.IO) { client.cancelAll() }
        return gate.withLock {
            check(!logoutPendingMutable.value && !logoutRunningMutable.value) {
                "Выход не завершён. Повторите очистку перед входом."
            }
            check(!browserOpen) {
                "Уже открыта страница ЭИОС"
            }
            browserOpen = true
            generation++
            BrowserLease(generation, state.value.snapshot.profile?.accountKey)
        }
    }


    suspend fun browserDidClose(lease: BrowserLease) =
        withContext(Dispatchers.IO) {
            gate.withLock {
                if (lease.generation == generation && browserOpen) {
                    try {
                        cookies.flush()
                    } catch (_: Exception) {
                        mutable.value = state.value.copy(
                            message = "Не удалось подтвердить сохранение сессии ЭИОС. Возможно, потребуется повторный вход."
                        )
                    } finally {
                        browserOpen = false
                    }
                }
            }
        }



    suspend fun verifyLogin(lease: BrowserLease): Boolean =
        withContext(Dispatchers.IO) {
            gate.withLock {
                if (lease.generation != generation || !browserOpen) {
                    return@withLock false
                }

                cookies.flush()

                val page = getPage(PortalConfiguration.GRADES)
                val profile = PortalParser.authenticatedProfile(page.html, page.url)
                val old = state.value.snapshot

                commit(
                    (if (old.profile?.accountKey == profile.accountKey) old else PortalSnapshot())
                        .copy(profile = profile)
                )

                if (old.profile?.accountKey != profile.accountKey) accountGeneration++
                notes.activate(RefreshSessionToken(profile.accountKey, accountGeneration))
                if (old.profile != null && old.profile.accountKey != profile.accountKey) {
                    runCatching { clearNotification() }
                    Messenger.reset() // chats are personal: never show A's list to B
                }
                mutable.value =
                    state.value.copy(
                        session = SessionState.ACTIVE,
                        message = null,
                        errors = emptyMap(),
                    )

                try {
                    importPage(PortalSection.GRADES, page.html, page.url)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    sectionError(PortalSection.GRADES, e)
                }

                true
            }
        }

    suspend fun verifyBrowserAccount(lease: BrowserLease) =
        withContext(Dispatchers.IO) {
            gate.withLock {
                if (lease.generation != generation || !browserOpen || lease.account == null)
                    throw PortalFailure.LoginRequired()
                val page = getPage(PortalConfiguration.GRADES)
                if (
                    PortalParser.authenticatedProfile(page.html, page.url).accountKey !=
                        lease.account
                )
                    throw PortalFailure.LoginRequired()
            }
        }

    suspend fun importRendered(
        section: PortalSection,
        html: String,
        source: String,
        lease: BrowserLease,
    ) =
        withContext(Dispatchers.IO) {
            gate.withLock {
                if (
                    lease.generation != generation ||
                        !browserOpen ||
                        lease.account == null ||
                        lease.account != state.value.snapshot.profile?.accountKey
                )
                    throw CancellationException()
                if (PortalParser.authenticatedProfile(html, source).accountKey != lease.account)
                    throw PortalFailure.LoginRequired()
                importPage(section, html, source)
                mutable.value = state.value.copy(session = SessionState.ACTIVE, message = null)
            }
        }
    fun queueNotes(value: String, account: String) {
        if (!logoutRunningMutable.value && !logoutPendingMutable.value) notes.edit(value, account)
    }

    fun flushNotes() { notes.flush() }

    suspend fun saveNotes(value: String, account: String) {
        prepare()
        if (notes.edit(value, account)) notes.flush()?.join()
    }

    private suspend fun persistNoteDraft(draft: NoteDraft): Unit = withContext(Dispatchers.IO) {
        gate.withLock {
            currentCoroutineContext().ensureActive()
            if (draft.generation != accountGeneration ||
                state.value.snapshot.profile?.accountKey != draft.account ||
                !notes.isCurrent(draft) || logoutPendingMutable.value)
                throw CancellationException("Note draft no longer belongs to this session")
            try {
                commit(state.value.snapshot.copy(notes = draft.text))
                if (state.value.message == NOTES_SAVE_ERROR)
                    mutable.value = state.value.copy(message = null)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutable.value = state.value.copy(message = NOTES_SAVE_ERROR)
                throw e
            }
        }
    }
    suspend fun saveProfilePhoto(value: String?, account: String) =
        withContext(Dispatchers.IO) {
            prepare()
            gate.withLock {
                currentCoroutineContext().ensureActive()
                if (state.value.snapshot.profile?.accountKey == account)
                    commit(state.value.snapshot.copy(profilePhoto = value))
            }
        }
// System.current
    private companion object {
        const val NOTES_SAVE_ERROR = "Не удалось сохранить заметку. Измените текст, чтобы повторить сохранение."
    }
    private suspend fun removeCookiesConfirmed() = withContext(Dispatchers.Main) {
        cookieRemoval.awaitRemoval { complete ->
            cookies.removeAllCookies { complete() }
        }
    }

    suspend fun logout(): Boolean {
        val task = synchronized(logoutTaskLock) {
            logoutTask?.takeIf { !it.isCompleted }
                ?: scope.async(start = CoroutineStart.LAZY) {
                    val failures = mutableListOf<String>()
                    var success = false
                    var markerCommitted = false

                    suspend fun attempt(
                        message: String,
                        action: suspend () -> Unit,
                    ): Boolean {
                        return try {
                            currentCoroutineContext().ensureActive()
                            action()
                            currentCoroutineContext().ensureActive()
                            true
                        } catch (e: CancellationException) {
                            throw e
                        } catch (_: Exception) {
                            failures += message
                            false
                        }
                    }

                    try {
                        withTimeout(12_000L) {
                            initialized.await()
                            client.cancelAll()
                            gate.withLock {
                                // Nothing destructive may run until BOTH marker and directory are durable.
                                if (!attempt("Не удалось сохранить отметку о незавершённом выходе. Данные и сессия сохранены; повторите выход.") {
                                    cache.beginLogout()
                                    markerCommitted = true
                                }) return@withTimeout
                                synchronized(logoutTaskLock) {
                                    logoutPendingMutable.value = true
                                }
                                generation++
                                accountGeneration++
                                browserOpen = false
                                notes.activate(null)
                                mutable.value = PortalState(
                                    ready = true,
                                    message = "Выполняется выход: удаляем данные аккаунта и сессию.",
                                )
                            }

                            attempt("Не удалось отменить фоновое обновление.") {
                                cancelRefresh()
                            }
                            attempt("Не удалось удалить уведомление аккаунта.") {
                                clearNotification()
                            }
                            attempt("Не удалось удалить зашифрованные данные аккаунта.") {
                                cache.clear()
                            }
                            attempt("Не удалось удалить сохранённый логин.") {
                                credentials.delete()
                                sessionPreferences.edit().remove("lastContact").apply()
                            }

                            val cookiesRemoved = attempt(
                                "Удаление сессии пока не подтверждено. Повторите очистку. " +
                                        "Если ошибка повторяется, перезапустите приложение и повторите очистку.",
                            ) {
                                removeCookiesConfirmed()
                            }
                            if (cookiesRemoved) {
                                attempt("Не удалось сохранить результат удаления сессии.") {
                                    cookies.flush()
                                }
                                attempt("Сессия осталась в хранилище или её удаление не удалось проверить.") {
                                    check(!cookies.hasCookies())
                                }
                            }
                        }

                        currentCoroutineContext().ensureActive()
                        if (markerCommitted && failures.isEmpty()) {
                            // Commit success only after all cleanup checks have passed.
                            // No suspension between marker deletion and success assignment.
                            cache.finishLogout()
                            success = true
                        }
                        success
                    } catch (_: TimeoutCancellationException) {
                        failures += "Истекло время ожидания очистки. Повторите попытку."
                        false
                    } catch (e: CancellationException) {
                        failures += "Очистка прервана. Повторите попытку."
                        throw e
                    } catch (_: Exception) {
                        failures += "Не удалось завершить выход. Повторите очистку."
                        false
                    } finally {
                        withContext(NonCancellable) {
                            gate.withLock {
                                synchronized(logoutTaskLock) {
                                    val message = if (success) null else failures.ifEmpty {
                                        listOf("Очистка прервана. Повторите попытку.")
                                    }.joinToString(" ")
                                    mutable.value = if (markerCommitted) PortalState(ready = true, message = message)
                                        else state.value.copy(message = message)
                                    // A failed preflight preserves data; an uncertain marker still blocks login.
                                    logoutPendingMutable.value = !success && (markerCommitted ||
                                        runCatching { cache.hasPendingLogout() }.getOrDefault(true))
                                    logoutTask = null
                                    logoutRunningMutable.value = false
                                }
                            }
                        }
                    }
                }.also {
                    logoutTask = it
                    logoutRunningMutable.value = true
                    it.start()
                }
        }

        return try {
            withTimeoutOrNull(15_000L) { task.await() } ?: false
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            false
        }
    }

    private fun currentRefreshSession(): RefreshSessionToken? =
        if (logoutPendingMutable.value || logoutRunningMutable.value) null
        else state.value.snapshot.profile?.let { RefreshSessionToken(it.accountKey, accountGeneration) }

    internal suspend fun refreshSession(): RefreshSessionToken? {
        prepare()
        return gate.withLock { currentRefreshSession() }
    }

    internal suspend fun withRefreshSession(token: RefreshSessionToken, action: suspend (PortalSnapshot) -> Unit) =
        withRefreshSessionGuard(gate, token, ::currentRefreshSession) { action(state.value.snapshot) }

    internal suspend fun withCurrentSnapshot(
        snapshot: PortalSnapshot,
        action: () -> Unit,
    ) {
        gate.withLock {
            currentCoroutineContext().ensureActive()
            if (
                !logoutPendingMutable.value && !logoutRunningMutable.value &&
                snapshot.profile != null &&
                state.value.snapshot === snapshot
            ) {
                action()
            }
        }
    }
}

private const val TOUCH_BODY =
    "[{\"index\":0,\"methodname\":\"core_session_touch\",\"args\":{}}," +
        "{\"index\":1,\"methodname\":\"core_session_time_remaining\",\"args\":{}}]"
