package com.anton.smartulsu.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.anton.smartulsu.NetworkManager
import com.anton.smartulsu.core.*
import com.google.gson.JsonArray
import com.google.gson.JsonObject
import java.time.Instant
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

// Port of the iOS messenger, «Задать вопрос» and «Заказ справок»: everything inside the app,
// over the same Moodle web services and portal requests the site itself uses.

private val ru = Locale.forLanguageTag("ru")
private fun time(millis: Long, pattern: String) =
    Instant.ofEpochMilli(millis).atZone(CampusDate.zone).format(DateTimeFormatter.ofPattern(pattern, ru))
private fun listTime(millis: Long): String {
    val day = Instant.ofEpochMilli(millis).atZone(CampusDate.zone).toLocalDate()
    return when (day) {
        CampusDate.today() -> time(millis, "HH:mm")
        CampusDate.today().minusDays(1) -> "вчера"
        else -> time(millis, "d MMM")
    }
}

/** Conversations kept in memory only; messages are personal and always re-read from the portal. */
object Messenger {
    val conversations = MutableStateFlow<List<ChatConversation>>(emptyList())
    val error = MutableStateFlow<String?>(null)
    val loading = MutableStateFlow(false)
    @Volatile var myId: Int? = null

    private fun args(vararg pairs: Pair<String, Any>) = JsonObject().apply {
        pairs.forEach { (k, v) ->
            when (v) {
                is Number -> addProperty(k, v); is Boolean -> addProperty(k, v); is String -> addProperty(k, v)
                is JsonArray -> add(k, v)
            }
        }
    }

    /** Bumped by reset(): a load started for the previous account must not fill the new one. */
    @Volatile private var generation = 0

    suspend fun load(repo: NetworkManager) {
        if (loading.value) return
        val token = generation
        loading.value = true
        try {
            val me = repo.userId()
            val values = PortalExtrasParser.conversations(repo.ajax("core_message_get_conversations",
                args("userid" to me, "limitfrom" to 0, "limitnum" to 50, "mergeself" to true)))
                .sortedByDescending { it.lastMessage?.time ?: 0 }
            if (token != generation) return
            myId = me
            conversations.value = values
            error.value = null
        } catch (e: Exception) {
            if (token == generation) error.value = PortalErrors.message(e)
        } finally { if (token == generation) loading.value = false }
    }

    suspend fun messages(repo: NetworkManager, id: Int): Pair<List<ChatMessage>, List<ChatUser>> {
        val me = repo.userId().also { myId = it }
        return PortalExtrasParser.conversationMessages(repo.ajax("core_message_get_conversation_messages",
            args("currentuserid" to me, "convid" to id, "limitfrom" to 0, "limitnum" to 100, "newest" to true)))
    }

    suspend fun conversationWith(repo: NetworkManager, user: ChatUser): Int? {
        conversations.value.firstOrNull { !it.isGroup && it.members.any { m -> m.id == user.id } }?.let { return it.id }
        return runCatching {
            repo.ajax("core_message_get_conversation_between_users", args("userid" to repo.userId(), "otheruserid" to user.id,
                "includecontactrequests" to false, "includeprivacyinfo" to false)).asJsonObject.get("id")?.asInt
        }.getOrNull()
    }

    private fun messageList(vararg message: Pair<String, Any>) = JsonArray().apply { add(args(*message)) }

    suspend fun send(repo: NetworkManager, id: Int, text: String) = PortalExtrasParser.sentMessages(
        repo.ajax("core_message_send_messages_to_conversation", args("conversationid" to id, "messages" to messageList("text" to text))))

    suspend fun sendFirst(repo: NetworkManager, user: ChatUser, text: String): Pair<Int?, List<ChatMessage>> {
        val data = repo.ajax("core_message_send_instant_messages", args("messages" to messageList("touserid" to user.id, "text" to text)))
        val conversation = data.takeIf { it.isJsonArray }?.asJsonArray?.firstOrNull()?.asJsonObject?.get("conversationid")?.asInt
        return conversation to PortalExtrasParser.sentMessages(data)
    }

    suspend fun search(repo: NetworkManager, query: String): List<ChatUser> {
        val me = repo.userId()
        return PortalExtrasParser.searchResults(repo.ajax("core_message_message_search_users",
            args("userid" to me, "search" to query, "limitfrom" to 0, "limitnum" to 30))).filter { it.id != me }
    }

    suspend fun markRead(repo: NetworkManager, id: Int) {
        runCatching { repo.ajax("core_message_mark_all_conversation_messages_as_read", args("userid" to repo.userId(), "conversationid" to id)) }
        conversations.value = conversations.value.map { if (it.id == id) it.copy(unread = 0) else it }
    }

    fun reset() { generation++; conversations.value = emptyList(); myId = null; error.value = null; loading.value = false }
}

