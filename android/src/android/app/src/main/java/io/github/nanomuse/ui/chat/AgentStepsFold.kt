package io.github.nanomuse.ui.chat

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.unit.dp
import com.openminis.app.BuildConfig
import com.openminis.app.ui.chat.FlatChatItem
import com.openminis.app.ui.chat.ToolCallPill

/** 默认收起思考和执行；点按在独立面板里查看全部步骤，执行中在同一行显示当前步骤，标题高度不变。 */
@Composable
internal fun AgentStepsFold(
    row: FlatChatItem.AssistantSteps, isExpanded: Boolean, onToggle: () -> Unit,
) {
    val current = if (row.isStreaming) currentStep(row) else null
    Text(
        text = "${if (isExpanded) "▾" else "▸"} " + stepsLabel(row) + (current?.let { " · $it" } ?: ""),
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 1,
        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)
            .then(foldTraceModifier(row.key)).clickable {
                io.github.nanomuse.chat.DebugFoldTrace.toggled(row.key)
                onToggle()
            }.padding(vertical = 10.dp),
    )
}

@Composable
private fun foldTraceModifier(key: String): Modifier {
    if (!BuildConfig.DEBUG || !BuildConfig.APPLICATION_ID.endsWith(".uitest")) return Modifier
    val owner = remember { Any() }
    DisposableEffect(key) {
        onDispose { io.github.nanomuse.chat.DebugFoldTrace.removed(key, owner) }
    }
    return Modifier.onGloballyPositioned {
        io.github.nanomuse.chat.DebugFoldTrace.placed(key, it.positionInWindow().y, owner)
    }
}

/** 仅隔离验收包在列表完成绘制后采样，正式包不安装绘制探针。 */
internal fun Modifier.traceStepDrawing(): Modifier {
    if (!BuildConfig.DEBUG || !BuildConfig.APPLICATION_ID.endsWith(".uitest")) return this
    return drawWithContent {
        drawContent()
        io.github.nanomuse.chat.DebugFoldTrace.drawnFrame()
    }
}

/** 仅构建当前可见的过程片段，仍保留工具详情和停止入口。 */
@Composable
internal fun AgentStepPart(
    part: FlatChatItem.AssistantStepPart, onDetail: (String) -> Unit, onStop: () -> Unit,
) {
    Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp)) {
        if (part.block.kind == "tool_use") ToolCallPill(
            block = part.block, allToolBlocks = part.tools,
            onStop = if (part.isStreaming) onStop else null, onOpenDetail = onDetail,
        ) else Text(text = part.text, style = MaterialTheme.typography.bodySmall)
    }
}
