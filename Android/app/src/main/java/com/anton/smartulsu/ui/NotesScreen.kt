package com.anton.smartulsu.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.anton.smartulsu.core.*

@Composable
internal fun NotesScreen(
    snapshot: PortalSnapshot,
    draft: NoteDraft?,
    flush: () -> Unit,
    edit: (String) -> Unit,
    close: () -> Unit,
) {
    val current = draft?.takeIf { it.account == snapshot.profile?.accountKey }
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    DisposableEffect(snapshot.profile?.accountKey) { onDispose { flush() } }
    fun finish() { flush(); close() }
    BackHandler { finish() }
    Column(Modifier.fillMaxSize().imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        TextButton(onClick = ::finish) { Text("Назад") }
        Text("Заметки", style = MaterialTheme.typography.headlineSmall)
        OutlinedTextField(
            value = current?.text ?: snapshot.notes,
            onValueChange = edit,
            label = { Text("Личные заметки") },
            modifier = Modifier.fillMaxWidth().heightIn(min = 220.dp),
            minLines = 8,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = {
                flush(); focus.clearFocus(); keyboard?.hide()
            }),
        )
        Text(when (current?.status) {
            NoteSaveStatus.PENDING -> "Сохраняем изменения…"
            NoteSaveStatus.FAILED -> "Заметка не сохранена. Повторите сохранение."
            else -> "Изменения сохранены."
        }, style = MaterialTheme.typography.bodySmall)
        if (current?.status == NoteSaveStatus.FAILED)
            TextButton(onClick = flush) { Text("Повторить сохранение") }
    }
}
