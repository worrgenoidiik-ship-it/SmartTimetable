package com.anton.smartulsu

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.setContent
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.anton.smartulsu.core.NotificationDestination
import com.anton.smartulsu.ui.SmartTableRoot
import com.anton.smartulsu.ui.theme.SmartULSUTheme

class MainActivity : FragmentActivity() {
    private var locked by mutableStateOf(false)
    private var requestedDestination by mutableStateOf<NotificationDestination?>(null)
    private var authenticationRunning = false
    private val app
        get() = application as SmartTableApplication

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestedDestination = PortalNotifier.destination(intent)
        locked = app.preferences.state.value.appLock
        setContent {
            val preferences by app.preferences.state.collectAsState()
            SideEffect {
                if (preferences.appLock) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
            SmartULSUTheme(preferences.dark, preferences.christmas) {
                SmartTableRoot(
                    app,
                    locked,
                    { authenticate() },
                    { setAppLock(it) },
                    { locked = false },
                    requestedDestination,
                    {
                        requestedDestination = null
                        intent.removeExtra(PortalNotifier.DESTINATION_EXTRA)
                        intent.removeExtra("openInbox")
                    },
                )
            }
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        requestedDestination = PortalNotifier.destination(intent)
    }

    override fun onStop() {
        app.touchSessionOnLeaving()
        if (app.preferences.state.value.appLock) locked = true
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        if (locked) authenticate()
    }

    private fun authenticators() =
        if (Build.VERSION.SDK_INT >= 30)
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
        else BiometricManager.Authenticators.BIOMETRIC_STRONG

    private fun setAppLock(enabled: Boolean): Boolean {
        if (
            enabled &&
                BiometricManager.from(this).canAuthenticate(authenticators()) !=
                    BiometricManager.BIOMETRIC_SUCCESS
        )
            return false
        app.preferences.update { it.copy(appLock = enabled) }
        if (enabled) {
            locked = true
            authenticate()
        }
        return true
    }

    private fun authenticate() {
        if (authenticationRunning || !locked) return
        authenticationRunning = true
        val prompt =
            BiometricPrompt(
                this,
                ContextCompat.getMainExecutor(this),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(
                        result: BiometricPrompt.AuthenticationResult
                    ) {
                        authenticationRunning = false
                        locked = false
                    }

                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        authenticationRunning = false
                    }
                },
            )
        val info =
            BiometricPrompt.PromptInfo.Builder()
                .setTitle("Вход в SmartTimetable")
                .setSubtitle("Подтвердите, что это вы")
                .setAllowedAuthenticators(authenticators())
        if (Build.VERSION.SDK_INT < 30) info.setNegativeButtonText("Отмена")
        prompt.authenticate(info.build())
    }
}
