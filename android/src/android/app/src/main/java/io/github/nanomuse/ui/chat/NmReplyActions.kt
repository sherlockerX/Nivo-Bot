package io.github.nanomuse.ui.chat

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.CallSplit
import androidx.compose.material.icons.automirrored.outlined.TextSnippet
import androidx.compose.material.icons.automirrored.outlined.VolumeUp
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.StopCircle
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.data.repository.ChatRepository
import com.openminis.app.ui.chat.ChatMessage
import com.openminis.app.ui.chat.ChatViewModel
import com.openminis.app.ui.theme.ChatColors
import io.github.nanomuse.chat.ChatBranch
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** What a reply says, as Markdown: its text blocks in order, or the whole content for older rows. */
internal fun replyMarkdown(reply: ChatMessage): String =
    reply.toolBlocks.filter { it.kind == "text" && it.content.isNotEmpty() }
        .joinToString("\n\n") { it.content }
        .ifEmpty { reply.content }

/**
 * Mosaic: the row under a finished reply. Copy (the Markdown), read aloud or stop, answer again
 * (the latest reply), carry on in a new chat from here, and share as a picture or as text.
 * While a turn runs the actions that would change the chat wait.
 */
@Composable
fun NmReplyActions(
    reply: ChatMessage,
    messages: List<ChatMessage>,
    viewModel: ChatViewModel,
    speech: NmReplySpeech,
    chatRepository: ChatRepository,
    busy: Boolean,
    /** ChatScreen's safeMutate: closes the selection toolbar before the list is cut. */
    onMutate: (() -> Unit) -> Unit,
    onOpenSession: (String) -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val markdown = remember(reply) { replyMarkdown(reply) }
    val speaking by speech.speaking.collectAsState()
    val reading = speech.readingId == reply.id && speaking
    val question = remember(reply.id, messages) {
        val at = messages.indexOfFirst { it.id == reply.id }
        if (at <= 0) null else messages.subList(0, at).lastOrNull { it.role == "user" }
    }
    val latest = messages.lastOrNull { it.role == "assistant" }?.id == reply.id
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1_500)
            copied = false
        }
    }
    var shareMenu by remember { mutableStateOf(false) }
    var sharingImage by remember { mutableStateOf(false) }
    var branching by remember { mutableStateOf(false) }
    val timingRevision by io.github.nanomuse.chat.TurnTimingStore.revision.collectAsState()
    val elapsed = remember(reply.id, reply.sourceDbIds, timingRevision) {
        io.github.nanomuse.chat.TurnTimingStore.elapsedForMessage(reply.sourceDbIds + reply.id.substringBefore('#'))
    }

    androidx.compose.foundation.layout.Column {
    elapsed?.let { Text(stringResource(R.string.nm_turn_elapsed, io.github.nanomuse.chat.ConversationRunLedger.elapsed(it)), style = androidx.compose.material3.MaterialTheme.typography.labelSmall, color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant) }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 2.dp, bottom = 4.dp)) {
        MessageAnchorButton(viewModel.currentSessionId, reply)
        ActionIcon(if (copied) Icons.Outlined.Check else Icons.Outlined.ContentCopy, stringResource(R.string.nm_reply_copy)) {
            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText("reply", markdown))
            copied = true
        }
        ActionIcon(
            if (reading) Icons.Outlined.StopCircle else Icons.AutoMirrored.Outlined.VolumeUp,
            stringResource(if (reading) R.string.nm_reply_stop_reading else R.string.nm_reply_read),
        ) {
            // the answer only, not the notes on the way (as when replies are read aloud)
            if (reading) speech.stop() else speech.read(reply.id, answerText(reply.toolBlocks, reply.content))
        }
        if (latest && question != null) {
            ActionIcon(Icons.Outlined.Refresh, stringResource(R.string.nm_reply_regenerate), enabled = !busy) {
                onMutate { viewModel.retryFromMessage(question.id) }
            }
        }
        ActionIcon(Icons.AutoMirrored.Outlined.CallSplit, stringResource(R.string.nm_reply_branch), enabled = !busy && !branching) {
            branching = true
            scope.launch {
                val made = runCatching { branch(context, viewModel, chatRepository, reply, question) }.getOrNull()
                branching = false
                if (made == null) {
                    Toast.makeText(context, R.string.nm_reply_branch_failed, Toast.LENGTH_SHORT).show()
                } else {
                    Toast.makeText(context, R.string.nm_reply_branch_done, Toast.LENGTH_SHORT).show()
                    onOpenSession(made)
                }
            }
        }
        Box {
            ActionIcon(Icons.Outlined.Share, stringResource(R.string.nm_reply_share)) { shareMenu = true }
            DropdownMenu(expanded = shareMenu, onDismissRequest = { shareMenu = false }) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.nm_reply_share_image)) },
                    leadingIcon = { Icon(Icons.Outlined.Image, contentDescription = null) },
                    onClick = {
                        shareMenu = false
                        sharingImage = true
                    },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.nm_reply_share_text)) },
                    leadingIcon = { Icon(Icons.AutoMirrored.Outlined.TextSnippet, contentDescription = null) },
                    onClick = {
                        shareMenu = false
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, markdown)
                        }
                        runCatching { context.startActivity(Intent.createChooser(send, context.getString(R.string.nm_reply_share_text))) }
                    },
                )
            }
        }
    }

    }
    if (sharingImage) {
        NmReplyShareDialog(question = question?.content, answer = markdown, onDismiss = { sharingImage = false })
    }
}

/** Makes the branch and returns its id; null when the chat has not been saved yet or there is nothing to copy. */
private suspend fun branch(
    context: Context,
    viewModel: ChatViewModel,
    chatRepository: ChatRepository,
    reply: ChatMessage,
    question: ChatMessage?,
): String? {
    val sessionId = viewModel.realSessionId.ifEmpty { return null }
    val history = viewModel.messages.value
    val at = history.indexOfFirst { it.id == reply.id }
    if (at < 0) return null
    val turns = history.subList(0, at + 1).count { it.role == "user" && !it.isQueued }
    // Named after the question that led here; the main chat's own title says little about one turn.
    val topic = question?.content?.trim()?.take(20).orEmpty()
        .ifEmpty { chatRepository.getSession(sessionId)?.title?.trim().orEmpty() }
    val title = if (topic.isEmpty()) {
        context.getString(R.string.nm_reply_branch_untitled)
    } else {
        context.getString(R.string.nm_reply_branch_title, topic)
    }
    return ChatBranch.create(chatRepository, sessionId, turns, title)
}

@Composable
private fun ActionIcon(icon: ImageVector, label: String, enabled: Boolean = true, onClick: () -> Unit) {
    IconButton(onClick = onClick, enabled = enabled, modifier = Modifier.size(34.dp)) {
        Icon(
            icon,
            contentDescription = label,
            tint = ChatColors.secondaryText.copy(alpha = if (enabled) 1f else 0.4f),
            modifier = Modifier.size(18.dp),
        )
    }
}
