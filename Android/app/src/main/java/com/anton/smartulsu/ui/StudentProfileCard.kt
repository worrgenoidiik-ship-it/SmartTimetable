package com.anton.smartulsu.ui

import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.updateTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.anton.smartulsu.core.PortalSnapshot

@Composable
internal fun StudentProfileCard(
    snapshot: PortalSnapshot,
    endColor: Color,
    openGradebook: () -> Unit,
    front: @Composable ColumnScope.() -> Unit,
) = key(snapshot.profile?.accountKey) {
    var flipped by rememberSaveable { mutableStateOf(false) }
    val transition = updateTransition(flipped, label = "Student card")
    // Compose's animation clock observes the system animator duration scale (including zero).
    val rotation by transition.animateFloat(transitionSpec = { tween(400) }, label = "Flip") {
        if (it) 180f else 0f
    }
    val backVisible = rotation > 90f
    val idle = transition.currentState == flipped && !transition.isRunning
    Layout(
        modifier = Modifier.fillMaxWidth()
            .graphicsLayer { rotationY = rotation; cameraDistance = 12 * density }
            .clip(RoundedCornerShape(26.dp))
            .background(Brush.verticalGradient(listOf(Color(0xFF101820), endColor)), RoundedCornerShape(26.dp))
            .semantics {
                contentDescription = "Карточка студента"
                stateDescription = if (backVisible) "Учебные данные" else "Лицевая сторона"
            }
            .clickable(enabled = idle, role = Role.Button,
                onClickLabel = if (flipped) "Показать лицевую сторону" else "Показать учебные данные") {
                flipped = !flipped
            },
        content = {
            Column(Modifier.padding(horizontal = 18.dp, vertical = 12.dp), content = front)
            Column(Modifier.graphicsLayer { rotationY = 180f }
                .padding(horizontal = 18.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("УЧЕБНЫЕ ДАННЫЕ", color = Color.White, fontWeight = FontWeight.Bold)
                // Available authenticated responses verify identity and grades only.
                // Do not turn a Moodle ID or a semester label into academic profile data.
                Text("Дополнительные данные пока недоступны", color = Color.White.copy(alpha = .7f),
                    style = MaterialTheme.typography.bodySmall)
                val grades = snapshot.grades?.value
                Text(if (grades == null) "Зачётная книжка ещё не загружена"
                    else "Записей в зачётке: ${grades.size} · Семестров: ${grades.map { it.semester }.distinct().size}",
                    color = Color.White, style = MaterialTheme.typography.bodySmall)
                TextButton(onClick = openGradebook) { Text("Открыть зачётную книжку", color = Color.White) }
            }
        },
    ) { measurables, constraints ->
        // Measure both faces but place only one: dimensions remain stable, while the
        // hidden face has no visible text, focus targets or clickable child controls.
        val faces = measurables.map { it.measure(constraints.copy(minHeight = 0)) }
        layout(faces.maxOf { it.width }, faces.maxOf { it.height }) {
            faces[if (backVisible) 1 else 0].placeRelative(0, 0)
        }
    }
}
