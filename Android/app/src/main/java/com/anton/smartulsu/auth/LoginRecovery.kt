package com.anton.smartulsu.auth

/** Pure decisions shared by the WebView controller and regression tests. */
internal object LoginRecovery {
    enum class Decision { WAIT, READY, REJECTED }

    fun decide(
        submitted: LoginForm?,
        observed: LoginForm,
        pending: Boolean,
        error: String,
        outcome: String,
        sameDocument: Boolean,
        navigated: Boolean,
        freshResponse: Boolean,
    ): Decision {
        if (pending) return Decision.WAIT
        if (submitted == null) return Decision.READY
        if (submitted == LoginForm.CREDENTIALS && observed == LoginForm.CODE) return Decision.READY
        if (submitted == LoginForm.CODE) {
            if (observed == LoginForm.CREDENTIALS && navigated && !sameDocument) return Decision.READY
            return if (observed == LoginForm.CODE && sameDocument && freshResponse &&
                outcome == "rejected" && error.isNotBlank()) Decision.REJECTED else Decision.WAIT
        }
        return if (error.isNotBlank() && navigated && !sameDocument) Decision.READY else Decision.WAIT
    }
}
