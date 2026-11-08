package com.anton.smartulsu.core

import java.net.URI
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element

// Port of the iOS Quiz.swift: view.php → attempt.php → summary.php → review.php, read from the
// same pages a browser gets; answers are posted with the same fields the site's buttons send.

data class QuizOption(val id: String, val name: String, val value: String, val label: String)
data class QuizSelect(val name: String, val prompt: String, val options: List<Pair<String, String>>)

sealed class QuizAnswer {
    data class Single(val name: String, val options: List<QuizOption>) : QuizAnswer()
    data class Multiple(val options: List<QuizOption>) : QuizAnswer()
    data class Text(val name: String, val multiline: Boolean) : QuizAnswer()
    data class Selects(val selects: List<QuizSelect>) : QuizAnswer()
    data class Unsupported(val type: String) : QuizAnswer()
}

data class QuizQuestion(
    val id: String, val number: String, val state: String, val grade: String,
    val prompt: String, val text: String, val images: List<String>, val answer: QuizAnswer,
)

sealed class QuizEntry {
    data class Hidden(val name: String, val value: String) : QuizEntry()
    data class Choice(val id: String, val name: String, val value: String) : QuizEntry()
    data class Input(val name: String, val value: String) : QuizEntry()
}

data class QuizAttemptPage(
    val title: String, val url: String, val action: String, val entries: List<QuizEntry>,
    val questions: List<QuizQuestion>, val next: Pair<String, String>?, val previous: Pair<String, String>?,
    val timeLeftSeconds: Long?, val pageNumber: Int, val initiallyChecked: Set<String>,
) {
    val hasUnsupported get() = questions.any { it.answer is QuizAnswer.Unsupported }

    fun initialValues(): Map<String, String> {
        val values = entries.filterIsInstance<QuizEntry.Input>().associate { it.name to it.value }.toMutableMap()
        questions.forEach { q ->
            val a = q.answer
            if (a is QuizAnswer.Single) a.options.firstOrNull { it.id in initiallyChecked }?.let { values[a.name] = it.value }
        }
        return values
    }

    fun initialChecked(): Set<String> = questions.flatMap { q ->
        (q.answer as? QuizAnswer.Multiple)?.options.orEmpty().map { it.id }.filter { it in initiallyChecked }
    }.toSet()

    /** Same order as the browser: a hidden «0» is followed by the ticked «1» (Moodle keeps the last). */
    fun payload(values: Map<String, String>, checked: Set<String>, button: Pair<String, String>?, timeUp: Boolean = false): List<Pair<String, String>> {
        val radios = questions.mapNotNull { (it.answer as? QuizAnswer.Single)?.name }.toSet()
        val items = entries.mapNotNull { e ->
            when (e) {
                is QuizEntry.Hidden -> e.name to if (e.name == "timeup" && timeUp) "1" else e.value
                is QuizEntry.Choice -> if (e.name in radios) { if (values[e.name] == e.value) e.name to e.value else null }
                    else if (e.id in checked) e.name to e.value else null
                is QuizEntry.Input -> e.name to (values[e.name] ?: e.value)
            }
        }
        return items + listOfNotNull(button)
    }
}

data class QuizSummary(
    val title: String, val rows: List<Pair<String, String>>, val finishAction: String?,
    val finishFields: List<Pair<String, String>>, val returnUrl: String?, val timeLeftSeconds: Long?,
)

data class QuizStart(
    val title: String, val info: List<String>, val attempts: List<PortalTable>,
    val action: String?, val fields: List<Pair<String, String>>, val buttonTitle: String,
)

sealed class QuizContent {
    data class Start(val start: QuizStart) : QuizContent()
    data class Attempt(val page: QuizAttemptPage) : QuizContent()
    data class Summary(val summary: QuizSummary) : QuizContent()
    data class Review(val title: String, val rows: List<Pair<String, String>>, val url: String) : QuizContent()
    data class Unknown(val text: String) : QuizContent()
}

