package io.github.nanomuse.ui.home

import android.os.Build
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.openminis.app.ui.theme.ChatColors
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect

/** 宠物标题只采样消息层，轻磨砂向下淡出，主体和操作控件在独立前景保持清晰。 */
@Composable
fun MuseHeaderGlass(state: HazeState, modifier: Modifier = Modifier, isVisible: Boolean = true) {
    val background = ChatColors.background
    val tint = background.copy(alpha = if (MuseTones.isDark) 0.22f else 0.16f)
    Box(modifier.hazeEffect(state) {
        blurEnabled = isVisible && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        style = HazeStyle(
            backgroundColor = background,
            blurRadius = 4.dp,
            noiseFactor = 0.015f,
            tints = listOf(HazeTint(tint)),
            fallbackTint = HazeTint(background.copy(alpha = 0.24f)),
        )
        // 只在标题内合成，底缘透明，不再盖一层不透明背景或随滚动启停的遮罩。
        mask = Brush.verticalGradient(
            0f to Color.White.copy(alpha = 0.88f),
            0.65f to Color.White.copy(alpha = 0.72f),
            1f to Color.Transparent,
        )
    })
}
