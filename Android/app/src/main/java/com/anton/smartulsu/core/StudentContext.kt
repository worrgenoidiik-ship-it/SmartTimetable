package com.anton.smartulsu.core

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import org.jsoup.Jsoup
import org.jsoup.nodes.Element

// Port of the iOS 1.5–1.7 core (CourseTitle, StudentGroup, ScheduleEnricher, forms,
// messaging and timeline parsers). Same rules and test cases on both platforms.

/** «Базы данных ИС-О-25/1 (3 семестр, Комарова Юлиана Егоровна)» → subject + details + teacher. */
class CourseTitle(raw: String) {
    val subject: String
    val details: List<String>
    val teacher: String?

    init {
        var name = PortalParser.clean(raw)
        val parts = mutableListOf<String>()
        val open = name.lastIndexOf(" (")
        if (name.endsWith(")") && open > 0) {
            parts += name.substring(open + 2, name.length - 1).split(',').map { PortalParser.clean(it) }.filter { it.isNotEmpty() }
            name = name.substring(0, open)
        }
        Regex("\\s+([А-ЯЁA-Z]{1,6}-[А-ЯЁA-Z]{1,4}-\\d{2}(?:/\\d+)?)$").find(name)?.let {
            parts.add(0, it.groupValues[1])
            name = name.substring(0, it.range.first)
        }
        subject = name.ifEmpty { PortalParser.clean(raw) }
        details = parts
        val full = Regex("^[А-ЯЁ][а-яё-]+ [А-ЯЁ][а-яё-]+ [А-ЯЁ][а-яё-]+$")
        val short = Regex("^[А-ЯЁ]\\. ?[А-ЯЁ]\\. [А-ЯЁ][а-яё-]+$")
        teacher = parts.lastOrNull { full.matches(it) || short.matches(it) }
    }

    val detailLine: String get() = details.joinToString(" · ")
}

object StudentGroup {
    fun normalized(value: String) = value.replace('_', '-').replace(" ", "").uppercase()

    fun detect(courses: List<Course>): String? {
        val pattern = Regex("([А-ЯЁA-Z]{1,6})[-_]([А-ЯЁA-Z]{1,4})[-_](\\d{2})(?:/(\\d+))?")
        return courses.flatMap { course ->
            pattern.findAll(course.title).map { m ->
                normalized("${m.groupValues[1]}-${m.groupValues[2]}-${m.groupValues[3]}" +
                    (m.groupValues[4].takeIf { it.isNotEmpty() }?.let { "/$it" } ?: ""))
            }.toList()
        }.groupingBy { it }.eachCount().maxWithOrNull(compareBy({ it.value }, { it.key }))?.key
    }

    fun planApplies(snapshot: PortalSnapshot, manual: ManualSchedule): Boolean {
        val group = detect(snapshot.courses?.value.orEmpty()) ?: return true
        return sameGroup(group, manual.plan.group)
    }

    /** «ИС-О-25/1» and «ИС-О-25» (subgroup unknown) match; «ИС-О-25/1» and «ИС-О-25/10» do not. */
    fun sameGroup(a: String, b: String): Boolean {
        val left = normalized(a).split("/", limit = 2)
        val right = normalized(b).split("/", limit = 2)
        if (left[0] != right[0]) return false
        return left.size < 2 || right.size < 2 || left[1] == right[1]
    }

    /** ИС-О-25 → enrolled 2025; September–January is the odd semester. */
    fun currentSemester(group: String?, date: LocalDate = CampusDate.today()): Int? {
        val short = group?.let { Regex("-(\\d{2})(?:/|$)").find(it)?.groupValues?.get(1)?.toIntOrNull() } ?: return null
        val academicYear = if (date.monthValue >= 9) date.year else date.year - 1
        val course = academicYear - (2000 + short)
        if (course !in 0..6) return null
        return course * 2 + if (date.monthValue >= 9 || date.monthValue == 1) 1 else 2
    }
}

/** Full teacher names from course titles (initials must agree), rooms from the portal slot. */
object ScheduleEnricher {
    private data class Teacher(val key: Set<String>, val name: String)

    fun subjectKey(subject: String): Set<String> {
        val aliases = mapOf("английский" to "иностранный")
        return PortalParser.clean(subject).lowercase().replace('ё', 'е').split(Regex("[^\\p{L}]+"))
            .filter { it.length >= 4 }.map { (aliases[it] ?: it).take(5) }.toSet()
    }

    fun sameSubject(a: Set<String>, b: Set<String>) =
        a.isNotEmpty() && b.isNotEmpty() && (a intersect b).size.toDouble() / (a union b).size >= 0.5

