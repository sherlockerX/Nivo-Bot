package io.github.nanomuse.ui.chat

import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * 思考与执行区域共用的配色。过程是回答的附属信息，用中性的弱化文字和细描边，
 * 只有正在进行的图标使用主题强调色，不再用整块浅蓝底和正文争夺注意力。
 */
@Immutable
internal data class NivoProcessColors(
    val background: Color,
    val foreground: Color,
    val border: Color,
    val accent: Color,
)

/** 跟随应用主题取色，深浅两种画布下都保持足够对比度。 */
@Composable
internal fun nivoProcessColors(): NivoProcessColors {
    val scheme = MaterialTheme.colorScheme
    return NivoProcessColors(
        background = Color.Transparent,
        foreground = scheme.onSurfaceVariant,
        border = scheme.outlineVariant,
        accent = scheme.primary,
    )
}

/** 过程标题使用内容宽度的描边小卡片，与回答气泡同一左边线。 */
internal fun Modifier.nivoProcessSurface(colors: NivoProcessColors): Modifier {
    val shape = RoundedCornerShape(16.dp)
    return clip(shape).border(1.dp, colors.border, shape)
}
