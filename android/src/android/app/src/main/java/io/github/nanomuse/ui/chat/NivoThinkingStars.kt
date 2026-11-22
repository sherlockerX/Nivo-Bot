package io.github.nanomuse.ui.chat

import android.animation.ValueAnimator
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.MotionDurationScale
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlin.math.cos
import kotlin.math.PI

private const val CYCLE_MS = 800
private const val STAGGER_MS = 150

/** 在固定尺寸内绘制三颗四芒星。邻近的状态文字负责朗读，动画不产生额外的无障碍节点。 */
@Composable
internal fun NivoThinkingStars(color: Color, isVisible: Boolean, modifier: Modifier = Modifier.size(24.dp)) {
    val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateFlow.collectAsState()
    val scale = rememberCoroutineScope().coroutineContext[MotionDurationScale]?.scaleFactor
    val hasMotion = scale?.let { it > 0f } ?: ValueAnimator.areAnimatorsEnabled()
    val phase = if (isVisible && lifecycle.isAtLeast(Lifecycle.State.STARTED) && hasMotion) {
        rememberInfiniteTransition(label = "thinking-stars").animateFloat(
            initialValue = 0f, targetValue = 1f,
            animationSpec = infiniteRepeatable(tween(CYCLE_MS, easing = LinearEasing)), label = "phase",
        )
    } else null

    Spacer(modifier.drawWithCache {
        val unit = size.minDimension / 24f
        val star = Path().apply {
            moveTo(0f, -1f)
            quadraticTo(.14f, -.14f, 1f, 0f)
            quadraticTo(.14f, .14f, 0f, 1f)
            quadraticTo(-.14f, .14f, -1f, 0f)
            quadraticTo(-.14f, -.14f, 0f, -1f)
            close()
        }
        onDrawBehind {
            // 只在绘制阶段读取相位，逐帧变化不会重新排版聊天列表。
            val progress = phase?.value
            fun drawStar(index: Int, x: Float, y: Float, radius: Float) {
                val pulse = progress?.let {
                    ((1.0 - cos(2.0 * PI * (it - index * STAGGER_MS.toFloat() / CYCLE_MS))) / 2.0).toFloat()
                } ?: 1f
                val sizePx = radius * unit * (.80f + .20f * pulse)
                withTransform({ translate(x * unit, y * unit); scale(sizePx, sizePx, Offset.Zero) }) {
                    drawPath(star, color, alpha = .60f + .40f * pulse)
                }
            }
            drawStar(0, 14.3f, 14.6f, 7.4f)
            drawStar(1, 6.3f, 7.2f, 4.5f)
            drawStar(2, 17.7f, 4.8f, 2.9f)
        }
    })
}
