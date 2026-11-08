package com.anton.smartulsu.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.anton.smartulsu.NetworkManager
import com.anton.smartulsu.core.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Test inside the app (port of the iOS QuizScreen). «Завершить» only after confirmation. */
@Composable
internal fun QuizScreen(repo: NetworkManager, title: String, url: String, openBrowser: (String, String) -> Unit, close: () -> Unit) {
    BackHandler(onBack = close)
    var content by remember { mutableStateOf<QuizContent?>(null) }
    val values = remember { mutableStateMapOf<String, String>() }
    val checked = remember { mutableStateListOf<String>() }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmFinish by remember { mutableStateOf(false) }
    var deadline by remember { mutableStateOf<Long?>(null) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()

    fun show(next: QuizContent) {
        content = next; error = null
        values.clear(); checked.clear()
        when (next) {
            is QuizContent.Attempt -> {
                values.putAll(next.page.initialValues()); checked.addAll(next.page.initialChecked())
                deadline = next.page.timeLeftSeconds?.let { System.currentTimeMillis() + it * 1000 }
            }
            is QuizContent.Summary -> deadline = next.summary.timeLeftSeconds?.let { System.currentTimeMillis() + it * 1000 }
            else -> deadline = null
        }
        scope.launch { list.scrollToItem(0) }
    }
    fun load(target: String) = scope.launch {
        busy = true
        try { show(repo.quizPage(target)) } catch (e: Exception) { error = PortalErrors.message(e) }
        busy = false
    }
    fun submit(action: String, items: List<Pair<String, String>>) = scope.launch {
        busy = true
        try { show(repo.quizSubmit(action, items)) } catch (e: Exception) { error = "Не отправлено: ${PortalErrors.message(e)} Ответы остались на экране." }
        busy = false
    }
    LaunchedEffect(url) { load(url) }
    LaunchedEffect(deadline) {
        while (deadline != null) {
            now = System.currentTimeMillis()
            val page = (content as? QuizContent.Attempt)?.page
            if (page != null && now >= deadline!! && !busy) { // the site's own timer sends the page with timeup=1
                submit(page.action, page.payload(values, checked.toSet(), page.next, timeUp = true)); break
            }
            delay(1000)
        }
    }

    if (confirmFinish) AlertDialog(
        onDismissRequest = { confirmFinish = false },
        title = { Text("Завершить тест?") },
        text = { Text("После отправки изменить ответы будет нельзя. ЭИОС сразу посчитает результат.") },
        confirmButton = { TextButton(onClick = {
            confirmFinish = false
            (content as? QuizContent.Summary)?.summary?.let { s -> s.finishAction?.let { submit(it, s.finishFields) } }
        }) { Text("Отправить всё") } },
        dismissButton = { TextButton(onClick = { confirmFinish = false }) { Text("Отмена") } },
    )

    LazyColumn(state = list, contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = close) { Text("Закрыть") }
                Text(title, Modifier.weight(1f), fontWeight = FontWeight.Bold, maxLines = 2)
                deadline?.let {
                    val left = ((it - now) / 1000).coerceAtLeast(0)
                    Text("%d:%02d".format(left / 60, left % 60), fontWeight = FontWeight.Bold,
                        color = if (left < 60) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
                }
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            error?.let { Hint(it) }
        }
        when (val c = content) {
            is QuizContent.Start -> item {
                Text(c.start.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                c.start.info.forEach { Hint(it) }
                c.start.action?.let { action ->
                    Button(onClick = { submit(action, c.start.fields) }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text(c.start.buttonTitle) }
                }
            }
            is QuizContent.Attempt -> {
                val page = c.page
                item {
                    Hint("Страница ${page.pageNumber + 1}")
                    if (page.hasUnsupported) SectionCard {
                        Text("На этой странице есть вопрос, который удобнее ответить в окне ЭИОС.")
                        TextButton(onClick = { openBrowser("Тест", page.url) }) { Text("Открыть эту страницу") }
                    }
                }
                items(page.questions, key = { it.id }) { q -> QuestionCard(q, values, checked) }
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        page.previous?.let { p -> OutlinedButton(onClick = { submit(page.action, page.payload(values, checked.toSet(), p)) },
                            enabled = !busy, modifier = Modifier.weight(1f)) { Text("Назад") } }
                        page.next?.let { n ->
                            val finish = "закончить" in n.second.lowercase()
                            Button(onClick = { submit(page.action, page.payload(values, checked.toSet(), n)) },
                                enabled = !busy, modifier = Modifier.weight(1f)) { Text(if (finish) "К итогам" else "Далее") }
                        }
                    }
                    Hint("Ответы сохраняются в ЭИОС при переходе на другую страницу, как на сайте.")
                }
            }
            is QuizContent.Summary -> {
                item { Text("Итог попытки", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold) }
                items(c.summary.rows) { (q, status) ->
                    SectionCard { Row { Text("Вопрос $q", Modifier.weight(1f)); Text(status,
                        color = if ("нет ответа" in status.lowercase()) Color(0xFFE08A00) else MaterialTheme.colorScheme.onSurfaceVariant) } }
                }
                item {
                    c.summary.returnUrl?.let { back -> OutlinedButton(onClick = { load(back) }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text("Вернуться к вопросам") } }
                    if (c.summary.finishAction != null)
                        Button(onClick = { confirmFinish = true }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text("Отправить всё и завершить тест") }
                }
            }
            is QuizContent.Review -> {
                item { Text("Тест завершён", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = Color(0xFF2E9E4F)) }
                items(c.rows) { (k, v) -> SectionCard { Row { Text(k, Modifier.weight(1f)); Text(v, fontWeight = FontWeight.Bold) } } }
                item {
                    TextButton(onClick = { openBrowser("Разбор", c.url) }) { Text("Посмотреть разбор ответов") }
                    Button(onClick = close, modifier = Modifier.fillMaxWidth()) { Text("Готово") }
                }
            }
            is QuizContent.Unknown -> item {
                Text(c.text)
                Button(onClick = { openBrowser(title, url) }, modifier = Modifier.fillMaxWidth()) { Text("Открыть тест в окне ЭИОС") }
            }
            null -> {}
        }
    }
}

