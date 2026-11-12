package io.github.nanomuse.ui.coach

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import io.github.nanomuse.coach.CoachRequestState

/** 上下文由当前聊天的权威专题绑定确定，普通聊天不继承全局课程选择。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun CoachChatContext(
    onOpen: (() -> Unit)?,
    request: CoachRequestState? = null,
    chatSessionId: String = "",
    isMainChat: Boolean = false,
    onEndLesson: ((String) -> Unit)? = null,
    onStartLesson: (() -> Unit)? = null,
    isStreaming: Boolean = false,
) {
    val state by rememberCoachConversationState()
    val topic = state.topics.singleOrNull { chatSessionId.isNotBlank() && it.chatSessionId == chatSessionId }
    val session = topic?.let { bound ->
        state.sessions.firstOrNull { it.id == bound.activeSessionId && it.topicId == bound.id }
            ?: state.sessions.lastOrNull { it.topicId == bound.id }
    }
    val draft = if (isMainChat && topic == null) state.drafts.lastOrNull { it.status != "activated" } else null
    val relatedRequest = request?.takeIf { current ->
        if (topic != null) state.sessions.any { it.id == current.sessionId && it.topicId == topic.id }
        else isMainChat && current.sessionId == null
    }
    val hasArchives = isMainChat && state.sessions.isNotEmpty()
    if (topic == null && draft == null && !hasArchives && relatedRequest?.error == null) return
    var isExpanded by rememberSaveable(chatSessionId, topic?.id) { mutableStateOf(false) }
    val unit = session?.course?.units?.firstOrNull { it.id == session.unitId }
    Surface(color = MaterialTheme.colorScheme.secondaryContainer, shape = MaterialTheme.shapes.medium,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 6.dp)) {
        Column(Modifier.padding(horizontal = 6.dp, vertical = 2.dp)) {
            relatedRequest?.error?.let {
                Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                val titleWidth = maxWidth * 0.38f
                FlowRow(horizontalArrangement = Arrangement.spacedBy(0.dp)) {
                    if (topic != null || draft != null) TextButton(
                        onClick = { isExpanded = !isExpanded },
                        contentPadding = PaddingValues(horizontal = 6.dp),
                        modifier = Modifier.heightIn(min = 48.dp).widthIn(max = titleWidth),
                    ) {
                        Text(topic?.title ?: draft?.course?.title ?: stringResource(R.string.nm_coach_explore),
                            maxLines = 1, overflow = TextOverflow.Ellipsis,
                            style = MaterialTheme.typography.labelLarge)
                    }
                    if (onOpen != null) TextButton(onClick = {
                        topic?.let { CoachUi.selectedCourseId.value = it.courseId }
                        CoachUi.open(if (topic != null || draft == null) "results" else "courses")
                        onOpen()
                    }, contentPadding = PaddingValues(horizontal = 6.dp), modifier = Modifier.heightIn(min = 48.dp)) {
                        Text(stringResource(R.string.nm_coach_chat_archive))
                    }
                    if (topic?.status == "active" && session?.status == "complete" && onStartLesson != null) {
                        TextButton(enabled = !isStreaming && relatedRequest?.isRunning != true,
                            onClick = onStartLesson, contentPadding = PaddingValues(horizontal = 6.dp),
                            modifier = Modifier.heightIn(min = 48.dp)) {
                            Text(stringResource(R.string.nm_coach_chat_next_lesson))
                        }
                    }
                    if (topic?.status == "active" && session != null && session.status in setOf("active", "waiting_real") && onEndLesson != null) {
                        TextButton(enabled = !isStreaming && relatedRequest?.isRunning != true,
                            onClick = { onEndLesson(session.id) }, contentPadding = PaddingValues(horizontal = 6.dp),
                            modifier = Modifier.heightIn(min = 48.dp)) {
                            Text(stringResource(R.string.nm_coach_chat_end_today))
                        }
                    }
                }
            }
            if (isExpanded) {
                topic?.let { Text(it.title, style = MaterialTheme.typography.labelLarge) }
                session?.let {
                    Text(it.course.title + "·" + (unit?.title ?: it.unitId),
                        style = MaterialTheme.typography.bodySmall)
                }
                Text(unit?.focus ?: draft?.text.orEmpty(), style = MaterialTheme.typography.bodySmall)
            }
            if (session?.assessment != null) {
                Text(stringResource(R.string.nm_coach_chat_independent_check),
                    style = MaterialTheme.typography.labelMedium)
            }
        }
    }
}
