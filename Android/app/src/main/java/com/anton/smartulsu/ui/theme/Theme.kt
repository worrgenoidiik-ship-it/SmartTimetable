package com.anton.smartulsu.ui.theme

import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

@Composable
fun SmartULSUTheme(
    darkTheme: Boolean = true,
    christmas: Boolean = false,
    content: @Composable () -> Unit,
) {
    val accent = if (christmas) Color(0xFFD92936) else Color(0xFF1686FF)
    val scheme =
        if (darkTheme)
            darkColorScheme(
                primary = accent,
                onPrimary = Color.White,
                background = Color(0xFF090A0D),
                surface = Color(0xFF191B20),
                surfaceVariant = Color(0xFF24272E),
                onSurface = Color(0xFFF3F5F8),
                onSurfaceVariant = Color(0xFF9DA5B4),
                secondary = Color(0xFF42C68A),
            )
        else
            lightColorScheme(
                primary = accent,
                onPrimary = Color.White,
                background = Color(0xFFF2F4F8),
                surface = Color.White,
                surfaceVariant = Color(0xFFE9EDF4),
                onSurface = Color(0xFF172134),
                onSurfaceVariant = Color(0xFF677287),
            )
    MaterialTheme(colorScheme = scheme, typography = Typography, content = content)
}