    fun initials(name: String): String? {
        val parts = name.split(' ').filter { it.isNotBlank() }
        if (parts.size == 3 && '.' !in name) return (parts[1].take(1) + parts[2].take(1)).uppercase()
        val letters = parts.filter { it.endsWith('.') }.map { it.take(1) }
        return if (letters.size >= 2) letters.take(2).joinToString("").uppercase() else null
    }

    fun enrich(window: ScheduleWindow, courses: List<Course>, portal: ScheduleWindow?): ScheduleWindow {
        val full = Regex("^[А-ЯЁ][а-яё-]+ [А-ЯЁ][а-яё-]+ [А-ЯЁ][а-яё-]+$")
        val teachers = courses.mapNotNull { c -> CourseTitle(c.title).let { t -> t.teacher?.takeIf { '.' !in it }?.let { Teacher(subjectKey(t.subject), it) } } } +
            portal?.items.orEmpty().flatMap { item ->
                item.teacher.split('\n').filter { full.matches(it) }.map { Teacher(subjectKey(item.subject), it) }
            }
        val rooms = portal?.items.orEmpty().filter { it.place.isNotBlank() }.groupBy { slot(it) }
        if (teachers.isEmpty() && rooms.isEmpty()) return window
        return window.copy(items = window.items.map { item ->
            var teacher = item.teacher
            if (teacher.isBlank() || '.' in teacher) {
                val key = subjectKey(item.subject)
                val candidates = teachers.filter { sameSubject(it.key, key) }.map { it.name }.distinct()
                val pick = if (teacher.isBlank()) candidates.singleOrNull()
                else initials(teacher)?.let { wanted -> candidates.filter { initials(it) == wanted }.singleOrNull() }
                if (pick != null) teacher = pick
            }
            var place = item.place
            if (place.isBlank()) {
                val key = subjectKey(item.subject)
                rooms[slot(item)].orEmpty().filter { sameSubject(subjectKey(it.subject), key) }
                    .groupingBy { it.place }.eachCount().maxWithOrNull(compareBy({ it.value }, { it.key }))?.let { place = it.key }
            }
            if (teacher == item.teacher && place == item.place) item else item.copy(teacher = teacher, place = place)
        })
    }

    private fun slot(item: ScheduleItem) =
        runCatching { LocalDate.parse(item.day).dayOfWeek.value }.getOrDefault(0).toString() + "|" + item.timeStart
}

data class QuestionForm(val categories: List<Pair<String, String>>, val email: String)

data class PortalForm(val action: String, val isPost: Boolean, val fields: List<Field>, val submit: Pair<String, String>?) {
    enum class Kind { HIDDEN, TEXT, TEXTAREA, SELECT, CHECKBOX }
    data class Field(val name: String, val label: String, val kind: Kind, val value: String, val options: List<Pair<String, String>>)

    val visibleFields get() = fields.filter { it.kind != Kind.HIDDEN }

    fun payload(values: Map<String, String>): List<Pair<String, String>> =
        fields.mapNotNull { f ->
            if (f.kind == Kind.CHECKBOX && values[f.name] != "1") null else f.name to (values[f.name] ?: f.value)
        } + listOfNotNull(submit)
}

data class ChatUser(val id: Int, val fullname: String, val imageUrl: String?, val online: Boolean?) {
    val initials get() = fullname.split(' ').take(2).mapNotNull { it.firstOrNull()?.uppercase() }.joinToString("")
}
data class ChatMessage(val id: Int, val fromUserId: Int, val text: String, val time: Long)
data class ChatConversation(
    val id: Int, val name: String, val subtitle: String, val members: List<ChatUser>,
    val lastMessage: ChatMessage?, val unread: Int, val isGroup: Boolean, val isSelf: Boolean,
) {
    val title get() = name.ifEmpty { if (isSelf) "Личные заметки" else members.firstOrNull()?.fullname ?: "Диалог" }
}

object PortalExtrasParser {
    private fun clean(s: String) = PortalParser.clean(s)

    fun moodleUserId(html: String): Int? {
        val menu = html.indexOf("usermenu").takeIf { it >= 0 } ?: return null
        return Regex("user/profile\\.php\\?id=(\\d+)").find(html.substring(menu, minOf(html.length, menu + 20_000)))
            ?.groupValues?.get(1)?.toIntOrNull()
    }

