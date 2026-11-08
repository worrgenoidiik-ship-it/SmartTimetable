package com.anton.smartulsu.core

import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException
import org.junit.Assert.*
import org.junit.Test

class PortalErrorsTest {
    @Test fun temporaryFailuresNeverClaimSessionExpiration() {
        val errors = listOf(UnknownHostException("private-host"), SocketTimeoutException("secret"), SSLException("cookie=secret"), PortalFailure.Http(503))
        for (error in errors) {
            val message = PortalErrors.sectionMessage(PortalSection.COURSES, error)
            assertTrue(message.startsWith("Курсы:"))
            assertFalse(message.contains("Сессия завершена"))
            assertFalse(message.contains("secret"))
            assertFalse(message.contains("private-host"))
        }
    }
    @Test fun timeoutAndTlsHaveDifferentAccurateMessages() {
        assertTrue(PortalErrors.message(SocketTimeoutException()).contains("не ответила вовремя"))
        assertTrue(PortalErrors.message(SSLException("private details")).contains("защищённое соединение"))
    }
    @Test fun courseMarkupFailureExplainsRenderedLoadingWithoutClaimingNoEnrollment() {
        val message = PortalErrors.sectionMessage(PortalSection.COURSES, PortalFailure.Parse("список курсов"))
        assertTrue(message.contains("Загрузить карточки курсов"))
        assertTrue(message.contains("Сохранённые курсы"))
        assertFalse(message.contains("не записаны"))
    }
    @Test fun confirmedAuthenticationFailureRetainsOfficialReloginMessage() {
        assertTrue(PortalErrors.sectionMessage(PortalSection.COURSES, PortalFailure.LoginRequired()).contains("Войдите снова"))
    }
}
