package io.github.nanomuse.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.unit.dp

/** 思考与执行区域共用的配色，跟随应用主题而不是系统主题。 */
@Immutable
internal data class NivoProcessColors(val background: Color, val foreground: Color, val border: Color)

private val LIGHT_PROCESS_COLORS = NivoProcessColors(Color(0xFFEDF5FF), Color(0xFF325879), Color(0xFFD5E6F7))
private val DARK_PROCESS_COLORS = NivoProcessColors(Color(0xFF1B2D41), Color(0xFFC1D8F0), Color(0xFF34506D))

/** 以当前画布亮度选择浅蓝或深蓝底，保持过程文字的可读性。 */
@Composable
internal fun nivoProcessColors(): NivoProcessColors =
    if (MaterialTheme.colorScheme.surface.luminance() < 0.5f) DARK_PROCESS_COLORS else LIGHT_PROCESS_COLORS

/** 短状态使用胶囊形，长详情使用大圆角；不引入额外动画或布局层。 */
internal fun Modifier.nivoProcessSurface(colors: NivoProcessColors, isExpanded: Boolean = false): Modifier {
    val shape = if (isExpanded) RoundedCornerShape(20.dp) else RoundedCornerShape(percent = 50)
    return clip(shape).background(colors.background).border(1.dp, colors.border, shape)
}
