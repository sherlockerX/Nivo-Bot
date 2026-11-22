package io.github.nanomuse.ui.chat

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.Remove
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openminis.app.BuildConfig
import com.openminis.app.R
import com.openminis.app.ui.chat.AssistantBlock
import com.openminis.app.ui.chat.FlatChatItem
import com.openminis.app.ui.chat.ToolBlockStatus
import com.openminis.app.ui.chat.ToolCallPill
import com.openminis.app.ui.chat.ToolCancelColor
import com.openminis.app.ui.chat.ToolCheckColor
import com.openminis.app.ui.chat.ToolErrorColor

/**
 * 回答上方的过程摘要：与回答气泡同一左边线、按内容宽度显示的描边小卡片。
 * 收起时只有图标、标题、工具数和箭头；执行中第二行显示当前步骤。点按在独立面板里查看全部步骤。
 */
@Composable
internal fun AgentStepsFold(
    row: FlatChatItem.AssistantSteps, isExpanded: Boolean, isVisible: Boolean, onToggle: () -> Unit,
) {
    val current = if (row.isStreaming) currentStep(row) else null
    val colors = nivoProcessColors()
    val tools = row.blocks.count { it.kind == "tool_use" }
    val toolRunning = row.isStreaming && row.blocks.any { it.kind == "tool_use" && it.isRunningTool() }
    // 聊天列表已有16dp左右边距，这里不再另加，摘要与回答气泡同一左边线。
    Box(Modifier.fillMaxWidth().padding(vertical = 4.dp), contentAlignment = Alignment.TopStart) {
        Column(
            modifier = Modifier.widthIn(max = 340.dp)
                .then(foldTraceModifier(row.key))
                .nivoProcessSurface(colors)
                .clickable(role = Role.Button, onClickLabel = stringResource(R.string.nm_steps_open)) {
                    io.github.nanomuse.chat.DebugFoldTrace.toggled(row.key)
                    onToggle()
                }
                .heightIn(min = 44.dp)
                .padding(start = 12.dp, end = 8.dp, top = 10.dp, bottom = 10.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                when {
                    row.isThinking -> NivoThinkingStars(colors.accent, isVisible, Modifier.size(16.dp))
                    toolRunning -> CircularProgressIndicator(Modifier.size(14.dp), color = colors.accent, strokeWidth = 1.5.dp)
                    else -> Icon(if (tools > 0) Icons.Outlined.Checklist else Icons.Outlined.Lightbulb, contentDescription = null,
                        tint = colors.foreground, modifier = Modifier.size(16.dp))
                }
                Spacer(Modifier.width(8.dp))
                // 标题和工具数是同一段文字：大字号时一起换行，不把标题截断。
                val title = stepsTitle(row)
                val count = if (tools > 0) pluralStringResource(R.plurals.nm_steps_tool_count, tools, tools) else null
                val onSurface = MaterialTheme.colorScheme.onSurface
                Text(
                    text = buildAnnotatedString {
                        withStyle(SpanStyle(color = onSurface, fontWeight = FontWeight.Medium)) { append(title) }
                        if (count != null) withStyle(SpanStyle(color = colors.foreground)) { append(" ·\u00A0$count") }
                    },
                    style = MaterialTheme.typography.labelLarge,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                Icon(Icons.AutoMirrored.Outlined.KeyboardArrowRight, contentDescription = null,
                    tint = colors.foreground, modifier = Modifier.padding(start = 2.dp).size(18.dp))
            }
            if (current != null) {
                Text(
                    text = current,
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.foreground,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(start = 24.dp, end = 4.dp),
                )
            }
        }
    }
}

private fun AssistantBlock.isRunningTool(): Boolean = toolStatus == ToolBlockStatus.RUNNING ||
    toolStatus == ToolBlockStatus.STREAMING || toolStatus == ToolBlockStatus.PENDING

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

/**
 * 时间线上的一个过程片段：左侧是节点和连线，右侧是内容。
 * 节点只画在每一步的第一个片段上，同一步后续片段只延续连线；工具保留原有的详情、停止和长按菜单。
 */
@Composable
internal fun AgentStepPart(
    part: FlatChatItem.AssistantStepPart, onDetail: (String) -> Unit, onStop: () -> Unit,
    isFirst: Boolean = false, isLast: Boolean = false,
    fold: io.github.nanomuse.chat.StepFold? = null, onToggleFold: () -> Unit = {},
) {
    val colors = nivoProcessColors()
    val isTool = part.block.kind == "tool_use"
    val hasNode = part.partIndex == 0
    val railColor = colors.border
    // 轨道在布局完成后绘制：节点上方一段、节点下方一段；第一步不画上段，最后一步不画下段。
    // 左右边距由所在列表提供：聊天列表和步骤面板各自留白。
    Row(Modifier.fillMaxWidth().drawBehind {
        val x = 12.dp.toPx()
        val stroke = 1.5.dp.toPx()
        val nodeTop = 6.dp.toPx()
        val nodeBottom = 26.dp.toPx()
        if (hasNode) {
            if (!isFirst) drawLine(railColor, Offset(x, 0f), Offset(x, nodeTop), stroke)
            if (!isLast) drawLine(railColor, Offset(x, nodeBottom), Offset(x, size.height), stroke)
        } else if (!isLast) {
            drawLine(railColor, Offset(x, 0f), Offset(x, size.height), stroke)
        }
    }) {
        Box(Modifier.width(24.dp).padding(top = 6.dp), contentAlignment = Alignment.TopCenter) {
            if (hasNode) StepNode(part.block, part.isStreaming, colors)
        }
        Box(Modifier.weight(1f).padding(start = 8.dp, top = if (hasNode) 6.dp else 0.dp, bottom = 10.dp)) {
            if (isTool) ToolCallPill(
                block = part.block, allToolBlocks = part.tools,
                onStop = if (part.isStreaming) onStop else null, onOpenDetail = onDetail,
            ) else StepText(part, fold, onToggleFold, colors)
        }
    }
}

/**
 * 过程文字。思考收起时最多显示三行，下面是"展开全部"；展开后在这段思考的最后一个片段下显示"收起"。
 * 文字本身也可以点按切换，短思考没有折叠入口。
 */
@Composable
private fun StepText(
    part: FlatChatItem.AssistantStepPart, fold: io.github.nanomuse.chat.StepFold?, onToggleFold: () -> Unit,
    colors: NivoProcessColors,
) {
    val isCollapsed = fold?.isCollapsed == true
    var overflows by remember(part.key) { mutableStateOf(false) }
    val canToggle = fold != null && ((isCollapsed && (overflows || fold.hasMore)) || fold.showCollapse)
    val toggleLabel = stringResource(if (isCollapsed) R.string.nm_steps_show_more else R.string.nm_steps_show_less)
    Column {
        Text(
            text = part.text,
            style = MaterialTheme.typography.bodySmall,
            color = if (part.block.kind == "thinking") colors.foreground else MaterialTheme.colorScheme.onSurface,
            maxLines = if (isCollapsed) COLLAPSED_THINKING_LINES else Int.MAX_VALUE,
            overflow = TextOverflow.Ellipsis,
            onTextLayout = { if (isCollapsed) overflows = it.hasVisualOverflow },
            modifier = if (canToggle) Modifier.clickable(role = Role.Button, onClickLabel = toggleLabel, onClick = onToggleFold)
                else Modifier,
        )
        if (canToggle) {
            Text(
                text = toggleLabel,
                style = MaterialTheme.typography.labelMedium,
                color = colors.accent,
                modifier = Modifier.clickable(role = Role.Button, onClick = onToggleFold)
                    .heightIn(min = 32.dp).padding(top = 6.dp, end = 12.dp),
            )
        }
    }
}

/** 收起的思考在面板里保留的行数。 */
private const val COLLAPSED_THINKING_LINES = 3

/** 节点：思考是灯泡，说明文字是小圆点，工具按状态显示进行中、完成、失败或取消。 */
@Composable
private fun StepNode(block: AssistantBlock, isStreaming: Boolean, colors: NivoProcessColors) {
    Box(Modifier.size(20.dp), contentAlignment = Alignment.Center) {
        when {
            block.kind == "thinking" -> Icon(Icons.Outlined.Lightbulb, contentDescription = null,
                tint = colors.foreground, modifier = Modifier.size(16.dp))
            block.kind != "tool_use" -> Box(Modifier.size(7.dp).background(colors.foreground, CircleShape))
            block.isRunningTool() && isStreaming -> CircularProgressIndicator(Modifier.size(14.dp),
                color = colors.accent, strokeWidth = 1.5.dp)
            block.toolStatus == ToolBlockStatus.SUCCESS -> Icon(Icons.Outlined.Check,
                contentDescription = stringResource(R.string.nm_steps_status_done), tint = ToolCheckColor, modifier = Modifier.size(16.dp))
            block.toolStatus == ToolBlockStatus.FAILED || block.toolStatus == ToolBlockStatus.TIMEOUT -> Icon(Icons.Outlined.Close,
                contentDescription = stringResource(R.string.nm_steps_status_failed), tint = ToolErrorColor, modifier = Modifier.size(16.dp))
            block.toolStatus == ToolBlockStatus.CANCELLED -> Icon(Icons.Outlined.Remove,
                contentDescription = stringResource(R.string.nm_steps_status_cancelled), tint = ToolCancelColor, modifier = Modifier.size(16.dp))
            else -> Box(Modifier.size(7.dp).background(colors.foreground, CircleShape))
        }
    }
}
