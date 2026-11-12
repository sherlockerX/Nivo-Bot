package io.github.nanomuse.ui.chat

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.platform.LocalContext
import android.widget.Toast
import com.openminis.app.R
import com.openminis.app.ui.chat.ChatViewModel
import io.github.nanomuse.coach.CoachRuntime
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.UUID

/** 一次入口只携带定位或开场意图，聊天内容和草稿仍由原聊天持有。 */
data class CoachConversationEntry(
    val chatSessionId: String,
    val messageId: String? = null,
    val shouldStartLesson: Boolean = false,
    val requestId: String = UUID.randomUUID().toString(),
)

/** 等待聊天恢复后消费本次入口，旋转、返回或重组不会重发开场。 */
@Composable
fun CoachConversationEntryEffect(
    entry: CoachConversationEntry?,
    viewModel: ChatViewModel,
    isVisible: Boolean,
    onConsumed: ((String) -> Unit)?,
    onRevealMessage: (String) -> Unit,
) {
    val context = LocalContext.current
    LaunchedEffect(entry?.requestId, viewModel, isVisible) {
        val current = entry ?: return@LaunchedEffect
        if (!isVisible || current.chatSessionId != viewModel.currentSessionId) return@LaunchedEffect
        viewModel.nmAwaitSessionReady()
        current.messageId?.let {
            onConsumed?.invoke(current.requestId)
            onRevealMessage(it)
            return@LaunchedEffect
        }
        if (!current.shouldStartLesson || viewModel.isStreaming.value || !viewModel.nmIsCoachPractice()) {
            onConsumed?.invoke(current.requestId)
            return@LaunchedEffect
        }
        val lesson = try {
            withContext(Dispatchers.IO) {
                val state = CoachRuntime.service(context).state.value
                val topic = state.topics.singleOrNull { it.chatSessionId == current.chatSessionId }
                state.sessions.firstOrNull { it.id == topic?.activeSessionId && it.topicId == topic?.id }
            }
        } catch (failure: Exception) {
            if (failure is CancellationException) throw failure
            onConsumed?.invoke(current.requestId)
            Toast.makeText(context, failure.message ?: context.getString(R.string.nm_coach_failed), Toast.LENGTH_LONG).show()
            return@LaunchedEffect
        }
        // 读取完成后再消费；消费会重组界面，后续发送之间不能再挂起。
        onConsumed?.invoke(current.requestId)
        if (lesson == null) return@LaunchedEffect
        // 已有教学或待处理回答只恢复原位置，失败重试沿用聊天本来的入口。
        if (lesson.turns.isNotEmpty() || lesson.pendingTurnId != null || lesson.status != "active") return@LaunchedEffect
        // 程序发送会共用聊天发送逻辑，存在草稿时不触发，防止文字或附件被消费。
        if (viewModel.inputText.value.isNotBlank() || viewModel.attachments.value.isNotEmpty() ||
            viewModel.pastedTexts.value.isNotEmpty()) return@LaunchedEffect
        viewModel.nmSendCoachRequest(context.getString(R.string.nm_coach_start), lesson.id)
    }
}
