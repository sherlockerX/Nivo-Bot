package io.github.nanomuse.ui.focus

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path

/** 静态矢量山景占位，不加载远程图片，也没有逐帧绘制动画。 */
@Composable
internal fun FocusLandscape(modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val width = size.width
        val height = size.height
        drawRect(Brush.verticalGradient(listOf(Color(0xFF213A43), Color(0xFF789C91), Color(0xFFD1CDB3))))
        drawCircle(Color(0xFFF3E8C7).copy(alpha = .75f), width * .10f, Offset(width * .78f, height * .25f))
        fun mountain(level: Float, color: Color, shift: Float) {
            val path = Path().apply {
                moveTo(0f, height)
                lineTo(0f, height * level)
                cubicTo(width * .18f, height * (level - .15f), width * .30f, height * (level + shift), width * .52f, height * (level - .04f))
                cubicTo(width * .70f, height * (level - .20f), width * .88f, height * (level + .02f), width, height * (level - .07f))
                lineTo(width, height)
                close()
            }
            drawPath(path, color)
        }
        mountain(.68f, Color(0xFF698A83), .06f)
        mountain(.80f, Color(0xFF345D5A), -.04f)
        mountain(.93f, Color(0xFF183E42), -.07f)
    }
}
