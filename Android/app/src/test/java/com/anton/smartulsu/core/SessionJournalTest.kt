package com.anton.smartulsu.core

import org.junit.Assert.*
import org.junit.Test

class SessionJournalTest {
    private var stored: String? = null
    private var clock = 1_800_000_000_000L
    private val journal = SessionJournal({ stored }, { stored = it }, { clock })

    @Test fun keepsNewestEntriesAndSurvivesGarbage() {
        repeat(SessionJournal.LIMIT + 5) { clock += 1000; journal.add("событие $it") }
        assertEquals(SessionJournal.LIMIT, journal.entries().size)
        assertEquals("событие ${SessionJournal.LIMIT + 4}", journal.entries().last().text)
        assertTrue(journal.text().lines().first().endsWith("событие ${SessionJournal.LIMIT + 4}"))
        stored = "not json"
        assertEquals(emptyList<SessionJournal.Entry>(), journal.entries())
        journal.add("после сбоя")
        assertEquals(1, journal.entries().size)
        journal.clear()
        assertNull(stored)
    }

    @Test fun describesSessionChanges() {
        assertEquals("ЭИОС завершила сессию: нужен вход", SessionJournal.describe(SessionState.ACTIVE, SessionState.NEEDS_LOGIN))
        assertEquals("Вход выполнен, сессия ЭИОС активна", SessionJournal.describe(SessionState.NEEDS_LOGIN, SessionState.ACTIVE))
        assertEquals("Нет связи с ЭИОС", SessionJournal.describe(SessionState.ACTIVE, SessionState.OFFLINE))
        assertNull(SessionJournal.describe(SessionState.ACTIVE, SessionState.ACTIVE))
        assertNull(SessionJournal.describe(SessionState.ACTIVE, SessionState.UNCHECKED))
    }

    @Test fun reportCarriesNoPersonalData() {
        val text = ProblemReport.text("2.0.5", "Android 14", "Pixel 7", "ФКиС-О-23/1", mapOf("Курсы" to "Нет связи"),
            "10.11 12:00:00  Нет связи с ЭИОС", null)
        assertTrue(text.contains("ФКиС-О-23/1"))
        assertTrue(text.contains("Курсы: Нет связи"))
        assertFalse(text.contains("Последнее падение"))
        val crash = ProblemReport.crashSummary("10.11.2026 12:00", "2.0.5", IllegalStateException("boom"))
        assertTrue(crash.contains("IllegalStateException"))
        assertTrue(crash.contains("boom"))
    }
}
