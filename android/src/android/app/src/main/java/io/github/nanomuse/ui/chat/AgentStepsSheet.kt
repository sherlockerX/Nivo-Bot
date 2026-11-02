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
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    // Follows the newest step while streaming; scrolling away from the end stops following.
    var follow by remember { mutableStateOf(row.isStreaming) }
    LaunchedEffect(listState) {
        // Only a finished scroll decides; a new step arriving at the end does not stop following.
        snapshotFlow { listState.isScrollInProgress }.drop(1)
            .collect { scrolling -> if (!scrolling) follow = !listState.canScrollForward }
    }
    LaunchedEffect(parts.size, row.isStreaming) {
        if (follow && parts.isNotEmpty()) listState.scrollToItem(parts.lastIndex)
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
            Text(
                stepsLabel(row),
                style = MaterialTheme.typography.titleSmall,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = { scope.launch { follow = false; listState.scrollToItem(0) } }, enabled = parts.isNotEmpty()) {
                Icon(Icons.Filled.KeyboardArrowUp, contentDescription = stringResource(R.string.nm_steps_jump_first))
            }
            IconButton(onClick = { scope.launch { follow = row.isStreaming; if (parts.isNotEmpty()) listState.scrollToItem(parts.lastIndex) } },
                enabled = parts.isNotEmpty()) {
                Icon(Icons.Filled.KeyboardArrowDown, contentDescription = stringResource(R.string.nm_steps_jump_latest))
            }
        }
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxWidth().fillMaxHeight(0.85f),
        ) {
            itemsIndexed(parts, key = { _, part -> part.key }, contentType = { _, part -> part.contentType }) { _, part ->
                AgentStepPart(part = part, onDetail = onDetail, onStop = onStop)
            }
        }
    }
}

/** "Thinking and execution (N tools)", running or finished. */
@Composable
internal fun stepsLabel(row: FlatChatItem.AssistantSteps): String = stringResource(
    if (row.isStreaming) R.string.nm_steps_running else R.string.nm_steps_finished,
    row.blocks.count { it.kind == "tool_use" },
)

/** One line on what the process is doing now: the latest tool, or the last line of its thinking. */
internal fun currentStep(row: FlatChatItem.AssistantSteps): String? {
    val last = row.blocks.lastOrNull() ?: return null
    val line = if (last.kind == "tool_use") last.toolTitle.ifBlank { last.toolName }
    else last.content.lineSequence().map { it.trim() }.lastOrNull { it.isNotEmpty() }
    return line?.take(120)?.takeIf { it.isNotBlank() }
}