@Composable
private fun Avatar(name: String, size: Int = 44) {
    Box(Modifier.size(size.dp).background(MaterialTheme.colorScheme.primary.copy(alpha = .18f), CircleShape),
        contentAlignment = Alignment.Center) {
        Text(name.split(' ').take(2).mapNotNull { it.firstOrNull()?.uppercase() }.joinToString(""),
            color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Bold)
    }
}

@Composable
internal fun MessagesTab(
    repo: NetworkManager,
    state: PortalState,
    openChat: (Int, String) -> Unit,
    newChat: (String) -> Unit,
    pickCourse: () -> Unit,
    question: () -> Unit,
    openInbox: () -> Unit,
) {
    val conversations by Messenger.conversations.collectAsState()
    val error by Messenger.error.collectAsState()
    val loading by Messenger.loading.collectAsState()
    var showAll by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { Messenger.load(repo) }
    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            Text("Сообщения", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(top = 8.dp)) {
                OutlinedButton(onClick = { newChat("") }, Modifier.weight(1f)) { Text("Новое сообщение") }
                OutlinedButton(onClick = pickCourse, Modifier.weight(1f)) { Text("Преподавателю") }
            }
            if (loading) LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 8.dp))
            error?.let { Hint(it) }
        }
        if (conversations.isEmpty() && !loading && error == null)
            item { EmptyCard("Чатов пока нет", "Нажмите «Новое сообщение», чтобы написать преподавателю или одногруппнику.") }
        items(if (showAll) conversations else conversations.take(5), key = { it.id }) { c ->
            SectionCard(Modifier.clickable { openChat(c.id, c.title) }) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Avatar(c.title)
                    Column(Modifier.weight(1f)) {
                        Row {
                            Text(c.title, Modifier.weight(1f), fontWeight = FontWeight.SemiBold, maxLines = 1)
                            c.lastMessage?.let { Text(listTime(it.time), style = MaterialTheme.typography.labelSmall) }
                        }
                        Text((if (c.lastMessage?.fromUserId == Messenger.myId) "Вы: " else "") + (c.lastMessage?.text ?: "Нет сообщений"),
                            maxLines = 2, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (c.unread > 0) Badge { Text(c.unread.toString()) }
                }
            }
        }
        if (conversations.size > 5) item {
            TextButton(onClick = { showAll = !showAll }, Modifier.fillMaxWidth()) {
                Text(if (showAll) "Свернуть" else "Показать все (${conversations.size})")
            }
        }
        item {
            val unread = state.snapshot.notifications?.value.orEmpty().count { it.isUnread }
            SectionCard(Modifier.clickable(onClick = openInbox)) {
                Text("Уведомления ЭИОС" + if (unread > 0) " · $unread новых" else "", fontWeight = FontWeight.SemiBold)
            }
        }
        item { SectionCard(Modifier.clickable(onClick = question)) { Text("Задать вопрос в деканат", fontWeight = FontWeight.SemiBold); Hint("Официальная форма ЭИОС") } }
    }
}

