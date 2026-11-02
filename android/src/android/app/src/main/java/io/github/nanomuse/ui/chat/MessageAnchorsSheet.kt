package io.github.nanomuse.ui.chat

import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Bookmark
import androidx.compose.material.icons.outlined.BookmarkBorder
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.ui.chat.ChatMessage
import com.openminis.app.ui.chat.ChatViewModel
import io.github.nanomuse.chat.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** 一个入口提供问题目录、书签和当前聊天搜索，索引筛选在后台进行。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MessageAnchorsSheet(viewModel: ChatViewModel, onDismiss: () -> Unit, onPick: (String, String) -> Unit) {
    val context = LocalContext.current
    val session = viewModel.currentSessionId
    val messages by viewModel.messages.collectAsState()
    val store = remember { MessageAnchorStore.get(context) }
    val savedBySession by store.state.collectAsState()
    val ready by store.ready.collectAsState()
    val saved = savedBySession[session].orEmpty()
    var query by rememberSaveable(session) { mutableStateOf("") }
    var debounced by remember(session) { mutableStateOf("") }
    var savedOnly by rememberSaveable(session) { mutableStateOf(false) }
    LaunchedEffect(query) { delay(150); debounced = query }
    val entries by produceState(emptyList<MessageAnchor>(), messages, saved, debounced, savedOnly) {
        value = withContext(Dispatchers.Default) { anchorEntries(messages, saved, debounced, savedOnly) }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().fillMaxHeight(.85f).imePadding().padding(horizontal = 16.dp)) {
            Text(stringResource(R.string.nm_anchors), style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(query, { query = it }, label = { Text(stringResource(R.string.nm_anchor_search)) },
                modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp), singleLine = true)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(!savedOnly, { savedOnly = false }, { Text(stringResource(R.string.nm_anchor_directory)) })
                FilterChip(savedOnly, { savedOnly = true }, { Text(stringResource(R.string.nm_anchor_saved)) })
            }
            if (!ready) Text(stringResource(R.string.nm_anchor_loading))
            else if (entries.isEmpty()) Text(stringResource(R.string.nm_anchor_empty), Modifier.padding(vertical = 16.dp))
            LazyColumn(Modifier.weight(1f)) {
                items(entries, key = { it.id }) { entry ->
                    Row(Modifier.fillMaxWidth().clickable { onPick(entry.id, query.trim()) }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(stringResource(if (entry.role == "user") R.string.nm_anchor_user else R.string.nm_anchor_assistant),
                                style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Text(entry.text.ifBlank { "…" }, maxLines = 2, overflow = TextOverflow.Ellipsis,
                                style = MaterialTheme.typography.bodyMedium)
                        }
                        AnchorToggle(viewModel.currentSessionId, messages.firstOrNull { anchorIdentity(it) == entry.id }, store, entry.saved, ready)
                    }
                    HorizontalDivider()
                }
            }
        }
    }
}

/** 回复操作栏和目录共用同一书签按钮，避免各入口状态不一致。 */
@Composable
fun MessageAnchorButton(sessionId: String, message: ChatMessage) {
    val context = LocalContext.current
    val store = remember { MessageAnchorStore.get(context) }
    val data by store.state.collectAsState()
    val ready by store.ready.collectAsState()
    val ids = data[sessionId].orEmpty()
    AnchorToggle(sessionId, message, store, message.id in ids || message.sourceDbIds.any { it in ids }, ready && !message.isStreaming)
}

@Composable
private fun AnchorToggle(sessionId: String, message: ChatMessage?, store: MessageAnchorStore, saved: Boolean, enabled: Boolean) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var saving by remember { mutableStateOf(false) }
    val stable = message != null && !message.isStreaming && (message.role == "user" || message.sourceDbIds.isNotEmpty())
    IconButton(enabled = enabled && !saving && stable, onClick = {
        val selected = message ?: return@IconButton
        saving = true
        scope.launch {
            try { store.toggle(sessionId, selected) }
            catch (error: Exception) {
                if (error is kotlinx.coroutines.CancellationException) throw error
                Toast.makeText(context, R.string.nm_anchor_save_failed, Toast.LENGTH_SHORT).show()
            } finally { saving = false }
        }
    }) {
        Icon(if (saved) Icons.Outlined.Bookmark else Icons.Outlined.BookmarkBorder,
            stringResource(if (saved) R.string.nm_anchor_remove else R.string.nm_anchor_add))
    }
}
