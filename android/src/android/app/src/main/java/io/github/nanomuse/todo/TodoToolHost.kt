package io.github.nanomuse.todo

import com.openminis.app.tools.ToolExecutionResult
import io.github.nanomuse.coach.CoachTurnAuthorization
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.json.JSONObject

/** 宿主从当前循环与界面取得的快照，任何字段都不能由模型参数覆盖。 */
data class TodoToolAccess(
    val isAccountCurrent: Boolean,
    val isMain: Boolean,
    val isScheduled: Boolean,
    val isTaskDispatch: Boolean,
    val sessionId: String,
    val loopUserId: String?,
    val authorization: CoachTurnAuthorization?,
    val currentAuthorization: CoachTurnAuthorization?,
    val user: TodoToolUser?,
) {
    /** 只复用精确的前台用户授权，不继承教练专题或新回合的权限。 */
    fun denialReason(): String? = when {
        !isAccountCurrent -> "account_changed"
        !isMain -> "main_required"
        isScheduled -> "scheduled_forbidden"
        isTaskDispatch -> "dispatch_forbidden"
        else -> userDenial()
    }

    private fun userDenial(): String? = when {
        user == null || user.messageId.isBlank() || user.text.isBlank() ||
            user.messageId.startsWith("queued_msg_") -> "saved_user_required"
        loopUserId != user.messageId || user.chatSessionId != sessionId -> "current_user_required"
        else -> authorizationDenial()
    }

    private fun authorizationDenial(): String? = when {
        authorization == null || authorization.messageId != user?.messageId ||
            authorization.chatSessionId != sessionId -> "foreground_authorization_required"
        authorization != currentAuthorization -> "authorization_changed"
        else -> null
    }
}

/** 将当前用户、统一审批与持久化端口串在一起，每次等待后重新核对同一授权。 */
class TodoToolHost(
    private val access: suspend () -> TodoToolAccess,
    private val guard: suspend (String, String) -> String?,
    private val storageFactory: suspend () -> TodoToolStorage,
    private val focusFactory: (suspend () -> io.github.nanomuse.focus.FocusStore)? = null,
) {
    /** 等待审批和真实写入结束后才返回成功，取消直接传给模型循环。 */
    suspend fun execute(name: String, arguments: String): ToolExecutionResult { return try {
        currentCoroutineContext().ensureActive()
        require(name in setOf(TodoAgentBridge.QUERY, TodoAgentBridge.COMMAND, io.github.nanomuse.focus.FocusAgentBridge.QUERY, io.github.nanomuse.focus.FocusAgentBridge.COMMAND)) { "Unknown Todo tool" }
        val initial = access()
        requireAccess(initial)
        guard(name, arguments)?.let { return failure(it) }
        requireSameAccess(initial)
        if (name == io.github.nanomuse.focus.FocusAgentBridge.QUERY || name == io.github.nanomuse.focus.FocusAgentBridge.COMMAND) {
            val store = checkNotNull(focusFactory) { "Focus is unavailable" }.invoke()
            return io.github.nanomuse.focus.FocusAgentBridge(store) { requireSameAccess(initial) }.execute(name, arguments)
        }
        val storage = GuardedStorage(storageFactory()) { requireSameAccess(initial) }
        val bridge = TodoAgentBridge(storage)
        val result = if (name == TodoAgentBridge.QUERY) bridge.query(arguments)
            else bridge.command(arguments, initial.user)
        requireSameAccess(initial)
        result
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (failure: Exception) {
        failure(failure.message ?: "Todo request failed")
    }

    }

    private fun requireAccess(state: TodoToolAccess) {
        state.denialReason()?.let { error("Todo access denied: $it") }
    }

    private suspend fun requireSameAccess(initial: TodoToolAccess) {
        currentCoroutineContext().ensureActive()
        val current = access()
        requireAccess(current)
        check(current.authorization == initial.authorization && current.user == initial.user &&
            current.sessionId == initial.sessionId) { "Todo access denied: user_turn_changed" }
    }

    private fun failure(message: String): ToolExecutionResult = ToolExecutionResult(
        JSONObject().put("success", false).put("message", message).toString(), false,
    )

    /** 更新读取和写入之间仍要检查授权，防止等待数据库时旧回合继续修改。 */
    private class GuardedStorage(
        private val storage: TodoToolStorage,
        private val checkAccess: suspend () -> Unit,
    ) : TodoToolStorage {
        override val ownerKey: String get() = storage.ownerKey
        override suspend fun categories(): List<TodoCategory> = checked { storage.categories() }
        override suspend fun categoryCommand(action:String,kind:String,name:String,expectedCreatedAt:Long?,operationId:String):String =
            checked { storage.categoryCommand(action,kind,name,expectedCreatedAt,operationId) }
        override suspend fun tasks(): List<TodoTask> = checked { storage.tasks() }
        override suspend fun task(id: String): TodoTask? = checked { storage.task(id) }
        override suspend fun taskForUpdate(id: String, expectedRevision: Long, operationId: String): TodoTask? =
            checked { storage.taskForUpdate(id, expectedRevision, operationId) }
        override suspend fun saveTask(task: TodoTask, operationId: String): TodoTask =
            checked { storage.saveTask(task, operationId) }
        override suspend fun changeStatus(id: String, status: String, expectedRevision: Long,
            operationId: String, completedDay: Long?): TodoTask =
            checked { storage.changeStatus(id, status, expectedRevision, operationId, completedDay) }
        override suspend fun deleteTask(id: String, expectedRevision: Long, operationId: String) =
            checked { storage.deleteTask(id, expectedRevision, operationId) }
        private suspend fun <T> checked(block: suspend () -> T): T {
            checkAccess()
            return block().also { checkAccess() }
        }
    }
}

/** 恢复首次更新的完整输入；后续字段补丁仍由Store比较持久化签名。 */
internal object TodoToolReplay {
    /** 同一操作ID不能改为其他目标、修订或动作。 */
    fun updateInput(request: String, id: String, revision: Long): TodoTask {
        val json = JSONObject(request)
        require(json.getString("kind") == "save") { "Operation id was already used for another action" }
        return TodoJson.readTask(json.getJSONObject("task")).also {
            require(it.id == id && it.revision == revision) { "Operation id was already used for another task revision" }
        }
    }
}