@Composable
internal fun ChatScreen(repo: NetworkManager, title: String, conversationId: Int?, partner: ChatUser?, back: () -> Unit) {
    BackHandler(onBack = back)
    var id by remember { mutableStateOf(conversationId) }
    var messages by remember { mutableStateOf<List<ChatMessage>>(emptyList()) }
    var members by remember { mutableStateOf<List<ChatUser>>(emptyList()) }
    var draft by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val list = rememberLazyListState()
    LaunchedEffect(Unit) {
        if (id == null && partner != null) id = Messenger.conversationWith(repo, partner)
        while (true) { // the portal has no push for this app: poll while the chat is open
            id?.let { current ->
                try {
                    val (loaded, people) = Messenger.messages(repo, current)
                    if (loaded != messages) messages = loaded
                    members = people
                    error = null
                    Messenger.markRead(repo, current)
                } catch (e: Exception) { error = PortalErrors.message(e) }
            }
            delay(12_000)
        }
    }
    LaunchedEffect(messages.size) { if (messages.isNotEmpty()) list.animateScrollToItem(messages.size - 1) }
    Column(Modifier.fillMaxSize()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 8.dp)) {
            TextButton(onClick = back) { Text("Назад") }
            Text(title, fontWeight = FontWeight.Bold, maxLines = 1)
        }
        LazyColumn(Modifier.weight(1f).padding(horizontal = 12.dp), state = list, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (messages.isEmpty()) item {
                Hint(if (partner != null && id == null) "Напишите первое сообщение — оно уйдёт через ЭИОС." else "Сообщений пока нет.")
            }
            items(messages, key = { it.id }) { m ->
                val mine = m.fromUserId == Messenger.myId
                Row(Modifier.fillMaxWidth(), horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
                    Column(
                        Modifier.widthIn(max = 300.dp)
                            .background(if (mine) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surface, RoundedCornerShape(18.dp))
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                    ) {
                        if (members.size > 1 && !mine) members.firstOrNull { it.id == m.fromUserId }?.let {
                            Text(it.fullname, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                        }
                        Text(m.text, color = if (mine) Color.White else MaterialTheme.colorScheme.onSurface)
                        Text(time(m.time, "d MMM, HH:mm"), style = MaterialTheme.typography.labelSmall,
                            color = if (mine) Color.White.copy(alpha = .75f) else MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        error?.let { Hint(it, Modifier.padding(horizontal = 16.dp)) }
        Row(Modifier.fillMaxWidth().padding(12.dp).imePadding(), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(draft, { draft = it }, Modifier.weight(1f), placeholder = { Text("Сообщение") },
                maxLines = 6, shape = RoundedCornerShape(20.dp))
            IconButton(enabled = !sending && draft.isNotBlank(), onClick = {
                val original = draft
                val text = draft.trim()
                scope.launch {
                    sending = true
                    try {
                        val sent = id?.let { Messenger.send(repo, it, text) } ?: partner?.let { p ->
                            Messenger.sendFirst(repo, p, text).also { id = it.first }.second
                        } ?: emptyList()
                        // Only the sent text leaves the field; anything typed meanwhile stays.
                        if (draft.startsWith(original)) draft = draft.removePrefix(original).trimStart()
                        messages = messages + sent.filter { s -> messages.none { it.id == s.id } }
                        error = null
                    } catch (e: Exception) {
                        error = "Не отправлено: ${PortalErrors.message(e)} Текст сохранён в поле ввода."
                    } finally { sending = false }
                }
            }) { Icon(Icons.AutoMirrored.Outlined.Send, "Отправить") }
        }
    }
}

@Composable
internal fun NewChatScreen(repo: NetworkManager, initialQuery: String, open: (ChatUser) -> Unit, back: () -> Unit) {
    BackHandler(onBack = back)
    var query by remember { mutableStateOf(initialQuery) }
    var results by remember { mutableStateOf<List<ChatUser>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var searching by remember { mutableStateOf(false) }
    LaunchedEffect(query) {
        if (query.trim().length < 3) { results = emptyList(); return@LaunchedEffect }
        delay(400) // debounce typing
        searching = true
        try { results = Messenger.search(repo, query.trim()); error = null } catch (e: Exception) { error = PortalErrors.message(e) }
        searching = false
    }
    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            TextButton(onClick = back) { Text("Назад") }
            Text("Новое сообщение", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), label = { Text("Фамилия или имя") }, singleLine = true)
            if (searching) LinearProgressIndicator(Modifier.fillMaxWidth())
            error?.let { Hint(it) }
            if (query.trim().length < 3) Hint("Введите хотя бы 3 буквы.")
        }
        items(results, key = { it.id }) { user ->
            SectionCard(Modifier.clickable { open(user) }) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Avatar(user.fullname, 38); Text(user.fullname)
                }
            }
        }
    }
}

@Composable
internal fun CoursePickerScreen(courses: List<Course>, pick: (Course) -> Unit, back: () -> Unit) {
    BackHandler(onBack = back)
    var query by remember { mutableStateOf("") }
    val filtered = courses.filter { query.isBlank() || it.title.contains(query.trim(), ignoreCase = true) }
    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            TextButton(onClick = back) { Text("Назад") }
            Text("Выберите курс", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth(), label = { Text("Предмет или преподаватель") }, singleLine = true)
        }
        items(filtered, key = { it.id }) { course ->
            val title = CourseTitle(course.title)
            SectionCard(Modifier.clickable { pick(course) }) {
                Text(title.subject, fontWeight = FontWeight.SemiBold)
                if (title.detailLine.isNotBlank()) Hint(title.detailLine)
            }
        }
    }
}

