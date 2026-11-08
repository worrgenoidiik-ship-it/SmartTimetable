package com.anton.smartulsu.core

import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/** User-facing diagnostics never include request URLs, credentials or exception details. */
object PortalErrors {
    fun message(error: Exception): String = when (error) {
        is PortalFailure -> error.message.orEmpty()
        is UnknownHostException -> "Не удалось найти сервер ЭИОС. Проверьте интернет или VPN. Сохранённые данные доступны."
        is SocketTimeoutException -> "ЭИОС не ответила вовремя. Повторите загрузку позже. Сохранённые данные доступны."
        is SSLException -> "Не удалось установить защищённое соединение с ЭИОС. Сохранённые данные доступны."
        else -> "Не удалось загрузить данные ЭИОС. Проверьте соединение и повторите попытку. Сохранённые данные доступны."
    }

    fun sectionMessage(section: PortalSection, error: Exception): String =
        if (section == PortalSection.COURSES && error is PortalFailure.Parse)
            "Курсы: список не распознан или ещё не загружен страницей ЭИОС. " +
                "Нажмите «Загрузить карточки курсов». Сохранённые курсы доступны."
        else "${section.title}: ${message(error)}"
}
