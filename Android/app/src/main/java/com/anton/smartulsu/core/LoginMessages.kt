package com.anton.smartulsu.core

/** Presentation only: does not classify the authentication result or change retry evidence. */
object LoginMessages {
    const val SESSION_EXPIRED = "Срок действия сессии истёк. Войдите в ЭИОС повторно."
    private val expiry = Regex(
        "^(?:(?:Your session has timed out\\. Please log in again\\.|" +
            Regex.escape(SESSION_EXPIRED) + ")\\s*)+$",
        RegexOption.IGNORE_CASE,
    )

    fun normalize(message: String): String {
        val text = message.replace(Regex("[\\s\\u00a0]+"), " ").trim()
        return if (expiry.matches(text)) SESSION_EXPIRED else text
    }
}