@Composable
internal fun QuestionScreen(repo: NetworkManager, back: () -> Unit) {
    BackHandler(onBack = back)
    var form by remember { mutableStateOf<QuestionForm?>(null) }
    var category by remember { mutableStateOf("") }
    var subject by remember { mutableStateOf("") }
    var message by remember { mutableStateOf("") }
    var email by remember { mutableStateOf("") }
    var status by remember { mutableStateOf<String?>(null) }
    var sending by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) {
        try { form = repo.questionForm().also { category = it.categories.firstOrNull()?.first.orEmpty(); email = it.email } }
        catch (e: Exception) { status = PortalErrors.message(e) }
    }
    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            TextButton(onClick = back) { Text("Назад") }
            Text("Задать вопрос", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            if (form == null && status == null) LinearProgressIndicator(Modifier.fillMaxWidth())
        }
        form?.let { f ->
            item {
                Text("Раздел", fontWeight = FontWeight.SemiBold)
                f.categories.forEach { (id, title) ->
                    Row(Modifier.fillMaxWidth().clickable { category = id }, verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(category == id, { category = id }); Text(title)
                    }
                }
                OutlinedTextField(subject, { subject = it }, Modifier.fillMaxWidth(), label = { Text("Тема") }, singleLine = true)
                OutlinedTextField(message, { message = it }, Modifier.fillMaxWidth().heightIn(min = 140.dp), label = { Text("Вопрос") })
                OutlinedTextField(email, { email = it }, Modifier.fillMaxWidth(), label = { Text("Email для ответа") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email))
                Button(
                    enabled = !sending && category.isNotBlank() && subject.isNotBlank() && message.isNotBlank() && '@' in email,
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    onClick = {
                        scope.launch {
                            sending = true
                            status = try {
                                repo.sendQuestion(category, subject.trim(), message.trim(), email.trim())
                                message = ""; subject = ""
                                "Вопрос отправлен. Ответ придёт на $email."
                            } catch (e: Exception) { "Не отправлено: ${PortalErrors.message(e)}" }
                            sending = false
                        }
                    },
                ) { Text(if (sending) "Отправляем…" else "Отправить") }
            }
        }
        status?.let { item { Hint(it) } }
    }
}

@Composable
internal fun InquiryScreen(repo: NetworkManager, back: () -> Unit) {
    BackHandler(onBack = back)
    var chooser by remember { mutableStateOf<PortalForm?>(null) }
    var request by remember { mutableStateOf<PortalForm?>(null) }
    var kind by remember { mutableStateOf("") }
    val values = remember { mutableStateMapOf<String, String>() }
    var status by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(true) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) {
        try {
            chooser = repo.loadForms(PortalConfiguration.INQUIRY).first.firstOrNull { f -> f.fields.any { it.name == "form_type" } }
            if (chooser == null) status = "Форма заказа справок не распознана."
        } catch (e: Exception) { status = PortalErrors.message(e) }
        busy = false
    }
    fun open(value: String) {
        kind = value; request = null; values.clear()
        val form = chooser ?: return
        scope.launch {
            busy = true
            try {
                val (forms, page) = repo.openForm(form, mapOf("form_type" to value))
                request = forms.firstOrNull { f -> f.isPost && f.fields.none { it.name == "form_type" } }
                status = if (request == null) PortalExtrasParser.notice(page.html)?.first ?: "Для этой справки ЭИОС не показала форму." else null
            } catch (e: Exception) { status = PortalErrors.message(e) }
            busy = false
        }
    }
    LazyColumn(contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        item {
            TextButton(onClick = back) { Text("Назад") }
            Text("Заказ справок", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        }
        chooser?.fields?.firstOrNull { it.name == "form_type" }?.let { field ->
            items(field.options.filter { it.first.isNotBlank() }, key = { it.first }) { (value, title) ->
                Row(Modifier.fillMaxWidth().clickable { open(value) }, verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(kind == value, { open(value) }); Text(title)
                }
            }
        }
        request?.let { form ->
            item {
                Text("Данные для справки", fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 8.dp))
                form.visibleFields.forEach { field ->
                    val label = field.label.ifBlank { field.name }
                    when (field.kind) {
                        PortalForm.Kind.SELECT -> {
                            Text(label, style = MaterialTheme.typography.labelLarge)
                            field.options.forEach { (value, title) ->
                                Row(Modifier.fillMaxWidth().clickable { values[field.name] = value }, verticalAlignment = Alignment.CenterVertically) {
                                    RadioButton((values[field.name] ?: field.value) == value, { values[field.name] = value }); Text(title)
                                }
                            }
                        }
                        PortalForm.Kind.CHECKBOX -> Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(values[field.name] == "1", { values[field.name] = if (it) "1" else "0" }); Text(label)
                        }
                        else -> OutlinedTextField(values[field.name] ?: field.value, { values[field.name] = it },
                            Modifier.fillMaxWidth(), label = { Text(label) })
                    }
                }
                Button(enabled = !busy, modifier = Modifier.fillMaxWidth().padding(top = 8.dp), onClick = {
                    scope.launch {
                        busy = true
                        status = try {
                            val page = repo.submitForm(form, values.toMap())
                            val notice = PortalExtrasParser.notice(page.html)
                            if (notice?.second == true) notice.first else {
                                request = null; kind = ""
                                notice?.first ?: "Запрос отправлен. Статус справки виден на этой же странице ЭИОС."
                            }
                        } catch (e: Exception) { "Не отправлено: ${PortalErrors.message(e)}" }
                        busy = false
                    }
                }) { Text(form.submit?.second ?: "Отправить запрос") }
            }
        }
        status?.let { item { Hint(it) } }
    }
}
