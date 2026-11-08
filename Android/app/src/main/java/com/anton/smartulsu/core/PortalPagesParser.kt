package com.anton.smartulsu.core

import java.net.URI
import java.time.Instant
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element

/**
 * Port of the iOS PortalPagesParser (1.1). Only news_items is confirmed by a saved page
 * (version2.html); course pages and the calendar follow standard Moodle markup; CDO
 * pages use the generic [document] reader. Every parser throws instead of returning an
 * empty result it cannot justify, so the cache keeps the last good data.
 */
object PortalPagesParser {
    private fun clean(s: String) = PortalParser.clean(s)
    private fun fail(s: String): Nothing = throw PortalFailure.Parse(s)

    private fun portalURL(href: String, source: String): String? =
        runCatching { URI(source).resolve(href.trim()).toString() }.getOrNull()
            ?.takeIf { PortalConfiguration.allowsDataURL(it) }

    private fun Element.insideTable() = parents().any { it.tagName() == "table" }

    private fun cellText(e: Element) =
        e.html().split(Regex("<br\\s*/?>", RegexOption.IGNORE_CASE))
            .map { clean(Jsoup.parse(it).text()) }
            .filter { it.isNotEmpty() }
            .joinToString("\n")

    // ---- Session keep-alive ----

    /** M.cfg.sesskey printed into every Moodle page. */
    fun sesskey(html: String): String? =
        Regex("\"sesskey\"\\s*:\\s*\"([A-Za-z0-9]{6,64})\"").find(html)?.groupValues?.get(1)

    /** Parses the service.php batch answer; any error means the session must be re-checked. Returns seconds left. */
    fun sessionTouchResult(json: String): Long? {
        val root = runCatching { com.google.gson.JsonParser.parseString(json) }.getOrNull() ?: throw PortalFailure.InvalidResponse()
        if (root.isJsonObject && root.asJsonObject.has("error")) throw PortalFailure.LoginRequired()
        if (!root.isJsonArray || root.asJsonArray.size() == 0) throw PortalFailure.InvalidResponse()
        val results = root.asJsonArray.map { it.asJsonObject }
        if (results.any { it.get("error")?.takeIf { e -> e.isJsonPrimitive }?.asBoolean == true }) throw PortalFailure.LoginRequired()
        val data = results.getOrNull(1)?.get("data")?.takeIf { it.isJsonObject }?.asJsonObject ?: return null
        return data.get("timeremaining")?.asLong?.takeIf { it > 0 }
    }

    // ---- Generic page ----

    fun document(html: String, source: String): PortalDocument {
        val doc = Jsoup.parse(html, source)
        val main = doc.selectFirst("#region-main [role=main]") ?: doc.selectFirst("#region-main")
            ?: doc.selectFirst("[role=main]") ?: fail("содержимое страницы")
        main.select("script, style, noscript, template, .sr-only, .accesshide, .skip-block, [hidden], .modal").remove()
        val title = clean(main.selectFirst("h1, h2")?.text().orEmpty())
            .ifEmpty { clean(doc.title()).substringBefore(':') }

        val tables = main.select("table").filter { !it.insideTable() }.mapNotNull { readTable(it, doc) }

        val seenText = mutableSetOf<String>()
        val paragraphs = main.select("h3, h4, h5, p, li, dt, dd, .alert, .box, .generalbox").asSequence()
            .filter { !it.insideTable() }
            // Jsoup's select() includes the element itself, so exclude it when looking for children.
            .filter { it.tagName() == "li" || it.select("p, li, table").none { child -> child !== it } }
            .map { clean(it.text()) }
            .filter { it.length in 2 until 2_000 && seenText.add(it) }
            .take(200).toList()

        val seenLinks = mutableSetOf<String>()
        val links = main.select("a[href]").asSequence()
            .filter { !it.insideTable() }
            .mapNotNull { a ->
                // In-page anchors (#sem1) are tab switches, not destinations.
                if (a.attr("href").trim().startsWith("#")) return@mapNotNull null
                val url = portalURL(a.attr("href"), source) ?: return@mapNotNull null
                if ('#' in url && url.substringBefore('#') == source.substringBefore('#')) return@mapNotNull null
                val text = clean(a.text())
                if (text.isEmpty() || "sesskey" in url || "/login/" in url || !seenLinks.add(url)) null
                else PortalLink(text, url)
            }
            .take(100).toList()

        // A bare sentence such as «Текущая успеваемость не найдена!» is a notice, not an unknown page.
        val notice = if (tables.isEmpty() && paragraphs.isEmpty())
            clean(main.text()).takeIf { it.isNotEmpty() && it.length < 600 && it != title } else null
        if (tables.isEmpty() && paragraphs.isEmpty() && notice == null) fail("содержимое страницы «$title»")
        if (notice != null) return PortalDocument(title, tables, listOf(notice), links)
        return PortalDocument(title, tables, if (tables.isEmpty()) paragraphs else paragraphs.take(30), links)
    }

