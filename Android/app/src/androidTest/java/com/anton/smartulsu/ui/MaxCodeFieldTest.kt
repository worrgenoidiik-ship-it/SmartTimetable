package com.anton.smartulsu.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import org.junit.Rule
import org.junit.Test

/** Synthetic field only: no login, logout, repository mutation or live credentials. */
class MaxCodeFieldTest {
    @get:Rule val compose = createComposeRule()

    @Test fun pasteCorrectionAndDeletingLastDigit() {
        val value = mutableStateOf("")
        compose.setContent { MaterialTheme { MaxCodeField(value.value, { value.value = it }, true) } }
        val field = compose.onNodeWithText("Код MAX")
        field.performTextInput("12a٣４34567")
        field.assertTextContains("123456")
        field.performTextReplacement("987654")
        field.assertTextContains("987654")
        field.performTextReplacement("1")
        field.performTextClearance()
        field.assertTextEquals("Код MAX", "")
    }

    @Test fun pendingDisablesFieldAndRejectionClearsAndEnablesIt() {
        val value = mutableStateOf("123456")
        val enabled = mutableStateOf(false)
        compose.setContent { MaterialTheme { MaxCodeField(value.value, { value.value = it }, enabled.value) } }
        val field = compose.onNodeWithText("Код MAX")
        field.assertIsNotEnabled()
        compose.runOnIdle { value.value = ""; enabled.value = true }
        field.assertIsEnabled()
        field.assertTextEquals("Код MAX", "")
        field.performTextInput("654321")
        field.assertTextContains("654321")
    }
}
