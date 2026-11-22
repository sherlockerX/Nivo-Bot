package com.openminis.app.ui.chat

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.foundation.clickable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openminis.app.R
import com.openminis.app.ui.theme.ChatColors
import io.github.nanomuse.ui.chat.nivoProcessSurface // nanoMuse: 等待状态共用浅蓝色胶囊背景。

// [T-android-split-chat] Self-contained "thinking / streaming" dot indicators
// extracted verbatim from ChatScreen.kt. `internal` so the chat package can
// still reference them. No logic change — code moved as-is.

@Composable
internal fun BouncingDots(color: Color) {
    val infiniteTransition = rememberInfiniteTransition(label = "bounce")
    Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        repeat(3) { i ->
            val offset by infiniteTransition.animateFloat(
                initialValue = 0f,
                targetValue = -2f,
                animationSpec = infiniteRepeatable(
                    animation = tween(350, delayMillis = i * 120),
                    repeatMode = RepeatMode.Reverse,
                ),
                label = "dot_$i",
            )
            Box(
                modifier = Modifier
                    .size(4.dp)
                    .padding(top = (-offset).dp.coerceAtLeast(0.dp))
                    .background(color, CircleShape),
            )
        }
    }
}

// iOS-style streaming "..." after tool title — 3 dots bouncing inline with text
@Composable
internal fun StreamingDotsText() {
    val infiniteTransition = rememberInfiniteTransition(label = "streamDots")
    Row {
        repeat(3) { i ->
            val offset by infiniteTransition.animateFloat(
                initialValue = 0f,
                targetValue = -3f,
                animationSpec = infiniteRepeatable(
                    animation = tween(350, delayMillis = i * 120, easing = FastOutSlowInEasing),
                    repeatMode = RepeatMode.Reverse,
                ),
                label = "sdot_$i",
            )
            Text(
                text = ".",
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier.offset(y = offset.dp),
            )
        }
    }
}

// ─── Compaction progress ──────────────────────────────────────────────────────

/**
 * [T-android-compact-progress] Live status while a compaction runs, with a
 * Cancel affordance.
 *
 * Compaction used to present as a single unchanging flag for however long it
 * took — which on a slow or rate-limited model could be many minutes, and is
 * indistinguishable from a hang. This ticks once a second so the elapsed count
 * visibly moves, and names the split segment when the run had to fall back to
 * summarising halves, so "still working" is legible rather than inferred.
 */
@Composable
internal fun CompactProgressIndicator(
    progress: ChatViewModel.CompactProgress,
    onCancel: () -> Unit,
) {
    // Re-reads the clock every second; the changing value is what makes the
    // row demonstrably alive.
    var elapsedSec by remember(progress.startedAtMs) { mutableStateOf(0) }
    LaunchedEffect(progress.startedAtMs) {
        while (true) {
            elapsedSec = ((System.currentTimeMillis() - progress.startedAtMs) / 1000L).toInt()
            kotlinx.coroutines.delay(1000)
        }
    }

    Row(
        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = if (progress.depth > 0) {
                // Only surfaced once a split actually happened — saying
                // "segment 1" on the common single-call path would imply a
                // complexity that isn't there.
                stringResource(
                    R.string.compact_progress_split,
                    elapsedSec,
                    progress.callsIssued,
                    progress.callBudget,
                )
            } else {
                stringResource(R.string.compact_progress, elapsedSec)
            },
            fontSize = 14.sp,
            color = ChatColors.tertiaryText,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = stringResource(R.string.cancel),
            fontSize = 14.sp,
            fontWeight = FontWeight.Medium,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier
                .clickable(onClick = onCancel)
                .padding(horizontal = 8.dp, vertical = 4.dp),
        )
    }
}

// nanoMuse: 等待模型时显示三颗星，朗读仍使用包含助手昵称的本地化状态。

@Composable
internal fun TypingIndicator(isVisible: Boolean = true) {
    // Live Soul name → "<custom name> is thinking…" when the user renamed
    // the assistant in Soul settings. SoulStore.cachedMetadata is a StateFlow
    // that's updated on save (SoulSettingsScreen) and at app start
    // (MinisApp.onCreate via refreshCache); collectAsState makes Compose
    // recompose the indicator immediately when it changes.
    val soulMeta by com.openminis.app.agent.SoulStore.cachedMetadata.collectAsState()
    // nanoMuse: 默认助手名称本地化，保留用户自定义昵称。
    val soulName = io.github.nanomuse.identity.AssistantIdentity.displayName(soulMeta.name, stringResource(R.string.nm_pet_dragon))
    val processColors = io.github.nanomuse.ui.chat.nivoProcessColors() // nanoMuse: 跟随应用明暗主题。

    Row(
        // nanoMuse: 等待状态不再套胶囊底色，星形和文字与过程标题同一左边线。
        modifier = Modifier.padding(top = 2.dp, bottom = 8.dp).padding(horizontal = 4.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        io.github.nanomuse.ui.chat.NivoThinkingStars(processColors.accent, isVisible, Modifier.size(18.dp)) // nanoMuse: 进行中的图标用强调色。
        Text(
            text = stringResource(R.string.chat_typing_indicator, soulName),
            fontSize = 15.sp,
            color = processColors.foreground, // nanoMuse: 弱化的主题文字色。
            maxLines = 1, // nanoMuse: 长昵称保持单行，避免胶囊圆角裁切多行文字。
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
        )
    }
}
