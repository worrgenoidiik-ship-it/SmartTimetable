package com.anton.smartulsu.core

import com.google.gson.JsonParser
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

/** Same cases as the iOS MessagingTests / StudentContextTests / EnrichmentAndFormsTests. */
class StudentContextTest {
    private val url = "https://portal.ulsu.ru/course/view.php?id=1"
    private fun course(title: String) = Course(title, title, "", url)
    private fun lesson(day: String, start: String, subject: String, teacher: String = "", place: String = "") =
        ScheduleItem(day + start + subject, day, start, "23:00", "", subject, teacher, place)

    @Test fun courseTitlesSplitReadably() {
        val t = CourseTitle("Базы данных ИС-О-25/1 (3 семестр, Комарова Юлиана Егоровна)")
        assertEquals("Базы данных", t.subject)
        assertEquals(listOf("ИС-О-25/1", "3 семестр", "Комарова Юлиана Егоровна"), t.details)
        assertEquals("Комарова Юлиана Егоровна", t.teacher)
        assertNull(CourseTitle("Безопасность жизнедеятельности").teacher)
        assertEquals("Ж. Н. Донилова", CourseTitle("Психология (Ж. Н. Донилова)").teacher)
    }

    @Test fun groupAndCurrentSemester() {
        assertEquals("ИС-О-25/1", StudentGroup.detect(listOf(course("Базы данных ИС-О-25/1 (3 семестр)"), course("ИС_О_25/1_Web_технологии_4"))))
        assertEquals(3, StudentGroup.currentSemester("ИС-О-25/1", LocalDate.of(2026, 11, 1)))
        assertEquals(3, StudentGroup.currentSemester("ИС-О-25/1", LocalDate.of(2027, 1, 15)))
        assertEquals(4, StudentGroup.currentSemester("ИС-О-25/1", LocalDate.of(2027, 3, 1)))
    }

    @Test fun teachersFromCourseTitlesWhenInitialsAgree() {
        val courses = listOf(
            course("Психология и педагогика ИС-О-25/1 (3 семестр,Данилова Жанна Никитична)"),
            course("Ознакомительная практика ИС-О-25/1 (3 семестр,Комарова Юлиана Егоровна)"),
            course("Иностранный язык ИС-О-25/1 (3 семестр,Морозова Инна Руслановна)"),
        )
        val window = ScheduleWindow(listOf("2026-11-05"), listOf(
            lesson("2026-11-05", "14:15", "Психология и педагогика", "Ж. Н. Донилова"),
            lesson("2026-11-05", "11:00", "Ознакомительная практика"),
            lesson("2026-11-05", "09:30", "Английский язык"),
            lesson("2026-11-05", "08:00", "Психология и педагогика", "А. Б. Другой"),
        ), "manual")
        assertEquals(listOf("Данилова Жанна Никитична", "Комарова Юлиана Егоровна", "Морозова Инна Руслановна", "А. Б. Другой"),
            ScheduleEnricher.enrich(window, courses, null).items.map { it.teacher })
    }

    @Test fun roomFromThePortalSlotOfTheSameSubject() {
        val portal = ScheduleWindow(listOf("2026-11-12"), listOf(lesson("2026-11-12", "11:00", "Базы данных", place = "3/118"),
            lesson("2026-11-12", "11:00", "Физика", place = "2/20")))
        val plan = ScheduleWindow(listOf("2026-11-05"), listOf(lesson("2026-11-05", "11:00", "Базы данных"),
            lesson("2026-11-05", "12:45", "Базы данных")), "manual")
        assertEquals(listOf("3/118", ""), ScheduleEnricher.enrich(plan, emptyList(), portal).items.map { it.place })
    }

    @Test fun formLabelsComeFromTheirRows() {
        val html = """<section id="region-main"><form class="forminquiry mform" action="https://portal.ulsu.ru/CDO/inquiry/index.php" method="post">
            <input name="sesskey" type="hidden" value="AbCdEf1234">
            <div class="form-group row fitem"><label for="id_form_fields_"> Телефон для связи </label><input type="text" name="form_fields[Телефон]" id="id_form_fields_" value=""></div>
            <div class="form-group row fitem"><label for="id_form_fields_"> Вид печати </label><select name="form_fields[ВидПечати]" id="id_form_fields_"><option value="1">без герба</option><option value="2">Герб</option></select></div>
            <input type="submit" name="submitbutton" value="Отправить запрос"></form></section>"""
        val form = PortalExtrasParser.forms(html, "https://portal.ulsu.ru/CDO/inquiry/index.php").single()
        assertTrue(form.isPost)
        assertEquals(listOf("Телефон для связи", "Вид печати"), form.visibleFields.map { it.label })
        val payload = form.payload(mapOf("form_fields[Телефон]" to "+7"))
        assertTrue(("sesskey" to "AbCdEf1234") in payload)
        assertTrue(("form_fields[ВидПечати]" to "1") in payload)
        assertTrue(("submitbutton" to "Отправить запрос") in payload)
    }

    @Test fun ajaxAnswersAndMessenger() {
        assertThrows(PortalFailure.LoginRequired::class.java) {
            PortalExtrasParser.ajaxResult("""[{"error":true,"exception":{"errorcode":"servicerequireslogin"}}]""")
        }
        assertThrows(PortalFailure.Parse::class.java) {
            PortalExtrasParser.ajaxResult("""[{"error":true,"exception":{"errorcode":"nopermissions","message":"Нет прав"}}]""")
        }
        val data = PortalExtrasParser.ajaxResult("""[{"error":false,"data":{"conversations":[{"id":7,"name":"","subname":"","type":1,"unreadcount":2,
            "members":[{"id":501,"fullname":"Комарова Юлиана Егоровна"}],
            "messages":[{"id":90,"useridfrom":501,"text":"<p>Добрый день!<br>Отчёт до пятницы.</p>","timecreated":1793500000}]}]}}]""")
        val c = PortalExtrasParser.conversations(data).single()
        assertEquals("Комарова Юлиана Егоровна", c.title)
        assertEquals("Добрый день!\nОтчёт до пятницы.", c.lastMessage?.text)
        assertThrows(PortalFailure.Parse::class.java) {
            PortalExtrasParser.sentMessages(JsonParser.parseString("""[{"msgid":-1,"errormessage":"Пользователь ограничил сообщения"}]"""))
        }
    }

    @Test fun timelineEventsAndQuestionForm() {
        val events = PortalExtrasParser.actionEvents(JsonParser.parseString("""{"events":[{"id":77,"name":"Лабораторная работа №1","modulename":"assign",
            "timesort":1793600000,"url":"https://portal.ulsu.ru/mod/assign/view.php?id=2","course":{"fullname":"Базы данных ИС-О-25/1 (3 семестр,Комарова Юлиана Егоровна)"}}]}"""))
        assertEquals("Задание", events.single().kindLabel)
        assertEquals("Базы данных", events.single().course)
        assertEquals(1793600000000L, events.single().due)
        val form = PortalExtrasParser.questionForm("""<select id="cat"><option value="a">Общие вопросы</option><option value="b">Учебный процесс</option></select>
            <input id="subject"><textarea id="message"></textarea><input id="reply_type" value="student@ulsu.ru">""")
        assertEquals(listOf("a" to "Общие вопросы", "b" to "Учебный процесс"), form.categories)
        assertEquals("student@ulsu.ru", form.email)
    }
}
