package io.github.nanomuse.ui.chat

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.ui.chat.FlatChatItem
import io.github.nanomuse.chat.AgentStepRowsCache
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch

/**
 * Mosaic: the thinking and tool steps of one reply in their own sheet, so a long process never
 * pushes the answer down the chat. It has its own list and its own scroll: it follows the newest
 * step while the reply is being written, until the person scrolls up, and two buttons jump to
 * the first step and the newest one.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun AgentStepsSheet(
    row: FlatChatItem.AssistantSteps,
    onDetail: (String) -> Unit,
    onStop: () -> Unit,
    onDismiss: () -> Unit,
) {
    val cache = remember { AgentStepRowsCache() }
    val parts = remember(row) { cache.partsFor(row) }
    // 每段思考的折叠状态由用户点按决定；没点过时，正在输出的那段展开，其余收起。
    val toggles = remember(row.messageId) { mutableStateMapOf<String, Boolean>() }
    val liveKeyPrefix = if (row.isStreaming) row.blocks.lastOrNull()?.id?.let { "$it:" } else null
    val visible = io.github.nanomuse.chat.visibleStepParts(parts) { key ->
        toggles[key] ?: (liveKeyPrefix != null && key.startsWith(liveKeyPrefix))
    }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    // Follows the newest step while streaming; scrolling away from the end stops following.
    var follow by remember { mutableStateOf(row.isStreaming) }
    LaunchedEffect(listState) {
        // Only a finished scroll decides; a new step arriving at the end does not stop following.
        snapshotFlow { listState.isScrollInProgress }.drop(1)
            .collect { scrolling -> if (!scrolling) follow = !listState.canScrollForward }
    }
    LaunchedEffect(visible.size, row.isStreaming) {
        if (follow && visible.isNotEmpty()) listState.scrollToItem(visible.lastIndex)
    }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        // Fully open at once: half open, the list's lower part (the newest steps) sat below the screen,
        // and back only halved the sheet instead of closing it.
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            // 标题概括整个过程，下面一行写工具数和步数，展开的列表按时间线逐步排列。
            androidx.compose.foundation.layout.Column(Modifier.weight(1f)) {
                Text(stepsTitle(row), style = MaterialTheme.typography.titleMedium)
                Text(stepsSummary(row), style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = { scope.launch { follow = false; listState.scrollToItem(0) } }, enabled = parts.isNotEmpty()) {
                Icon(Icons.Filled.KeyboardArrowUp, contentDescription = stringResource(R.string.nm_steps_jump_first))
            }
            IconButton(onClick = { scope.launch { follow = row.isStreaming; if (visible.isNotEmpty()) listState.scrollToItem(visible.lastIndex) } },
                enabled = visible.isNotEmpty()) {
                Icon(Icons.Filled.KeyboardArrowDown, contentDescription = stringResource(R.string.nm_steps_jump_latest))
            }
        }
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxWidth().fillMaxHeight(0.85f).padding(top = 8.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp),
        ) {
            itemsIndexed(visible, key = { _, item -> item.first.key }, contentType = { _, item -> item.first.contentType }) { index, item ->
                val (part, fold) = item
                AgentStepPart(part = part, onDetail = onDetail, onStop = onStop,
                    isFirst = index == 0, isLast = index == visible.lastIndex, fold = fold,
                    onToggleFold = {
                        val key = io.github.nanomuse.chat.stepFoldKey(part)
                        toggles[key] = fold?.isCollapsed == true
                    })
            }
        }
    }
}

/** 过程标题：只有思考时写"正在思考 / 思考过程"，用过工具时写"思考与执行中 / 思考与执行过程"。 */
@Composable
internal fun stepsTitle(row: FlatChatItem.AssistantSteps): String {
    val hasTools = row.blocks.any { it.kind == "tool_use" }
    return stringResource(when {
        hasTools && row.isStreaming -> R.string.nm_steps_title_running
        hasTools -> R.string.nm_steps_title_done
        row.isStreaming -> R.string.nm_steps_title_thinking
        else -> R.string.nm_steps_title_thought
    })
}

/** 面板副标题：工具数和总步数。 */
@Composable
internal fun stepsSummary(row: FlatChatItem.AssistantSteps): String {
    val tools = row.blocks.count { it.kind == "tool_use" }
    val steps = pluralStringResource(R.plurals.nm_steps_step_count, row.blocks.size, row.blocks.size)
    return if (tools == 0) steps else pluralStringResource(R.plurals.nm_steps_tool_count, tools, tools) + " · " + steps
}

/** One line on what the process is doing now: the latest tool, or the last line of its thinking. */
internal fun currentStep(row: FlatChatItem.AssistantSteps): String? {
    val last = row.blocks.lastOrNull() ?: return null
    val line = if (last.kind == "tool_use") last.toolTitle.ifBlank { last.toolName }
    else last.content.lineSequence().map { it.trim() }.lastOrNull { it.isNotEmpty() }
    return line?.take(120)?.takeIf { it.isNotBlank() }
}
