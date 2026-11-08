package com.anton.smartulsu.ui

import android.graphics.Bitmap
import androidx.activity.compose.LocalActivityResultRegistryOwner
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResultRegistryOwner
import androidx.activity.result.contract.ActivityResultContract
import androidx.core.app.ActivityOptionsCompat
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.test.platform.app.InstrumentationRegistry
import com.anton.smartulsu.UiPreferences
import com.anton.smartulsu.core.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File

/** Offline, synthetic UI: no real repository, WebView, account or cookie mutation. */
class StudentFeedbackUiTest {
    @get:Rule val compose = createComposeRule()
    private fun snapshot(account: String = "A") = PortalSnapshot(
        profile = StudentProfile(account, "Synthetic student $account"), notes = "Private cached note",
        grades = CachedSection(listOf(GradeItem("1", "Synthetic subject", "Exam", "5", "", "", "1 семестр"))))

    @Test fun physicalTapsOnActualProfileCardShowBothFaces() {
        compose.setContent { MaterialTheme {
            ProfileScreen(PortalState(snapshot = snapshot()), UiPreferences(), {}, {}, { _, _ -> })
        } }
        compose.onNodeWithText("Synthetic student A", useUnmergedTree = true).performTouchInput { click() }
        compose.waitForIdle()
        compose.onNodeWithText("УЧЕБНЫЕ ДАННЫЕ", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Synthetic student A", useUnmergedTree = true).assertIsNotDisplayed()
        compose.onNodeWithText("УЧЕБНЫЕ ДАННЫЕ", useUnmergedTree = true).performTouchInput { click() }
        compose.waitForIdle()
        compose.onNodeWithText("Synthetic student A", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("УЧЕБНЫЕ ДАННЫЕ", useUnmergedTree = true).assertIsNotDisplayed()
    }

    @Test fun photoAreaFlipsCardInsteadOfLaunchingPhotoPicker() {
        var launches = 0
        val owner = object : ActivityResultRegistryOwner {
            override val activityResultRegistry = object : ActivityResultRegistry() {
                override fun <I, O> onLaunch(requestCode: Int, contract: ActivityResultContract<I, O>,
                    input: I, options: ActivityOptionsCompat?) { launches++ }
            }
        }
        compose.setContent { CompositionLocalProvider(LocalActivityResultRegistryOwner provides owner) {
            MaterialTheme { ProfileScreen(PortalState(snapshot = snapshot()), UiPreferences(), {}, {}, { _, _ -> }) }
        } }
        compose.onNode(hasContentDescription("Фото профиля") or hasContentDescription("Добавить фото"),
            useUnmergedTree = true).performTouchInput { click() }
        compose.runOnIdle { assertEquals("The portrait is part of the flip target", 0, launches) }
        compose.onNodeWithText("УЧЕБНЫЕ ДАННЫЕ", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("УЧЕБНЫЕ ДАННЫЕ", useUnmergedTree = true).performTouchInput { click() }
        compose.onNodeWithContentDescription("Изменить фото").performTouchInput { click() }
        compose.runOnIdle { assertEquals(1, launches) }
        compose.onNodeWithText("Synthetic student A", useUnmergedTree = true).assertIsDisplayed()
    }

    @Test fun faceSurvivesRecompositionAndSavedStateRestorationForSameAccount() {
        val restoration = StateRestorationTester(compose)
        val data = mutableStateOf(snapshot())
        restoration.setContent { MaterialTheme {
            StudentProfileCard(data.value, Color.DarkGray, {}) { Text(data.value.profile!!.name) }
        } }
        compose.onNodeWithContentDescription("Карточка студента").performTouchInput { click() }
        compose.runOnIdle { data.value = data.value.copy(notes = "Unrelated cache change") }
        compose.onNodeWithText("УЧЕБНЫЕ ДАННЫЕ", useUnmergedTree = true).assertIsDisplayed()
        restoration.emulateSavedInstanceStateRestore()
        compose.onNodeWithText("УЧЕБНЫЕ ДАННЫЕ", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("УЧЕБНЫЕ ДАННЫЕ", useUnmergedTree = true).performTouchInput { click() }
        compose.onNodeWithText("Synthetic student A", useUnmergedTree = true).assertIsDisplayed()
    }

    @Test fun lockBoundaryResetsSavedFaceWithoutChangingCachedProfile() {
        val locked = mutableStateOf(false)
        compose.setContent { MaterialTheme {
            // Same account/lock key used by SmartTableRoot around ProfileScreen.
            key("A", locked.value) {
                ProfileScreen(PortalState(snapshot = snapshot()), UiPreferences(), {}, {}, { _, _ -> })
            }
        } }
        compose.onNodeWithText("Synthetic student A", useUnmergedTree = true).performTouchInput { click() }
        compose.onNodeWithText("УЧЕБНЫЕ ДАННЫЕ", useUnmergedTree = true).assertIsDisplayed()
        compose.runOnIdle { locked.value = true }
        compose.runOnIdle { locked.value = false }
        compose.onNodeWithText("Synthetic student A", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("УЧЕБНЫЕ ДАННЫЕ", useUnmergedTree = true).assertIsNotDisplayed()
    }

    @Test fun homeKeepsStudentCardAndGradebookWithoutLargeNotesEditor() {
        compose.setContent {
            MaterialTheme {
                ProfileScreen(PortalState(snapshot = snapshot()), UiPreferences(), {}, {}, { _, _ -> })
            }
        }
        compose.onNodeWithContentDescription("Карточка студента").assertIsDisplayed()
        compose.onNodeWithText("Synthetic student A", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Личные заметки").assertDoesNotExist()
        compose.onNodeWithText("Private cached note").assertDoesNotExist()
        capture("front")
        compose.onNodeWithContentDescription("Карточка студента").performClick()
        compose.waitForIdle()
        capture("back")
    }

    @Test fun flipIgnoresRapidTapsKeepsDimensionsAndDoesNotOpenGradebook() {
        var opened = 0
        compose.setContent {
            MaterialTheme { StudentProfileCard(snapshot(), Color(0xFF138454), { opened++ }) {
                Text("Synthetic front")
            } }
        }
        val card = compose.onNodeWithContentDescription("Карточка студента")
        val before = card.fetchSemanticsNode().boundsInRoot
        compose.mainClock.autoAdvance = false
        card.performTouchInput { click() }
        compose.mainClock.advanceTimeByFrame()
        card.assertIsNotEnabled()
        repeat(5) { card.performTouchInput { click() } }
        compose.mainClock.advanceTimeBy(500)
        card.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Учебные данные"))
        compose.onNodeWithText("Synthetic front", useUnmergedTree = true).assertIsNotDisplayed()
        compose.onNodeWithText("Записей в зачётке: 1 · Семестров: 1", useUnmergedTree = true).assertIsDisplayed()
        assertEquals(before.width, card.fetchSemanticsNode().boundsInRoot.width, .1f)
        assertEquals(before.height, card.fetchSemanticsNode().boundsInRoot.height, .1f)
        assertEquals(0, opened)
        card.performTouchInput { click() }
        compose.mainClock.advanceTimeBy(500)
        card.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Лицевая сторона"))
        assertEquals(0, opened)
    }

    @Test fun accountChangeResetsFrontAndReplacesCachedAcademicInformation() {
        val data = mutableStateOf(snapshot())
        compose.setContent { MaterialTheme {
            StudentProfileCard(data.value, Color.DarkGray, {}) { Text(data.value.profile!!.name) }
        } }
        val card = compose.onNodeWithContentDescription("Карточка студента")
        card.performTouchInput { click() }
        compose.waitForIdle()
        compose.onNodeWithText("Записей в зачётке: 1 · Семестров: 1", useUnmergedTree = true).assertIsDisplayed()
        compose.runOnIdle { data.value = snapshot("B").copy(grades = null) }
        card.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Лицевая сторона"))
        compose.onNodeWithText("Synthetic student B", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Synthetic student A", useUnmergedTree = true).assertDoesNotExist()
        card.performTouchInput { click() }
        compose.waitForIdle()
        compose.onNodeWithText("Зачётная книжка ещё не загружена", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithText("Дополнительные данные пока недоступны", useUnmergedTree = true).assertIsDisplayed()
        compose.onAllNodesWithText("Нет данных", useUnmergedTree = true).assertCountEquals(0)
    }

    @Test fun gradebookEntryWorksFromBackInLightAndDarkThemes() {
        val dark = mutableStateOf(false)
        var opened = 0
        compose.setContent { MaterialTheme(colorScheme = if (dark.value) darkColorScheme() else lightColorScheme()) {
            StudentProfileCard(snapshot(), Color(0xFF1059C0), { opened++ }) { Text("Synthetic front") }
        } }
        compose.onNodeWithContentDescription("Карточка студента").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Открыть зачётную книжку").performTouchInput { click() }
        compose.runOnIdle { dark.value = true }
        compose.onNodeWithText("Открыть зачётную книжку").assertIsDisplayed().performTouchInput { click() }
        compose.runOnIdle { assertEquals(2, opened) }
    }

    @Test fun cardEntryRevealsExistingCachedGradebookEvenWhenNormallyCollapsedByPreference() {
        compose.setContent { MaterialTheme {
            ProfileScreen(PortalState(snapshot = snapshot()), UiPreferences(showGradeBook = false), {}, {}, { _, _ -> })
        } }
        compose.onNodeWithText("Synthetic subject").assertDoesNotExist()
        compose.onNodeWithContentDescription("Карточка студента").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Открыть зачётную книжку").performTouchInput { click() }
        compose.waitForIdle()
        compose.onNodeWithText("Synthetic subject").assertIsDisplayed()
    }

    @Test fun notesNavigationKeepsPendingDraftAndAcknowledgesOnlyCompletedWrite() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val release = CompletableDeferred<Unit>()
        val saved = mutableStateOf(snapshot())
        val open = mutableStateOf(true)
        val drafts = NoteDrafts(scope, debounceMillis = 60_000) {
            release.await()
            saved.value = saved.value.copy(notes = it.text)
        }
        drafts.activate(RefreshSessionToken("A", 1))
        try {
            compose.setContent { MaterialTheme {
                val draft by drafts.state.collectAsState()
                if (open.value) NotesScreen(saved.value, draft, { drafts.flush() },
                    { drafts.edit(it, "A") }, { open.value = false })
                else TextButton(onClick = { open.value = true }) { Text("Заметки") }
            } }
            compose.onNodeWithText("Личные заметки").performTextReplacement("Latest edit")
            compose.onNodeWithText("Сохраняем изменения…").assertIsDisplayed()
            compose.onNodeWithText("Назад").performClick()
            compose.onNodeWithText("Заметки").performClick()
            compose.onNodeWithText("Личные заметки").assertTextContains("Latest edit")
            compose.runOnIdle { saved.value = saved.value.copy(nextRefreshAt = 123) }
            compose.onNodeWithText("Личные заметки").assertTextContains("Latest edit")
            compose.runOnIdle { release.complete(Unit) }
            compose.waitUntil(5_000) { drafts.state.value?.status == NoteSaveStatus.SAVED }
            compose.onNodeWithText("Изменения сохранены.").assertIsDisplayed()
            assertEquals("Latest edit", saved.value.notes)
        } finally { scope.cancel() }
    }

    @Test fun noteFailureOffersRetryAndNeverDisplaysAnotherAccountsDraft() {
        val data = mutableStateOf(snapshot())
        val draft = mutableStateOf<NoteDraft?>(NoteDraft("A", "Unsaved", NoteSaveStatus.FAILED, 1, 1))
        var retries = 0
        compose.setContent { MaterialTheme {
            NotesScreen(data.value, draft.value, { retries++ }, {}, {})
        } }
        compose.onNodeWithText("Повторить сохранение").performClick()
        compose.runOnIdle { assertEquals(1, retries); data.value = snapshot("B").copy(notes = "B note") }
        compose.onNodeWithText("Личные заметки").assertTextContains("B note")
        compose.onNodeWithText("Unsaved").assertDoesNotExist()
    }

    @Test fun differentCourseCardsSelectTheirOwnDestinationAndListPositionSurvivesReturn() {
        val courses = (1..30).map { Course("$it", "Synthetic course $it", "", "${PortalConfiguration.BASE}/course/view.php?id=$it") }
        val showingBrowser = mutableStateOf(false)
        var selected = ""
        compose.setContent { MaterialTheme {
            val position = rememberLazyListState()
            if (showingBrowser.value) TextButton(onClick = { showingBrowser.value = false }) { Text("Закрыть") }
            else CoursesScreen(PortalState(snapshot = snapshot().copy(courses = CachedSection(courses))), {}, {
                selected = CourseNavigation.destination(it)
                showingBrowser.value = true
            }, position)
        } }
        compose.onNode(hasScrollToIndexAction()).performScrollToIndex(20)
        compose.onNodeWithText("Synthetic course 20").performClick()
        compose.runOnIdle { assertEquals(courses[19].url, selected) }
        compose.onNodeWithText("Закрыть").performClick()
        compose.onNodeWithText("Synthetic course 20").assertIsDisplayed()
        compose.onNodeWithText("Synthetic course 21").performClick()
        compose.runOnIdle { assertEquals(courses[20].url, selected) }
    }

    private fun capture(face: String) {
        val directory = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir
        File(directory, "student-feedback-$face.png").outputStream().use {
            compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