    /** The single result of a service.php call; session problems become LoginRequired. */
    fun ajaxResult(json: String): JsonElement {
        val root = runCatching { JsonParser.parseString(json) }.getOrNull() ?: throw PortalFailure.InvalidResponse()
        fun failure(o: JsonObject): PortalFailure {
            val exception = o.get("exception")?.takeIf { it.isJsonObject }?.asJsonObject
            val code = o.get("errorcode")?.asString ?: exception?.get("errorcode")?.asString ?: ""
            val message = exception?.get("message")?.asString ?: o.get("error")?.takeIf { it.isJsonPrimitive }?.asString ?: code
            return if (code in setOf("servicerequireslogin", "invalidsesskey", "requireloginerror", "sitepolicynotagreed"))
                PortalFailure.LoginRequired() else PortalFailure.Parse(message.ifBlank { "ответ ЭИОС" })
        }
        if (root.isJsonObject && root.asJsonObject.has("error")) throw failure(root.asJsonObject)
        val first = root.takeIf { it.isJsonArray }?.asJsonArray?.firstOrNull()?.asJsonObject ?: throw PortalFailure.InvalidResponse()
        if (first.get("error")?.takeIf { it.isJsonPrimitive }?.asBoolean == true) throw failure(first)
        return first.get("data") ?: JsonObject()
    }

    fun plainText(html: String): String =
        html.replace(Regex("<br\\s*/?>|</p>|</div>|</li>", RegexOption.IGNORE_CASE), "␞")
            .let { Jsoup.parse(it).text() }.split('␞').map(::clean).filter { it.isNotEmpty() }.joinToString("\n")

    private fun JsonObject.int(name: String) = get(name)?.takeIf { it.isJsonPrimitive }?.asInt
    private fun JsonObject.str(name: String) = get(name)?.takeIf { it.isJsonPrimitive }?.asString

    fun user(o: JsonObject): ChatUser? {
        val id = o.int("id") ?: return null
        val image = o.str("profileimageurl")?.takeIf { PortalConfiguration.allowsDataURL(it) }
        val online = if (o.get("showonlinestatus")?.asBoolean == true) o.get("isonline")?.asBoolean else null
        return ChatUser(id, clean(o.str("fullname").orEmpty()), image, online)
    }

    fun message(o: JsonObject): ChatMessage? {
        val id = (o.int("id") ?: o.int("msgid"))?.takeIf { it > 0 } ?: return null
        val from = o.int("useridfrom") ?: return null
        val created = o.get("timecreated")?.asLong ?: return null
        return ChatMessage(id, from, plainText(o.str("text").orEmpty()), created * 1000)
    }

    fun conversations(data: JsonElement): List<ChatConversation> {
        val list = data.takeIf { it.isJsonObject }?.asJsonObject?.getAsJsonArray("conversations")
            ?: throw PortalFailure.Parse("список чатов")
        return list.mapNotNull { e ->
            val o = e.asJsonObject
            val id = o.int("id") ?: return@mapNotNull null
            val type = o.int("type") ?: 1
            val messages = o.getAsJsonArray("messages")?.mapNotNull { message(it.asJsonObject) }.orEmpty()
            ChatConversation(id, clean(o.str("name").orEmpty()), clean(o.str("subname").orEmpty()),
                o.getAsJsonArray("members")?.mapNotNull { user(it.asJsonObject) }.orEmpty(),
                messages.maxByOrNull { it.time }, o.int("unreadcount") ?: 0, type == 2, type == 3)
        }
    }

    fun conversationMessages(data: JsonElement): Pair<List<ChatMessage>, List<ChatUser>> {
        val o = data.takeIf { it.isJsonObject }?.asJsonObject ?: throw PortalFailure.Parse("сообщения чата")
        val list = o.getAsJsonArray("messages") ?: throw PortalFailure.Parse("сообщения чата")
        return list.mapNotNull { message(it.asJsonObject) }.sortedWith(compareBy({ it.time }, { it.id })) to
            o.getAsJsonArray("members")?.mapNotNull { user(it.asJsonObject) }.orEmpty()
    }

    fun sentMessages(data: JsonElement): List<ChatMessage> {
        val list = data.takeIf { it.isJsonArray }?.asJsonArray ?: throw PortalFailure.Parse("ответ на отправку")
        list.mapNotNull { it.asJsonObject.str("errormessage") }.firstOrNull { it.isNotBlank() }?.let { throw PortalFailure.Parse(it) }
        return list.mapNotNull { message(it.asJsonObject) }
    }

    fun searchResults(data: JsonElement): List<ChatUser> {
        val o = data.takeIf { it.isJsonObject }?.asJsonObject ?: return emptyList()
        return (o.getAsJsonArray("contacts").orEmptyArray() + o.getAsJsonArray("noncontacts").orEmptyArray())
            .mapNotNull { user(it.asJsonObject) }.distinctBy { it.id }
    }

