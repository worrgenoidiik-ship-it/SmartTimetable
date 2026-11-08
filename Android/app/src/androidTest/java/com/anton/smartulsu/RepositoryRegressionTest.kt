package com.anton.smartulsu

import android.content.Context
import android.content.ContextWrapper
import android.webkit.CookieManager
import android.webkit.ValueCallback
import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.anton.smartulsu.core.*
import com.anton.smartulsu.data.*
import java.io.File
import java.io.IOException
import java.net.UnknownHostException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import okhttp3.*
import okhttp3.ResponseBody.Companion.toResponseBody
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RepositoryRegressionTest {
    private fun context(): Context {
        val base = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(base.cacheDir, "repository-test-${UUID.randomUUID()}").apply { mkdirs() }
        return object : ContextWrapper(base) {
            override fun getNoBackupFilesDir() = directory
        }
    }

    // No real EIOS requests, cookies, worker cancellation or notifications are touched.
    @Suppress("DEPRECATION")
    private class TestCookies : CookieManager() {
        var failFlush = false
        var flushCalls = 0
        var cookieWrites = 0
        var deferRemoval = false
        var removal: ValueCallback<Boolean>? = null
        var removalCalls = 0
        var beforeFlush: (() -> Unit)? = null
        val removalStarted = CompletableDeferred<Unit>()
        override fun setAcceptCookie(accept: Boolean) {}
        override fun acceptCookie() = true
        override fun setAcceptThirdPartyCookies(webView: WebView?, accept: Boolean) {}
        override fun acceptThirdPartyCookies(webView: WebView?) = false
        override fun setCookie(url: String?, value: String?) { cookieWrites++ }
        override fun setCookie(url: String?, value: String?, callback: ValueCallback<Boolean>?) { callback?.onReceiveValue(true) }
        override fun getCookie(url: String?): String? = null
        override fun removeSessionCookie() {}
        override fun removeSessionCookies(callback: ValueCallback<Boolean>?) { callback?.onReceiveValue(false) }
        override fun removeAllCookie() {}
        override fun removeAllCookies(callback: ValueCallback<Boolean>?) {
            removalCalls++
            removal = callback
            removalStarted.complete(Unit)
            if (!deferRemoval) callback?.onReceiveValue(false)
        }
        override fun hasCookies() = false
        override fun removeExpiredCookie() {}
        override fun flush() { beforeFlush?.invoke(); flushCalls++; if (failFlush) throw IOException("Synthetic storage failure") }
    }

    private fun page(id: Int = 1) = PortalPage(
        "<div class='usermenu'><span class='usertext'>Test student</span><a href='/user/profile.php?id=$id'>Profile</a></div><a href='/login/logout.php'>Logout</a>",
        PortalConfiguration.GRADES,
    )

    private fun repository(context: Context, cookies: TestCookies,
                           events: (List<PortalEvent>) -> Unit = {},
                           load: suspend (String) -> PortalPage = { page() }) =
        NetworkManager(context, cookies, load, cancelRefresh = {}, clearNotification = {}, publishEvents = events)

    @Test fun secondBrowserCannotReplaceLeaseAndStaleLeaseCannotLogin() = runBlocking {
        val repo = repository(context(), TestCookies())
        val first = repo.browserWillOpen()
        try { repo.browserWillOpen(); fail("Second browser must be rejected") } catch (_: IllegalStateException) { }
        assertTrue(repo.verifyLogin(first))
        repo.browserDidClose(first)
        val second = repo.browserWillOpen()
        assertFalse(repo.verifyLogin(first))
        assertTrue(repo.verifyLogin(second))
        repo.browserDidClose(second)
    }

    @Test fun browserOpeningDuringSlowRefreshCookieFlushKeepsMainResponsive() =
        slowBrowserCancellation(cancelBeforeAcquisition = false)

    @Test fun cancellingBrowserDuringSlowCancellationDoesNotLeakLease() =
        slowBrowserCancellation(cancelBeforeAcquisition = true)

    private fun slowBrowserCancellation(cancelBeforeAcquisition: Boolean) = runBlocking {
        val context = context()
        val cookies = TestCookies()
        val flushStarted = CountDownLatch(1)
        val releaseFlush = CountDownLatch(1)
        val firstFlush = java.util.concurrent.atomic.AtomicBoolean(true)
        cookies.beforeFlush = {
            if (firstFlush.getAndSet(false)) {
                flushStarted.countDown()
                check(releaseFlush.await(10, TimeUnit.SECONDS))
            }
        }
        val client = PortalClient(cookies, "Synthetic test", Interceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(200).message("OK").body(page().html.toResponseBody()).build()
        })
        CacheStore(context).save(PortalSnapshot(
            profile = PortalParser.authenticatedProfile(page().html, page().url)))
        val repo = NetworkManager(context, cookies, cancelRefresh = {}, clearNotification = {}, client = client)
        repo.prepare()
        val refresh = launch(Dispatchers.IO) { try { repo.refresh(true) } catch (_: PortalRequestCancelled) { } }
        var browser: Deferred<NetworkManager.BrowserLease>? = null
        try {
            assertTrue(flushStarted.await(5, TimeUnit.SECONDS))
            val opening = async(Dispatchers.Main) { repo.browserWillOpen() }
            browser = opening
            // Queued after browser opening on the same Main dispatcher. A blocking
            // cancelAll would prevent this marker from running until flush is released.
            withTimeout(2_000) { withContext(Dispatchers.Main) { assertFalse(opening.isCompleted) } }
            if (cancelBeforeAcquisition) opening.cancel()
            releaseFlush.countDown()
            refresh.join()
            if (cancelBeforeAcquisition) {
                opening.join()
            } else {
                val lease = withTimeout(5_000) { opening.await() }
                try { repo.browserWillOpen(); fail("Concurrent owner must be rejected") }
                catch (_: IllegalStateException) { }
                repo.browserDidClose(lease)
                repo.browserDidClose(lease)
            }
            val reopened = withTimeout(5_000) { repo.browserWillOpen() }
            repo.browserDidClose(reopened)
            assertEquals(0, cookies.removalCalls)
            assertNotNull(repo.state.value.snapshot.profile)
        } finally {
            releaseFlush.countDown()
            browser?.cancelAndJoin()
            refresh.cancelAndJoin()
        }
    }

    @Test fun cookieFlushFailureStillReleasesBrowser() = runBlocking {
        val cookies = TestCookies()
        val repo = repository(context(), cookies)
        val first = repo.browserWillOpen()
        cookies.failFlush = true
        repo.browserDidClose(first)
        cookies.failFlush = false
        val second = repo.browserWillOpen()
        assertNotEquals(first.generation, second.generation)
        repo.browserDidClose(second)
    }

    @Test fun loginKeepsBrowserLeaseUntilCloseSoRefreshCannotDisturbMax() = runBlocking {
        var requests = 0
        val repo = repository(context(), TestCookies()) { requests++; page() }
        val lease = repo.browserWillOpen()
        assertTrue(repo.verifyLogin(lease))
        repo.refresh(true)
        assertEquals(1, requests)
        repo.browserDidClose(lease)
    }

    @Test fun temporaryNetworkFailurePreservesOfflineSnapshotWithoutRequestingLogin() = runBlocking {
        val context = context()
        val snapshot = PortalSnapshot(profile = StudentProfile("test-id", "Test"), notes = "Private note", profilePhoto = "synthetic-photo", courses = CachedSection(listOf(Course("1", "Cached", "", "https://portal.ulsu.ru/course/view.php?id=1"))))
        CacheStore(context).save(snapshot)
        val repo = repository(context, TestCookies()) { throw UnknownHostException("synthetic") }
        repo.refresh(true)
        assertEquals(SessionState.OFFLINE, repo.state.value.session)
        assertEquals(snapshot.notes, repo.state.value.snapshot.notes)
        assertEquals(snapshot.profilePhoto, repo.state.value.snapshot.profilePhoto)
        assertEquals(snapshot.courses, repo.state.value.snapshot.courses)
        assertEquals(snapshot.courses, CacheStore(context).load().courses)
    }

    @Test fun anotherAccountDoesNotInheritNotesPhotosCoursesGradesOrSchedule() = runBlocking {
        val context = context()
        CacheStore(context).save(PortalSnapshot(profile = StudentProfile("old", "Old account"), notes = "Old note", profilePhoto = "old-photo",
            courses = CachedSection(listOf(Course("42", "Old course", "", "${PortalConfiguration.BASE}/course/view.php?id=42"))),
            grades = CachedSection(listOf(GradeItem("1", "Old subject", "Exam", "5", "", "", "1"))),
            portalSchedule = CachedSection(ScheduleWindow(listOf("2026-10-19"), listOf(
                ScheduleItem("1", "2026-10-19", "09:00", "10:00", "Лекция", "Old subject", "", "A"))))))
        val repo = repository(context, TestCookies()) { page(2) }
        val lease = repo.browserWillOpen()
        assertTrue(repo.verifyLogin(lease))
        assertEquals("", repo.state.value.snapshot.notes)
        assertNull(repo.state.value.snapshot.profilePhoto)
        assertNull(repo.state.value.snapshot.courses)
        assertNull(repo.state.value.snapshot.grades)
        assertNull(repo.state.value.snapshot.portalSchedule)
        assertNull(CacheStore(context).load().portalSchedule)
        repo.browserDidClose(lease)
    }

    @Test fun courseBrowserVerificationReusesSessionButRejectsExpiryOrAnotherAccount() = runBlocking {
        val context = context()
        val profile = PortalParser.authenticatedProfile(page().html, page().url)
        CacheStore(context).save(PortalSnapshot(profile = profile))
        val cookies = TestCookies()
        var current = page()
        val repo = repository(context, cookies) { current }
        var lease = repo.browserWillOpen()
        repo.verifyBrowserAccount(lease)
        repo.browserDidClose(lease)
        current = page(2)
        lease = repo.browserWillOpen()
        try { repo.verifyBrowserAccount(lease); fail("Other account must not open cached courses") }
        catch (_: PortalFailure.LoginRequired) { }
        repo.browserDidClose(lease)
        current = PortalPage("<form id='login'></form>", PortalConfiguration.LOGIN)
        lease = repo.browserWillOpen()
        try { repo.verifyBrowserAccount(lease); fail("Expired session must not open courses") }
        catch (_: PortalFailure.LoginRequired) { }
        repo.browserDidClose(lease)
        current = page()
        lease = repo.browserWillOpen()
        repo.verifyBrowserAccount(lease)
        repo.browserDidClose(lease)
        assertEquals(profile, CacheStore(context).load().profile)
        assertEquals(0, cookies.removalCalls)
        assertEquals(0, cookies.cookieWrites)
    }

    @Test fun scheduleParseFailureAndOfflineRestartPreserveCurrentAccountTimetable() = runBlocking {
        val context = context()
        val original = PortalParser.parseAjaxSchedule(eventPage(PortalConfiguration.SCHEDULE, emptyList()).html)
        val snapshot = PortalSnapshot(profile = PortalParser.authenticatedProfile(page().html, page().url),
            portalSchedule = CachedSection(original))
        CacheStore(context).save(snapshot)
        val requested = mutableListOf<String>()
        val repo = repository(context, TestCookies()) { url ->
            requested += url
            if (url == PortalConfiguration.SCHEDULE) PortalPage("{\"html\":\"<main>Unsupported schedule</main>\"}", url)
            else eventPage(url, emptyList())
        }
        repo.refresh(true)
        assertTrue(requested.contains(PortalConfiguration.SCHEDULE))
        assertEquals(snapshot.portalSchedule, repo.state.value.snapshot.portalSchedule)
        assertTrue(repo.state.value.errors.containsKey(PortalSection.SCHEDULE))
        val restarted = repository(context, TestCookies()) { throw UnknownHostException("Synthetic offline") }
        restarted.refresh(true)
        assertEquals(snapshot.profile, restarted.state.value.snapshot.profile)
        assertEquals(snapshot.portalSchedule, restarted.state.value.snapshot.portalSchedule)
        assertEquals(snapshot.portalSchedule, CacheStore(context).load().portalSchedule)
    }

    @Test fun pendingMarkerBlocksRestorationAndLogin() = runBlocking {
        val context = context()
        CacheStore(context).apply { save(PortalSnapshot(notes = "Hidden")); beginLogout() }
        val repo = repository(context, TestCookies())
        repo.prepare()
        assertTrue(repo.logoutPending.value)
        assertEquals(PortalSnapshot(), repo.state.value.snapshot)
        try { repo.browserWillOpen(); fail("Login must stay blocked") } catch (_: IllegalStateException) { }
    }

    @Test fun cookiePersistenceFailureRemainsPendingAndNextAttemptCanSucceed() = runBlocking {
        val context = context()
        val cookies = TestCookies().apply { failFlush = true }
        val repo = repository(context, cookies)
        assertFalse(repo.logout())
        assertTrue(repo.logoutPending.value)
        assertFalse(repo.logoutRunning.value)
        assertTrue(CacheStore(context).hasPendingLogout())
        assertNull(repo.state.value.snapshot.profile)
        cookies.failFlush = false
        assertTrue(repo.logout())
        assertFalse(repo.logoutPending.value)
        assertFalse(CacheStore(context).hasPendingLogout())
        assertEquals(2, cookies.removalCalls)
    }

    @Test fun cancellingCallerDoesNotCancelCleanupAndStaleWorkerCannotPublish() = runBlocking {
        val cookies = TestCookies().apply { deferRemoval = true }
        val repo = repository(context(), cookies)
        val lease = repo.browserWillOpen()
        assertTrue(repo.verifyLogin(lease))
        repo.browserDidClose(lease)
        val old = repo.state.value.snapshot
        val caller = launch { repo.logout() }
        withTimeout(3000) { cookies.removalStarted.await() }
        caller.cancelAndJoin()
        assertTrue(repo.logoutRunning.value)
        cookies.removal!!.onReceiveValue(false)
        withTimeout(3000) { while (repo.logoutPending.value) delay(10) }
        assertNull(repo.state.value.snapshot.profile)
        var published = false
        repo.withCurrentSnapshot(old) { published = true }
        assertFalse(published)
    }

    @Test fun cancelledWorkerCannotPublishEvenWithAnImmediatelyAvailableMutex() = runBlocking {
        val repo = repository(context(), TestCookies())
        val lease = repo.browserWillOpen()
        assertTrue(repo.verifyLogin(lease))
        repo.browserDidClose(lease)
        val current = repo.state.value.snapshot
        var published = false
        val worker = launch {
            currentCoroutineContext().cancel()
            repo.withCurrentSnapshot(current) { published = true }
        }
        worker.join()
        assertFalse(published)
    }

    private fun eventPage(url: String, ids: List<Int>, room: String = "A"): PortalPage {
        val header = page().html
        val day = CampusDate.today().toString().replace("-", "")
        val body = when (url) {
            PortalConfiguration.NOTIFICATIONS -> "<div data-region='notification-area'>" + ids.joinToString("") {
                "<div data-region='notification-content-item-container' data-id='$it' class='unread'>" +
                    "<div class='notification-message'>Synthetic message</div><span class='timestamp'>сейчас</span></div>"
            } + "</div>"
            PortalConfiguration.COURSES -> "<main id='region-main'><a href='/course/view.php?id=1'>Synthetic course</a></main>"
            PortalConfiguration.SCHEDULE -> return PortalPage(com.google.gson.Gson().toJson(mapOf("html" to
                "<div class='tab-content'><div class='tab-pane' id='day$day'><table class='schedule-table'><tbody><tr>" +
                    "<td class='schedule-table_time'>09:00-10:00</td><td class='schedule-table_exam'>Synthetic</td>" +
                    "<td class='schedule-table_type'>Лекция</td><td class='schedule-table_category'>Teacher</td>" +
                    "<td class='schedule-table_adress'>$room</td></tr></tbody></table></div></div>")), url)
            else -> "" // No grades: parser failure is independent of valid notification/schedule sections.
        }
        return PortalPage(header + body, url)
    }

    @Test fun notificationEventsPersistBeforePublishingAndDoNotReplayAfterRecreation() = runBlocking {
        val context = context()
        val profile = PortalParser.authenticatedProfile(page().html, page().url)
        CacheStore(context).save(PortalSnapshot(profile = profile))
        var ids = listOf(10)
        var room = "A"
        val published = mutableListOf<PortalEvent>()
        val repo = repository(context, TestCookies(), events = {
            assertEquals(ids.size, CacheStore(context).load().notifications!!.value.size)
            published += it
        }) { eventPage(it, ids, room) }
        repo.refresh(true)
        assertTrue(published.isEmpty()) // first synchronization
        ids = listOf(10, 11)
        room = "B"
        repo.refresh(true)
        assertEquals(listOf(PortalEventCategory.EIOS, PortalEventCategory.SCHEDULE), published.map { it.category })
        published.clear()
        val recreated = repository(context, TestCookies(), events = { published += it }) { eventPage(it, ids, room) }
        recreated.refresh(true)
        assertTrue(published.isEmpty())
        assertEquals(2, recreated.state.value.snapshot.notifications!!.value.size)
    }

    @Test fun notificationRefreshFailureAndActiveBrowserNeverPublish() = runBlocking {
        val context = context()
        val snapshot = PortalSnapshot(profile = PortalParser.authenticatedProfile(page().html, page().url),
            notifications = CachedSection(listOf(PortalNotification("10", "Cached", "вчера", true))))
        CacheStore(context).save(snapshot)
        val events = mutableListOf<PortalEvent>()
        var requests = 0
        val repo = repository(context, TestCookies(), events = { events += it }) {
            requests++
            throw UnknownHostException("Synthetic offline failure")
        }
        repo.refresh() // same entry point as PortalRefreshWorker
        assertEquals(SessionState.OFFLINE, repo.state.value.session)
        assertEquals(snapshot.notifications, CacheStore(context).load().notifications)
        assertTrue(events.isEmpty())
        val lease = repo.browserWillOpen()
        val before = requests
        repo.refresh(true)
        assertEquals(before, requests)
        assertTrue(events.isEmpty())
        repo.browserDidClose(lease)
    }

    @Test fun notificationParseFailureAndSessionExpiryPreserveCacheWithoutEvents() = runBlocking {
        val context = context()
        val snapshot = PortalSnapshot(profile = PortalParser.authenticatedProfile(page().html, page().url),
            notifications = CachedSection(listOf(PortalNotification("10", "Cached", "вчера", true))))
        CacheStore(context).save(snapshot)
        val events = mutableListOf<PortalEvent>()
        val cookies = TestCookies()
        var expired = false
        val repo = repository(context, cookies, events = { events += it }) { url ->
            if (expired) throw PortalFailure.LoginRequired()
            if (url == PortalConfiguration.NOTIFICATIONS) PortalPage(page().html + "<main>Loading</main>", url)
            else eventPage(url, listOf(11))
        }
        repo.refresh(true)
        assertTrue(events.isEmpty())
        assertEquals(snapshot.notifications, CacheStore(context).load().notifications)
        expired = true
        repo.refresh(true)
        assertEquals(SessionState.NEEDS_LOGIN, repo.state.value.session)
        assertTrue(events.isEmpty())
        assertEquals(0, cookies.removalCalls)
        assertEquals(snapshot.notifications, CacheStore(context).load().notifications)
    }

    @Test fun notificationDeliveryFailureDoesNotInvalidateSessionOrReplayEvent() = runBlocking {
        val context = context()
        val profile = PortalParser.authenticatedProfile(page().html, page().url)
        CacheStore(context).save(PortalSnapshot(profile = profile,
            notifications = CachedSection(listOf(PortalNotification("10", "Cached", "вчера", true)))))
        var deliveries = 0
        val repo = repository(context, TestCookies(), events = {
            deliveries++
            throw SecurityException("Synthetic revoked notification permission")
        }) { eventPage(it, listOf(10, 11)) }
        repo.refresh(true)
        repo.refresh(true)
        assertEquals(1, deliveries)
        assertEquals(SessionState.ACTIVE, repo.state.value.session)
        assertEquals(2, CacheStore(context).load().notifications!!.value.size)
    }
    @Test fun markerFailurePreservesSnapshotCacheAndCookiesThenAllowsRetry() = runBlocking {
        val context = context()
        val before = PortalSnapshot(profile = StudentProfile("1", "Synthetic"), notes = "Retain me")
        val store = CacheStore(context)
        store.save(before)
        val cookies = TestCookies()
        var workerCancellations = 0
        var notificationCancellations = 0
        val repo = NetworkManager(context, cookies, { page() },
            cancelRefresh = { workerCancellations++ }, clearNotification = { notificationCancellations++ })
        repo.prepare()
        val file = File(context.noBackupFilesDir, "portal-v1.enc")
        val encrypted = file.readBytes()
        val marker = File(context.noBackupFilesDir, "logout.pending")
        assertTrue(marker.mkdir()) // Synthetic failure: a directory cannot be opened as a marker file.
        assertFalse(repo.logout())
        assertEquals(before, repo.state.value.snapshot)
        assertEquals(before, store.load())
        assertArrayEquals(encrypted, file.readBytes())
        assertEquals(0, cookies.removalCalls)
        assertEquals(0, workerCancellations)
        assertEquals(0, notificationCancellations)
        assertFalse(repo.logoutRunning.value)
        assertNotNull(repo.state.value.message)
        val restarted = repository(context, cookies)
        restarted.prepare()
        assertTrue(restarted.logoutPending.value)
        assertNull(restarted.state.value.snapshot.profile)
        assertTrue(marker.delete()) // Only this test's empty marker directory.
        assertTrue(repo.logout())
        assertFalse(store.hasPendingLogout())
        assertEquals(1, cookies.removalCalls)
        assertNull(repo.state.value.snapshot.profile)
    }

    @Test fun cacheDeletionFailureKeepsDurableMarkerAcrossRestartUntilRetry() = runBlocking {
        val context = context()
        val store = CacheStore(context)
        store.save(PortalSnapshot(profile = StudentProfile("1", "Synthetic")))
        val cookies = TestCookies()
        val repo = repository(context, cookies)
        repo.prepare()
        val blocked = File(context.noBackupFilesDir, "portal-v1.enc.new").apply { mkdirs() }
        val child = File(blocked, "synthetic-obstruction").apply { writeText("test") }
        assertFalse(repo.logout())
        assertTrue(store.hasPendingLogout())
        assertTrue(repo.logoutPending.value)
        val restarted = repository(context, cookies)
        restarted.prepare()
        assertNull(restarted.state.value.snapshot.profile)
        assertTrue(restarted.logoutPending.value)
        assertTrue(child.delete())
        assertTrue(blocked.delete())
        assertTrue(restarted.logout())
        assertFalse(store.hasPendingLogout())
    }

    @Test fun leaseCancellationAndRepeatedClosePreserveSessionAndAllowReopen() = runBlocking {
        val cookies = TestCookies()
        val repo = repository(context(), cookies)
        val job = launch {
            withBrowserLease({ repo.browserWillOpen().also { currentCoroutineContext().cancel() } },
                repo::browserDidClose, { fail("Cancelled acquisition cannot initialize WebView") })
        }
        job.join()
        val lease = repo.browserWillOpen()
        assertTrue(repo.verifyLogin(lease))
        repo.browserDidClose(lease)
        val flushed = cookies.flushCalls
        repo.browserDidClose(lease)
        assertEquals(flushed, cookies.flushCalls)
        val next = repo.browserWillOpen()
        repo.browserDidClose(lease)
        assertTrue(repo.verifyLogin(next))
        repo.browserDidClose(next)
        assertEquals(0, cookies.removalCalls)
        assertNotNull(repo.state.value.snapshot.profile)
    }

    @Test fun intentionalRefreshCancellationPreservesOfflineDataAndDoesNotMarkOffline() = runBlocking {
        val context = context()
        val original = PortalSnapshot(profile = StudentProfile("1", "Test"), notes = "Keep", nextRefreshAt = 123)
        CacheStore(context).save(original)
        val repo = repository(context, TestCookies()) { throw CancellationException("Browser opened") }
        repo.prepare()
        val session = repo.state.value.session
        try { repo.refresh(true); fail() } catch (_: CancellationException) { }
        assertEquals(session, repo.state.value.session)
        assertEquals(original, repo.state.value.snapshot)
        assertEquals(original, CacheStore(context).load())
        assertFalse(repo.state.value.loading)
        assertNull(repo.state.value.message)
        assertTrue(repo.state.value.errors.isEmpty())
    }

    @Test fun cancelledHttpResponseCannotWriteCookiesAndNextGenerationStillWorks() = runBlocking {
        val cookies = TestCookies()
        val started = CompletableDeferred<Unit>()
        val finish = CountDownLatch(1)
        var calls = 0
        val client = PortalClient(cookies, "Synthetic", Interceptor { chain ->
            if (calls++ == 0) {
                started.complete(Unit)
                check(finish.await(5, TimeUnit.SECONDS))
            }
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200)
                .message("OK").header("Set-Cookie", "synthetic=1")
                .body("synthetic".toResponseBody()).build()
        })
        val request = async(Dispatchers.IO) { client.get(PortalConfiguration.GRADES) }
        try {
            withTimeout(5_000) { started.await() }
            client.cancelAll()
        } finally { finish.countDown() }
        try { request.await(); fail("Invalidated request must cancel") } catch (_: CancellationException) { }
        assertEquals(0, cookies.cookieWrites)
        assertEquals("synthetic", client.get(PortalConfiguration.GRADES).html)
        assertEquals(1, cookies.cookieWrites)
    }

    @Test fun unexpectedRedirectIsUnsafeWithoutBecomingSessionExpiration() = runBlocking {
        for ((target, expected) in listOf(
            "https://example.com/login/index.php" to PortalFailure.UnsafeURL::class.java,
            "https://portal.ulsu.ru.example.com/wait.php" to PortalFailure.UnsafeURL::class.java,
            "http://portal.ulsu.ru/login/index.php" to PortalFailure.UnsafeURL::class.java,
            PortalConfiguration.LOGIN to PortalFailure.LoginRequired::class.java,
            "${PortalConfiguration.BASE}/local/loginwait/wait.php" to PortalFailure.LoginRequired::class.java,
            "https://s1.ulsu.ru:8443/realms/ulsu/" to PortalFailure.LoginRequired::class.java,
        )) {
            var requests = 0
            val client = PortalClient(TestCookies(), "Synthetic test", Interceptor { chain ->
                requests++
                Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                    .code(302).message("Found").header("Location", target)
                    .body("".toResponseBody()).build()
            })
            try { client.get(PortalConfiguration.GRADES); fail("Redirect should be classified") }
            catch (e: PortalFailure) { assertTrue(target, expected.isInstance(e)) }
            assertEquals("Redirect must never receive a data request", 1, requests)
        }
    }

    @Test fun cancelledHttpIOExceptionIsCancellationButRealNetworkFailureIsNot() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val finish = CountDownLatch(1)
        val client = PortalClient(TestCookies(), "Synthetic", Interceptor {
            started.complete(Unit)
            check(finish.await(5, TimeUnit.SECONDS))
            throw UnknownHostException("Synthetic DNS failure")
        })
        val request = async(Dispatchers.IO) { client.get(PortalConfiguration.GRADES) }
        try {
            withTimeout(5_000) { started.await() }
            client.cancelAll()
        } finally { finish.countDown() }
        try { request.await(); fail() } catch (_: CancellationException) { }
        try { client.get(PortalConfiguration.GRADES); fail() } catch (_: UnknownHostException) { }
    }

    @Test fun startupSchedulingWaitsForRestoredTimestampAndRechecksDisabledPreference() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val restore = CountDownLatch(1)
        val nextRefreshAt = System.currentTimeMillis() + 3_600_000
        val repo = NetworkManager(context(), TestCookies(), { page() }, cancelRefresh = {}, clearNotification = {},
            restoreSnapshot = {
                started.complete(Unit)
                check(restore.await(5, TimeUnit.SECONDS))
                PortalSnapshot(profile = StudentProfile("1", "Test"), nextRefreshAt = nextRefreshAt)
            })
        var enabled = true
        val delays = mutableListOf<Long>()
        withTimeout(5_000) { started.await() }
        val job = launch(start = CoroutineStart.UNDISPATCHED) {
            RefreshScheduler.ensure(repo, enabled = { enabled }, enqueue = { delays += it })
        }
        try {
            assertTrue(delays.isEmpty())
            assertFalse(job.isCompleted)
            enabled = false
        } finally { restore.countDown() }
        job.join()
        assertTrue(delays.isEmpty())
        enabled = true
        RefreshScheduler.ensure(repo, enabled = { enabled }, enqueue = { delays += it })
        assertEquals(1, delays.size)
        assertTrue(delays.single() in 3_590_000L..3_600_000L)
        val session = repo.refreshSession()!!
        repo.saveNotes("Changed", "1")
        RefreshScheduler.ensure(repo, session, { true }, { delays += it })
        assertEquals(2, delays.size)
    }

    @Test fun unwritableMarkerDirectoryAbortsLogoutWithoutHidingSavedAccount() = runBlocking {
        val context = context()
        val snapshot = PortalSnapshot(profile = StudentProfile("1", "Synthetic"), notes = "Keep")
        CacheStore(context).save(snapshot)
        val cookies = TestCookies()
        val repo = repository(context, cookies)
        repo.prepare()
        android.system.Os.chmod(context.noBackupFilesDir.path, 320) // 0500, test-owned directory only.
        try {
            assertFalse(repo.logout())
            assertFalse(repo.logoutPending.value)
            assertEquals(snapshot, repo.state.value.snapshot)
            assertEquals(snapshot, CacheStore(context).load())
            assertEquals(0, cookies.removalCalls)
        } finally { android.system.Os.chmod(context.noBackupFilesDir.path, 448) } // 0700
        assertTrue(repo.logout())
    }

    @Test fun largeNotificationBatchPublishesEveryNewIdButPersistsOnlyBoundedHistory() = runBlocking {
        val context = context()
        val profile = PortalParser.authenticatedProfile(page().html, page().url)
        CacheStore(context).save(PortalSnapshot(profile = profile,
            notifications = CachedSection(listOf(PortalNotification("1", "Old", "", true)))))
        val events = mutableListOf<PortalEvent>()
        var ids = (1..1001).toList()
        val repo = repository(context, TestCookies(), events = { events += it }) { eventPage(it, ids) }
        repo.refresh(true)
        assertEquals(listOf(PortalEvent(PortalEventCategory.EIOS, 1000)), events)
        assertEquals(500, CacheStore(context).load().notifications!!.value.size)
        events.clear()
        ids = (1..501).toList()
        val restarted = repository(context, TestCookies(), events = { events += it }) { eventPage(it, ids) }
        restarted.refresh(true)
        assertTrue(events.isEmpty())
        assertEquals("1001", CacheStore(context).load().notifications!!.value.first().id)
    }

    @Test fun noteAcknowledgementSurvivesRepositoryRecreation() = runBlocking {
        val context = context()
        CacheStore(context).save(PortalSnapshot(profile = StudentProfile("A", "Test")))
        val repo = repository(context, TestCookies())
        repo.saveNotes("Persisted draft", "A")
        assertEquals(NoteSaveStatus.SAVED, repo.noteDraft.value!!.status)
        assertEquals("Persisted draft", CacheStore(context).load().notes)
        val restarted = repository(context, TestCookies())
        restarted.prepare()
        assertEquals("Persisted draft", restarted.state.value.snapshot.notes)
    }

    @Test fun failedCacheCommitCannotAcknowledgeNoteOrReplaceSnapshot() = runBlocking {
        val context = context()
        val original = PortalSnapshot(profile = StudentProfile("A", "Test"), notes = "Old")
        CacheStore(context).save(original)
        val cache = CacheStore(context, finishWrite = { _, stream -> stream.close() })
        val repo = NetworkManager(context, TestCookies(), { page() }, cancelRefresh = {}, clearNotification = {}, cache = cache)
        repo.saveNotes("Keep as unsaved draft", "A")
        assertEquals(NoteSaveStatus.FAILED, repo.noteDraft.value!!.status)
        assertEquals("Keep as unsaved draft", repo.noteDraft.value!!.text)
        assertEquals(original, repo.state.value.snapshot)
        assertEquals(original, CacheStore(context).load())
    }

    @Test fun editDuringSlowSaveCannotBeOverwrittenByOldAcknowledgement() = runBlocking {
        val context = context()
        CacheStore(context).save(PortalSnapshot(profile = StudentProfile("A", "Test")))
        val started = CompletableDeferred<Unit>()
        val release = CountDownLatch(1)
        var first = true
        val cache = CacheStore(context, syncData = { stream ->
            if (first) {
                first = false
                started.complete(Unit)
                check(release.await(5, TimeUnit.SECONDS))
            }
            stream.fd.sync()
        })
        val repo = NetworkManager(context, TestCookies(), { page() }, cancelRefresh = {}, clearNotification = {}, cache = cache)
        repo.prepare()
        repo.queueNotes("First", "A")
        repo.flushNotes()
        try {
            withTimeout(5_000) { started.await() }
            repo.queueNotes("Latest", "A")
            repo.flushNotes()
            assertEquals("Latest", repo.noteDraft.value!!.text)
        } finally { release.countDown() }
        withTimeout(5_000) { repo.noteDraft.first { it?.text == "Latest" && it.status == NoteSaveStatus.SAVED } }
        assertEquals("Latest", CacheStore(context).load().notes)
    }

    @Test fun pendingNoteIsDiscardedOnAccountReplacementAndLogout() = runBlocking {
        val context = context()
        var account = 1
        val repo = repository(context, TestCookies()) { page(account) }
        var lease = repo.browserWillOpen()
        assertTrue(repo.verifyLogin(lease))
        repo.browserDidClose(lease)
        val previous = repo.state.value.snapshot.profile!!.accountKey
        repo.queueNotes("A draft", previous)
        account = 2
        lease = repo.browserWillOpen()
        assertTrue(repo.verifyLogin(lease))
        repo.browserDidClose(lease)
        assertNull(repo.noteDraft.value)
        assertEquals("", repo.state.value.snapshot.notes)
        repo.queueNotes("B draft", repo.state.value.snapshot.profile!!.accountKey)
        assertTrue(repo.logout())
        assertNull(repo.noteDraft.value)
        assertNull(repo.state.value.snapshot.profile)
        assertNull(CacheStore(context).load().profile)
    }

}
