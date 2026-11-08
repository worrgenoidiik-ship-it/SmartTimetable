package com.anton.smartulsu.core

import org.junit.Assert.*
import org.junit.Test

/** Same cases as the iOS QuizTests (structure of a real attempt page, identifiers replaced). */
class QuizTest {
    private val url = "https://portal.ulsu.ru/mod/quiz/attempt.php?attempt=1&cmid=2"
    private fun page(questions: String, previous: Boolean = false) = """
        <html><body><div id="page-header"><h1>Маркетинг</h1></div><section id="region-main">
        <form action="https://portal.ulsu.ru/mod/quiz/processattempt.php?cmid=2" method="post" id="responseform"><div>
        $questions
        <div class="submitbtns">${if (previous) "<input type=\"submit\" name=\"previous\" value=\"Предыдущая страница\">" else ""}<input type="submit" name="next" value="Следующая страница"></div>
        <input type="hidden" name="attempt" value="1"><input type="hidden" name="thispage" value="0"><input type="hidden" name="timeup" value="0">
        <input type="hidden" name="sesskey" value="AbCdEf1234"><input type="hidden" name="slots" value="1">
        </div></form></section><script>M.mod_quiz.timer.init(Y, 900, 0);</script></body></html>"""

    private val multichoice = """
        <div id="question-5-1" class="que multichoice notyetanswered"><span class="qno">1</span><div class="state">Пока нет ответа</div><div class="grade">Балл: 1,00</div>
        <input type="hidden" name="q5:1_:sequencecheck" value="1"><div class="qtext">Какие факторы не входят в маркетинговую среду фирмы:</div>
        <div class="ablock"><div class="prompt">Выберите один или несколько ответов:</div><div class="answer">
        <div><input type="hidden" name="q5:1_choice0" value="0"><input type="checkbox" name="q5:1_choice0" value="1" id="q5:1_choice0"><label for="q5:1_choice0">a. Мезофакторы.</label></div>
        <div><input type="hidden" name="q5:1_choice1" value="0"><input type="checkbox" name="q5:1_choice1" value="1" id="q5:1_choice1"><label for="q5:1_choice1">b. Микрофакторы.</label></div>
        </div></div></div>"""

    @Test fun multipleChoiceAndPayloadOrder() {
        val attempt = (QuizParser.parse(page(multichoice), url) as QuizContent.Attempt).page
        assertEquals("Маркетинг", attempt.title)
        assertEquals(900L, attempt.timeLeftSeconds)
        val q = attempt.questions.single()
        assertEquals("Какие факторы не входят в маркетинговую среду фирмы:", q.text)
        val options = (q.answer as QuizAnswer.Multiple).options
        assertEquals(listOf("a. Мезофакторы.", "b. Микрофакторы."), options.map { it.label })
        val pairs = attempt.payload(emptyMap(), setOf(options[1].id), attempt.next).map { "${it.first}=${it.second}" }
        assertTrue(pairs.indexOf("q5:1_choice1=0") < pairs.indexOf("q5:1_choice1=1"))
        assertFalse("q5:1_choice0=1" in pairs)
        assertEquals("next=Следующая страница", pairs.last())
        assertTrue(("timeup" to "1") in attempt.payload(emptyMap(), emptySet(), null, timeUp = true))
    }

    @Test fun singleChoiceTextAndUnsupported() {
        val html = page("""
            <div id="question-5-2" class="que multichoice"><span class="qno">2</span><div class="qtext">Столица?</div>
            <input type="radio" name="q5:2_answer" value="0" id="a0"><label for="a0">Москва</label>
            <input type="radio" name="q5:2_answer" value="1" id="a1" checked="checked"><label for="a1">Казань</label>
            <input type="radio" name="q5:2_answer" value="-1" id="a2"><label for="a2">Очистить мой выбор</label></div>
            <div id="question-5-3" class="que essay"><span class="qno">3</span><div class="qtext">Опишите</div><textarea name="q5:3_answer">черновик</textarea></div>
            <div id="question-5-4" class="que ddimageortext"><span class="qno">4</span><div class="qtext">Перетащите</div></div>""", previous = true)
        val attempt = (QuizParser.parse(html, url) as QuizContent.Attempt).page
        val single = attempt.questions[0].answer as QuizAnswer.Single
        assertEquals(listOf("Москва", "Казань"), single.options.map { it.label })
        assertEquals("1", attempt.initialValues()[single.name])
        assertEquals("черновик", attempt.initialValues()["q5:3_answer"])
        assertTrue((attempt.questions[1].answer as QuizAnswer.Text).multiline)
        assertTrue(attempt.hasUnsupported)
        assertEquals("previous", attempt.previous?.first)
        val items = attempt.payload(mapOf(single.name to "0"), emptySet(), attempt.next)
        assertTrue((single.name to "0") in items)
        assertFalse((single.name to "1") in items)
    }

    @Test fun summaryAndFinishForm() {
        val html = """<html><body><section id="region-main"><table class="generaltable quizsummaryofattempt"><tbody>
            <tr><td>1</td><td>Ответ сохранен</td></tr><tr><td>2</td><td>Пока нет ответа</td></tr></tbody></table>
            <form method="get" action="https://portal.ulsu.ru/mod/quiz/attempt.php"><input type="hidden" name="attempt" value="1"><input type="hidden" name="cmid" value="2"><button>Вернуться к попытке</button></form>
            <form method="post" action="https://portal.ulsu.ru/mod/quiz/processattempt.php"><input type="hidden" name="attempt" value="1"><input type="hidden" name="finishattempt" value="1"><button>Отправить всё</button></form>
            </section></body></html>"""
        val summary = (QuizParser.parse(html, url) as QuizContent.Summary).summary
        assertEquals(listOf("Ответ сохранен", "Пока нет ответа"), summary.rows.map { it.second })
        assertEquals("https://portal.ulsu.ru/mod/quiz/processattempt.php", summary.finishAction)
        assertTrue(("finishattempt" to "1") in summary.finishFields)
        assertEquals("https://portal.ulsu.ru/mod/quiz/attempt.php?attempt=1&cmid=2", summary.returnUrl)
    }

    @Test fun independentWorkLabel() {
        assertEquals("Самостоятельная работа", CourseActivity("1", "Самостоятельная работа №2", "quiz", "", null).kindLabel)
        assertEquals("Тест", CourseActivity("2", "Итоговый тест", "quiz", "", null).kindLabel)
    }
}

class OverdueTest {
    @Test fun oldCacheWithoutOverdueStillDecodes() {
        val snapshot = com.google.gson.Gson().fromJson("""{"schemaVersion":1}""", PortalSnapshot::class.java)
        assertNull(snapshot.overdue)
        val item = DeadlineItem("2", "Самостоятельная работа №1", "Маркетинг", "mod_quiz", "", 1L, null)
        assertEquals("Самостоятельная работа", item.kindLabel)
    }
}