    private fun readTable(table: Element, doc: Document): PortalTable? {
        val rows = table.select("tr").filter { r -> r.parents().firstOrNull { it.tagName() == "table" } === table }
        var headers = emptyList<String>()
        val body = mutableListOf<List<String>>()
        for (row in rows) {
            val cells = row.children().filter { it.tagName() in listOf("td", "th") }
            if (cells.isEmpty()) continue
            val texts = cells.flatMap { cell ->
                val span = (cell.attr("colspan").toIntOrNull() ?: 1).coerceIn(1, 12)
                listOf(cellText(cell)) + List(span - 1) { "" }
            }
            if (texts.all { it.isEmpty() }) continue
            val isHeader = cells.all { it.tagName() == "th" } || row.parent()?.tagName() == "thead"
            if (isHeader && body.isEmpty()) headers = texts else body += texts
        }
        if (body.isEmpty()) return null
        var caption = clean(table.selectFirst("caption")?.text().orEmpty())
        if (caption.isEmpty()) {
            val pane = table.parents().firstOrNull { it.hasClass("tab-pane") }
            val id = pane?.id().orEmpty()
            if (id.isNotEmpty()) caption = clean(doc.selectFirst("a[href=\"#$id\"]")?.text().orEmpty())
        }
        if (caption.isEmpty()) {
            val previous = table.previousElementSibling()
            if (previous != null && previous.tagName() in listOf("h2", "h3", "h4", "h5")) caption = clean(previous.text())
        }
        return PortalTable(caption, headers, body)
    }

    // ---- Dashboard news (block_news_items, confirmed in version2.html) ----

    fun news(html: String, source: String): List<NewsItem> {
        val doc = Jsoup.parse(html, source)
        val block = doc.selectFirst("[data-block=news_items]") ?: fail("блок объявлений")
        val posts = block.select(".post")
        val items = posts.mapNotNull { post ->
            val link = post.selectFirst(".info a[href]") ?: return@mapNotNull null
            val url = portalURL(link.attr("href"), source) ?: return@mapNotNull null
            val title = clean(link.text()).ifEmpty { return@mapNotNull null }
            val id = url.substringAfter("d=", "").substringBefore('&').ifEmpty { StableID.make(url) }
            NewsItem(id, title, clean(post.select(".name").text()), clean(post.select(".date").text()), url)
        }
        if (items.isEmpty() && posts.isNotEmpty()) fail("объявления")
        return items
    }

    // ---- Course page (standard Moodle: li.section > li.activity.modtype_*) ----