object QuizKind {
    fun label(name: String) = if ("самостоят" in name.lowercase().replace('ё', 'е')) "Самостоятельная работа" else "Тест"
}

object QuizParser {
    private fun clean(s: String) = PortalParser.clean(s)
    private fun resolve(base: String, href: String) = runCatching { URI(base).resolve(href.trim()).toString() }.getOrNull()
        ?.takeIf { PortalConfiguration.allowsDataURL(it) }
    private fun hidden(form: Element) = form.select("input[type=hidden][name]").map { it.attr("name") to it.attr("value") }
    private fun timer(html: String) = Regex("M\\.mod_quiz\\.timer\\.init\\(Y,\\s*(\\d+)").find(html)?.groupValues?.get(1)?.toLongOrNull()?.takeIf { it > 0 }

    fun parse(html: String, url: String): QuizContent {
        val doc = Jsoup.parse(html, url)
        val title = clean(doc.selectFirst("#page-header h1, .page-header-headings h1")?.text().orEmpty())
            .ifEmpty { clean(doc.title()).substringBefore(':').ifEmpty { "Тест" } }
        doc.selectFirst("form#responseform")?.let { return QuizContent.Attempt(attempt(it, html, url, title)) }
        if (doc.select("table.quizsummaryofattempt, form input[name=finishattempt]").isNotEmpty())
            return QuizContent.Summary(summary(doc, html, url, title))
        doc.selectFirst("table.quizreviewsummary")?.let { table ->
            return QuizContent.Review(title, table.select("tr").mapNotNull { r ->
                val k = clean(r.select("th").text()); val v = clean(r.select("td").text())
                if (k.isEmpty() || v.isEmpty()) null else k to v
            }, url)
        }
        doc.selectFirst("form[action*=startattempt.php]")?.let { form ->
            val tables = runCatching { PortalPagesParser.document(html, url).tables }.getOrDefault(emptyList())
            val button = clean(form.selectFirst("button")?.text().orEmpty())
                .ifEmpty { form.selectFirst("input[type=submit]")?.attr("value").orEmpty() }.ifEmpty { "Начать тестирование" }
            return QuizContent.Start(QuizStart(title,
                doc.select("#region-main .quizinfo p, #region-main #intro p").map { clean(it.text()) }.filter { it.isNotEmpty() },
                tables, resolve(url, form.attr("action")), hidden(form), button))
        }
        return QuizContent.Unknown(PortalExtrasParser.notice(html)?.first
            ?: runCatching { PortalPagesParser.document(html, url).paragraphs.firstOrNull() }.getOrNull()
            ?: "Страница теста не распознана.")
    }

    private fun attempt(form: Element, html: String, url: String, title: String): QuizAttemptPage {
        val action = resolve(url, form.attr("action"))?.takeIf { "processattempt.php" in it } ?: throw PortalFailure.Parse("форма теста")
        val entries = mutableListOf<QuizEntry>()
        val checked = mutableSetOf<String>()
        var next: Pair<String, String>? = null
        var previous: Pair<String, String>? = null
        for (e in form.select("input[name], select[name], textarea[name]")) {
            val name = e.attr("name")
            when (e.tagName()) {
                "select" -> entries += QuizEntry.Input(name, e.selectFirst("option[selected]")?.attr("value").orEmpty())
                "textarea" -> entries += QuizEntry.Input(name, e.text())
                else -> when (e.attr("type").lowercase()) {
                    "hidden" -> entries += QuizEntry.Hidden(name, e.attr("value"))
                    "radio", "checkbox" -> {
                        val id = e.id().ifEmpty { "$name=${e.attr("value")}" }
                        if (e.hasAttr("checked")) checked += id
                        entries += QuizEntry.Choice(id, name, e.attr("value"))
                    }
                    "submit" -> { if (name == "next") next = name to e.attr("value"); if (name == "previous") previous = name to e.attr("value") }
                    "image", "button", "file" -> {}
                    else -> entries += QuizEntry.Input(name, e.attr("value"))
                }
            }
        }
        val questions = form.select(".que").map { question(it, url) }
        if (questions.isEmpty()) throw PortalFailure.Parse("вопросы теста")
        val page = entries.filterIsInstance<QuizEntry.Hidden>().firstOrNull { it.name == "thispage" }?.value?.toIntOrNull() ?: 0
        return QuizAttemptPage(title, url, action, entries, questions, next, previous, timer(html), page, checked)
    }

