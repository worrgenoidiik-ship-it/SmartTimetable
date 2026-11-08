package com.anton.smartulsu.core

import com.google.gson.Gson
import org.junit.Assert.*
import org.junit.Test

class LoginMessagesTest {
    @Test fun singleAndDuplicatedSessionExpiryUseOneRussianMessage() {
        val english = "Your session has timed out. Please log in again."
        for (message in listOf(english, "$english $english", "$english\n\u00a0$english", LoginMessages.SESSION_EXPIRED.repeat(2))) {
            val raw = Gson().toJson(Gson().toJson(mapOf("kind" to "credentials", "error" to message)))
            assertEquals(LoginMessages.SESSION_EXPIRED, LoginBridgeCodec.decode(raw)!!["error"].asString)
        }
    }

    @Test fun maxRetryEvidenceAndOtherMessagesArePreserved() {
        val raw = Gson().toJson("""{"kind":"code","error":"Неверный или просроченный код","pending":false,"outcome":"rejected","documentId":"same","responseRevision":2}""")
        val result = LoginBridgeCodec.decode(raw)!!
        assertEquals("Неверный или просроченный код", result["error"].asString)
        assertFalse(result["pending"].asBoolean)
        assertEquals("rejected", result["outcome"].asString)
        assertEquals("same", result["documentId"].asString)
        assertEquals(2, result["responseRevision"].asInt)
        assertEquals("Неверный пароль", LoginMessages.normalize("Неверный пароль"))
    }
}