    fun courseContents(html: String, source: String): List<CourseSection> {
        val doc = Jsoup.parse(html, source)
        val sections = doc.select("li.section, li[data-for=section]")
        if (sections.isEmpty()) fail("разделы курса")
        val result = sections.mapIndexedNotNull { index, section ->
            val title = clean(section.selectFirst(".sectionname, h3.section-title, [data-for=section_title]")?.text().orEmpty())
            val summary = clean(section.selectFirst(".summary, .summarytext")?.text().orEmpty())
            val activities = section.select("li.activity").mapNotNull { activity ->
                val kind = activity.classNames().firstOrNull { it.startsWith("modtype_") }?.removePrefix("modtype_").orEmpty()
                val nameElement = activity.selectFirst(".instancename, .activityname, [data-activityname]")
                nameElement?.select(".accesshide")?.remove()
                var name = clean(nameElement?.text().orEmpty())
                if (name.isEmpty() && kind == "label") name = clean(activity.text())
                if (name.isEmpty()) return@mapNotNull null
                val href = activity.selectFirst("a.aalink[href], a[href*='/mod/']")?.attr("href").orEmpty()
                val info = clean(activity.select(".activity-dates, [data-region=activity-dates], .availabilityinfo, .contentafterlink .text-muted").text())
                CourseActivity(
                    activity.id().ifEmpty { StableID.make(index.toString(), name, href) },
                    if (kind == "label") name.take(300) else name, kind, info,
                    if (href.isEmpty()) null else portalURL(href, source),
                )
            }
            if (title.isEmpty() && activities.isEmpty() && summary.isEmpty()) null
            else CourseSection(
                section.id().ifEmpty { "section-$index" },
                title.ifEmpty { if (index == 0) "Общее" else "Раздел $index" },
                summary.take(600), activities,
            )
        }
        if (result.isEmpty()) fail("содержимое курса")
        return result
    }

    // ---- Upcoming events (calendar/view.php?view=upcoming) ----

    fun deadlines(html: String, source: String): List<DeadlineItem> {
        val doc = Jsoup.parse(html, source)
        val main = doc.selectFirst("#region-main") ?: fail("календарь")
        val events = main.select("[data-type=event][data-event-id], .event[data-event-id]")
        if (events.isEmpty()) {
            val text = clean(main.text()).lowercase().replace('ё', 'е')
            if ("нет предстоящих" in text || "no upcoming" in text) return emptyList()
            fail("список событий календаря")
        }
        val seen = mutableSetOf<String>()
        return events.mapNotNull { event ->
            val id = event.attr("data-event-id")
            if (id.isEmpty() || !seen.add(id)) return@mapNotNull null
            val title = clean(event.attr("data-event-title").ifEmpty { event.selectFirst("h3.name, .name")?.text().orEmpty() })
            if (title.isEmpty()) return@mapNotNull null
            val whenLabel = clean(event.selectFirst(".description .row, .description .col-11, .description div")?.text().orEmpty())
            val dayLink = event.selectFirst("a[href*='view=day'][href*='time=']")?.attr("href").orEmpty()
            val action = event.selectFirst(".card-footer a[href], a.card-link[href]")?.attr("href").orEmpty()
            DeadlineItem(
                id, title, clean(event.selectFirst("a[href*='/course/view.php']")?.text().orEmpty()),
                event.attr("data-event-component"), whenLabel, dueMillis(dayLink, whenLabel),
                if (action.isEmpty()) null else portalURL(action, source),
            )
        }.sortedWith(compareBy({ it.due ?: Long.MAX_VALUE }, { it.id }))
    }

    /** The day link carries a Unix timestamp of that day; the label carries HH:mm. */
    fun dueMillis(dayLink: String, label: String): Long? {
        val seconds = Regex("[?&]time=(\\d+)").find(dayLink.replace("&amp;", "&"))?.groupValues?.get(1)?.toLongOrNull()
            ?: return null
        val time = Regex("\\b([01]?\\d|2[0-3]):([0-5]\\d)\\b").findAll(label).lastOrNull() ?: return null
        val day = Instant.ofEpochSecond(seconds).atZone(CampusDate.zone).toLocalDate()
        return day.atTime(time.groupValues[1].toInt(), time.groupValues[2].toInt())
            .atZone(CampusDate.zone).toInstant().toEpochMilli()
    }
}