    private fun question(que: Element, url: String): QuizQuestion {
        val type = que.classNames().firstOrNull { it != "que" }.orEmpty()
        val qtext = que.selectFirst(".qtext")
        fun label(input: Element): String {
            val id = input.id()
            if (id.isNotEmpty()) que.selectFirst("label[for=\"$id\"]")?.let { return clean(it.text()) }
            return clean(input.parent()?.text().orEmpty())
        }
        val radios = que.select("input[type=radio]")
        val boxes = que.select("input[type=checkbox]")
        val texts = que.select(".ablock input[type=text], .answer input[type=text]")
        val areas = que.select("textarea[name]")
        val selects = que.select("select[name]")
        val answer = when {
            type in setOf("ddimageortext", "ddmarker", "ddwtos", "ordering") || que.select("input[type=file]").isNotEmpty() -> QuizAnswer.Unsupported(type)
            radios.isNotEmpty() -> {
                val options = radios.map { QuizOption(it.id().ifEmpty { "${it.attr("name")}=${it.attr("value")}" }, it.attr("name"), it.attr("value"), label(it)) }
                    .filter { it.value != "-1" && it.label.isNotEmpty() } // «Очистить мой выбор» is not an answer
                QuizAnswer.Single(options.firstOrNull()?.name.orEmpty(), options)
            }
            boxes.isNotEmpty() -> QuizAnswer.Multiple(boxes.map { QuizOption(it.id(), it.attr("name"), it.attr("value"), label(it)) })
            areas.isNotEmpty() -> QuizAnswer.Text(areas.first()!!.attr("name"), true)
            texts.isNotEmpty() -> QuizAnswer.Text(texts.first()!!.attr("name"), false)
            selects.isNotEmpty() -> QuizAnswer.Selects(selects.map { s ->
                QuizSelect(s.attr("name"), clean(s.parents().firstOrNull { it.tagName() == "tr" }?.selectFirst("td.text, .text")?.text().orEmpty()),
                    s.select("option").map { it.attr("value") to clean(it.text()) })
            })
            else -> QuizAnswer.Unsupported(type)
        }
        return QuizQuestion(que.id(), clean(que.select(".qno").text()), clean(que.select(".state").text()),
            clean(que.select(".grade").text()), clean(que.select(".prompt").text()),
            PortalExtrasParser.plainText(qtext?.html().orEmpty()),
            qtext?.select("img[src]")?.mapNotNull { resolve(url, it.attr("src")) }.orEmpty(), answer)
    }

    private fun summary(doc: Document, html: String, url: String, title: String): QuizSummary {
        val rows = doc.select("table.quizsummaryofattempt tbody tr").mapNotNull { r ->
            val cells = r.select("td, th").map { clean(it.text()) }
            if (cells.size >= 2) cells[0] to cells[1] else null
        }
        val finish = doc.select("form").firstOrNull { it.select("input[name=finishattempt]").isNotEmpty() }
        // «Вернуться к попытке» is a GET form whose hidden fields (attempt, cmid) belong in the URL.
        val back = doc.select("form[action*=attempt.php], a[href*=attempt.php]").mapNotNull { e ->
            if (e.tagName() == "form") resolve(url, e.attr("action"))?.let { base ->
                base + (if ('?' in base) "&" else "?") + hidden(e).joinToString("&") { (k, v) -> "$k=$v" }
            } else resolve(url, e.attr("href"))
        }.firstOrNull { it.substringBefore('?').endsWith("/attempt.php") }
        return QuizSummary(title, rows, finish?.let { resolve(url, it.attr("action")) }, finish?.let(::hidden).orEmpty(), back, timer(html))
    }
}