    private fun JsonArray?.orEmptyArray(): List<JsonElement> = this?.toList().orEmpty()

    /** core_calendar_get_action_events_by_timesort — upcoming quizzes and assignments. */
    fun actionEvents(data: JsonElement): List<DeadlineItem> {
        val events = data.takeIf { it.isJsonObject }?.asJsonObject?.getAsJsonArray("events")
            ?: throw PortalFailure.Parse("события временной шкалы")
        return events.mapNotNull { e ->
            val o = e.asJsonObject
            val id = o.int("id") ?: return@mapNotNull null
            val sort = o.get("timesort")?.asLong ?: return@mapNotNull null
            val course = o.get("course")?.takeIf { it.isJsonObject }?.asJsonObject?.str("fullname").orEmpty()
            val module = o.str("modulename").orEmpty()
            DeadlineItem(id.toString(), clean(o.str("name").orEmpty()), CourseTitle(course).subject,
                if (module.isEmpty()) "" else "mod_$module",
                Instant.ofEpochSecond(sort).atZone(ZoneId.of("Europe/Samara")).toLocalDateTime().toString().replace('T', ' '),
                sort * 1000, o.str("url")?.takeIf { PortalConfiguration.allowsDataURL(it) })
        }.sortedWith(compareBy({ it.due ?: Long.MAX_VALUE }, { it.id }))
    }

    fun questionForm(html: String): QuestionForm {
        val doc = Jsoup.parse(html)
        val options = doc.select("select#cat option").mapNotNull { o ->
            val id = o.attr("value"); val title = clean(o.text())
            if (id.isEmpty() || title.isEmpty()) null else id to title
        }
        if (options.isEmpty() || doc.select("#subject, #message").isEmpty()) throw PortalFailure.Parse("форма вопроса")
        return QuestionForm(options, doc.selectFirst("input#reply_type")?.attr("value").orEmpty())
    }

    /** Moodle forms; labels come from the field's own row (the portal reuses ids). */
    fun forms(html: String, source: String): List<PortalForm> {
        val doc = Jsoup.parse(html, source)
        val labelCounts = doc.select("label[for]").groupingBy { it.attr("for") }.eachCount()
        val labels = doc.select("label[for]").associate { it.attr("for") to clean(it.text()) }
        fun label(e: Element): String {
            e.parents().firstOrNull { it.hasClass("fitem") || it.hasClass("form-group") }
                ?.select("label")?.map { clean(it.text()) }?.firstOrNull { it.isNotEmpty() }?.let { return it }
            val id = e.attr("id")
            return if ((labelCounts[id] ?: 0) > 1) "" else labels[id].orEmpty()
        }
        return doc.select("#region-main form.mform").mapNotNull { form ->
            val action = runCatching { java.net.URI(source).resolve(form.attr("action")).toString() }.getOrNull()
                ?.takeIf { PortalConfiguration.allowsDataURL(it) } ?: return@mapNotNull null
            var submit: Pair<String, String>? = null
            val fields = form.select("input[name], select[name], textarea[name]").mapNotNull { e ->
                val name = e.attr("name")
                when (e.tagName()) {
                    "select" -> {
                        val options = e.select("option").map { it.attr("value") to clean(it.text()) }
                        PortalForm.Field(name, label(e), PortalForm.Kind.SELECT,
                            e.selectFirst("option[selected]")?.attr("value") ?: options.firstOrNull()?.first.orEmpty(), options)
                    }
                    "textarea" -> PortalForm.Field(name, label(e), PortalForm.Kind.TEXTAREA, e.text(), emptyList())
                    else -> when (val type = e.attr("type").lowercase()) {
                        "submit" -> { if (submit == null) submit = name to e.attr("value"); null }
                        "button", "file" -> null
                        else -> PortalForm.Field(name, label(e),
                            if (type == "hidden") PortalForm.Kind.HIDDEN else if (type == "checkbox") PortalForm.Kind.CHECKBOX else PortalForm.Kind.TEXT,
                            e.attr("value"), emptyList())
                    }
                }
            }
            PortalForm(action, form.attr("method").equals("post", true), fields, submit)
        }
    }

    fun notice(html: String): Pair<String, Boolean>? {
        val n = Jsoup.parse(html).selectFirst("#region-main .alert, #user-notifications .alert, #region-main .box.generalbox, #region-main .notifyproblem, #region-main .notifysuccess")
            ?: return null
        val text = clean(n.text()).ifEmpty { return null }
        val classes = n.className()
        return text to ("danger" in classes || "error" in classes || "problem" in classes)
    }
}
