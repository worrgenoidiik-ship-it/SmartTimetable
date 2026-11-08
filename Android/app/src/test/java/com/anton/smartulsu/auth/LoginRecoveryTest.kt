package com.anton.smartulsu.auth

import com.anton.smartulsu.auth.LoginRecovery.Decision.*
import org.junit.Assert.assertEquals
import org.junit.Test

class LoginRecoveryTest {
    private fun observe(
        submitted: LoginForm? = LoginForm.CODE,
        observed: LoginForm = LoginForm.CODE,
        pending: Boolean = false,
        error: String = "Неверный или просроченный код",
        outcome: String = "rejected",
        sameDocument: Boolean = true,
        navigated: Boolean = false,
        fresh: Boolean = true,
    ) = LoginRecovery.decide(submitted, observed, pending, error, outcome, sameDocument, navigated, fresh)

    @Test fun confirmedRussianRejectionAllowsRetry() {
        assertEquals(REJECTED, observe())
    }

    @Test fun twoAttemptsRequireTwoFreshConfirmedResponses() {
        for (attempt in 1..2) {
            assertEquals(WAIT, observe(pending = true, fresh = false))
            assertEquals(WAIT, observe(fresh = false))
            assertEquals(REJECTED, observe())
        }
    }

    @Test fun domChangesAndButtonCyclesWithoutResponseStayPending() {
        assertEquals(WAIT, observe(outcome = "", fresh = false))
        assertEquals(WAIT, observe(outcome = "", fresh = true))
    }

    @Test fun navigationAndUnrelatedDocumentCannotAuthorizeCodeRetry() {
        assertEquals(WAIT, observe(navigated = true, sameDocument = false))
        assertEquals(WAIT, observe(navigated = true, sameDocument = false, fresh = false))
    }

    @Test fun unknownAndNetworkOutcomesStayPending() {
        assertEquals(WAIT, observe(pending = true))
        assertEquals(WAIT, observe(error = "", outcome = ""))
    }

    @Test fun expiredChallengeRequiresActualReturnToCredentials() {
        assertEquals(WAIT, observe(pending = true, outcome = "expired"))
        assertEquals(READY, observe(observed = LoginForm.CREDENTIALS, sameDocument = false, navigated = true))
        assertEquals(WAIT, observe(observed = LoginForm.CREDENTIALS))
    }

    @Test fun credentialsAdvanceToMaxWithoutResubmitting() {
        assertEquals(READY, observe(submitted = LoginForm.CREDENTIALS, error = "", outcome = ""))
    }

    @Test fun initialInspectionHonorsBridgePendingEvenWithoutNativeAttempt() {
        assertEquals(WAIT, observe(submitted = null, pending = true))
        assertEquals(READY, observe(submitted = null, pending = false))
    }

    @Test fun credentialErrorsRequireNewDocument() {
        assertEquals(WAIT, observe(submitted = LoginForm.CREDENTIALS, observed = LoginForm.CREDENTIALS))
        assertEquals(READY, observe(submitted = LoginForm.CREDENTIALS, observed = LoginForm.CREDENTIALS,
            sameDocument = false, navigated = true))
    }
}
