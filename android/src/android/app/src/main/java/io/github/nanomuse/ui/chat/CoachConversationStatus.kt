package io.github.nanomuse.ui.chat

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.ui.chat.ChatViewModel
import io.github.nanomuse.ui.coach.CoachChatContext

/** 顶部展示当前课和档案错误，重试只整理档案，不重新请求模型。 */
@Composable
fun CoachConversationStatus(viewModel: ChatViewModel, chrome: NmHomeChrome, isStreaming: Boolean,
    isPractice: Boolean, archiveError: String?) {
    // nanoMuse: 主要聊天保持纯对话，不显示教练档案入口；专题练习聊天保留课次操作。
    if (chrome.isMainChat || !isPractice) return
    val request by viewModel.nmCoachRequest.collectAsState()
    CoachChatContext(
        onOpen = chrome.onOpenCoach,
        request = request,
        chatSessionId = viewModel.currentSessionId,
        isMainChat = false,
        onEndLesson = { viewModel.nmEndCoachLesson(it) },
        onStartLesson = { viewModel.nmStartCoachLesson() },
        isStreaming = isStreaming,
    )
    if (archiveError != null) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
            Text(stringResource(R.string.nm_coach_chat_archive_failed),
                style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.error)
            Text(archiveError, style = MaterialTheme.typography.bodySmall)
            TextButton(onClick = { viewModel.nmRetryCoachArchive() }, modifier = Modifier.heightIn(min = 48.dp)) {
                Text(stringResource(R.string.nm_coach_chat_retry_archive))
            }
        }
    }
}
