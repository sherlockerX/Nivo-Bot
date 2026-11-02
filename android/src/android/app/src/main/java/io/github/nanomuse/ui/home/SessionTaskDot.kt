package io.github.nanomuse.ui.home

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.service.SessionActivityTracker

/** 对话右侧显示运行和完成状态，只为正在执行的行创建动画。 */
@Composable
fun SessionTaskDot(sessionId: String) {
    val running by SessionActivityTracker.activeSessions.collectAsState()
    val outcomes by SessionActivityTracker.taskOutcomes.collectAsState()
    val isRunning = sessionId in running
    val isFailed = outcomes[sessionId] == false
    if (!isRunning && sessionId !in outcomes) return
    val description = stringResource(when {
        isRunning -> R.string.nm_task_running
        isFailed -> R.string.nm_task_failed
        else -> R.string.nm_task_completed
    })
    val alpha = if (isRunning) {
        rememberInfiniteTransition(label = "sessionTask").animateFloat(
            initialValue = 0.25f, targetValue = 1f,
            animationSpec = infiniteRepeatable(tween(650), RepeatMode.Reverse), label = "pulse",
        ).value
    } else 1f
    Box(Modifier.padding(end = 8.dp).size(9.dp).graphicsLayer { this.alpha = alpha }
        .background(when { isRunning -> Color(0xFFF4BA35); isFailed -> Color(0xFFDD5353); else -> Color(0xFF42AF72) }, CircleShape)
        .semantics { contentDescription = description })
}