@Composable
private fun QuestionCard(q: QuizQuestion, values: MutableMap<String, String>, checked: MutableList<String>) {
    val accent = MaterialTheme.colorScheme.primary
    SectionCard {
        Row { Text("Вопрос ${q.number}", Modifier.weight(1f), color = accent, fontWeight = FontWeight.Bold); Hint(q.grade) }
        if (q.text.isNotBlank()) Text(q.text, fontWeight = FontWeight.Medium)
        if (q.prompt.isNotBlank()) Hint(q.prompt)
        when (val a = q.answer) {
            is QuizAnswer.Single -> a.options.forEach { o ->
                Option(o.label, values[a.name] == o.value, false) { values[a.name] = o.value }
            }
            is QuizAnswer.Multiple -> a.options.forEach { o ->
                Option(o.label, o.id in checked, true) { if (o.id in checked) checked.remove(o.id) else checked.add(o.id) }
            }
            is QuizAnswer.Text -> OutlinedTextField(values[a.name].orEmpty(), { values[a.name] = it }, Modifier.fillMaxWidth()
                .then(if (a.multiline) Modifier.heightIn(min = 120.dp) else Modifier), label = { Text("Ваш ответ") }, singleLine = !a.multiline)
            is QuizAnswer.Selects -> a.selects.forEach { s ->
                var open by remember { mutableStateOf(false) }
                Column {
                    if (s.prompt.isNotBlank()) Text(s.prompt)
                    OutlinedButton(onClick = { open = true }) { Text(s.options.firstOrNull { it.first == values[s.name] }?.second?.ifBlank { null } ?: "Выбрать…") }
                    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                        s.options.forEach { (value, title) -> DropdownMenuItem(text = { Text(title.ifBlank { "—" }) }, onClick = { values[s.name] = value; open = false }) }
                    }
                }
            }
            is QuizAnswer.Unsupported -> Hint("Этот тип вопроса отвечается в окне ЭИОС (кнопка выше).")
        }
    }
}

@Composable
private fun Option(label: String, selected: Boolean, multiple: Boolean, onClick: () -> Unit) {
    val accent = MaterialTheme.colorScheme.primary
    Row(
        Modifier.fillMaxWidth()
            .background(if (selected) accent.copy(alpha = .14f) else MaterialTheme.colorScheme.onSurface.copy(alpha = .04f), RoundedCornerShape(12.dp))
            .border(BorderStroke(1.5.dp, if (selected) accent else Color.Transparent), RoundedCornerShape(12.dp))
            .clickable(onClick = onClick).padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (multiple) Checkbox(selected, { onClick() }) else RadioButton(selected, onClick)
        Text(label)
    }
}
