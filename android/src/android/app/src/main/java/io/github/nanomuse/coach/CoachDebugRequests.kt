package io.github.nanomuse.coach

import android.content.Context
import com.openminis.app.BuildConfig
import com.openminis.app.MinisApp
import com.openminis.app.ui.chat.ChatViewModel
import com.openminis.app.ui.chat.ChatViewModelStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** 隔离验收包复用真实页面请求入口，只读请求状态，不直接创建训练或证据。 */
object CoachDebugRequests {
    /** 仅调试隔离包可发送或停止真实模型请求；正式安装不可调用。 */
    suspend fun execute(context: Context, params: JSONObject): JSONObject {
        check(BuildConfig.DEBUG && BuildConfig.APPLICATION_ID.endsWith(".uitest")) {
            "Coach request inspection is only available in the isolated test build"
        }
        val app = context.applicationContext as MinisApp
        val requestedChat = params.getString("chatSessionId")
        val service = CoachRuntime.service(context)
        require(io.github.nanomuse.home.MainChat.isMain(context, requestedChat) ||
            service.topicForConversation(requestedChat)?.status == "active") { "Select the isolated main or bound topic conversation" }
        val action = params.optString("action", "status")
        val chatId = if (action == "open") CoachConversationCoordinator.open(
            context, app.chatRepository, app.providerRepository, params.getString("courseId")) else requestedChat
        return withContext(Dispatchers.Main) {
            val vm = androidx.lifecycle.ViewModelProvider(ChatViewModelStore.ownerFor(chatId),
                ChatViewModel.factory(chatId, app.chatRepository, app.providerRepository, app.applicationContext,
                    app.memoryRepository, app.skillRepository, app.mcpRepository))[ChatViewModel::class.java]
            vm.nmAwaitSessionReady()
            when (action) {
                "send" -> vm.nmSendCoachRequest(params.getString("prompt"), params.optString("sessionId").ifBlank { null })
                "chat" -> vm.sendMessage(params.getString("prompt"))
                "end" -> vm.nmEndCoachLesson(params.getString("sessionId"))
                "retry_archive" -> vm.nmRetryCoachArchive()
                "open" -> io.github.nanomuse.ui.home.HomeBus.showSession(chatId)
                "cancel" -> vm.nmCancelCoachRequest()
                "status" -> Unit
                else -> error("Unknown test request action")
            }
            val request = vm.nmCoachRequest.value
            val topic = service.topicForConversation(chatId)
            JSONObject().put("chatSessionId", chatId).put("topicId", topic?.id ?: JSONObject.NULL)
                .put("lessonId", topic?.activeSessionId ?: JSONObject.NULL)
                .put("archiveError", vm.nmCoachArchiveError.value ?: JSONObject.NULL)
                .put("modelBusy", vm.isStreaming.value).put("request", request?.let {
                JSONObject().put("sessionId", it.sessionId ?: JSONObject.NULL)
                    .put("requestId", it.requestId).put("isRunning", it.isRunning)
                    .put("error", it.error ?: JSONObject.NULL).put("reason", it.reason ?: JSONObject.NULL)
                    .put("canRetry", it.canRetry).put("isAwaitingConfirmation", it.isAwaitingConfirmation)
            } ?: JSONObject.NULL)
        }
    }
}
