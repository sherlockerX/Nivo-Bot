package io.github.nanomuse.coach

import java.util.UUID
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject

/** 只描述一个明确的教练请求，不继承普通主聊天的运行标记。 */
data class CoachRequestState(
    val sessionId: String?, val isRunning: Boolean, val error: String? = null,
    val requestId: String = UUID.randomUUID().toString(), val canRetry: Boolean = false,
    val reason: String? = null, val isAwaitingConfirmation: Boolean = false,
)

/** 请求开始时的领域位置，用于核对回复是否真正提交。 */
data class CoachRequestSnapshot(val sessionId: String, val stage: String, val pendingTurnId: String?, val revision: Long)

/** 收尾时同时核对请求代次和真实用户，避免同一消息重试被旧任务结束。 */
data class CoachRequestOwner(val requestId: String, val userId: String?)

/** 一个模型循环可被排队用户接管，每次替换和finally都结束当时的真实回合。 */
class CoachRequestLoop(
    initialUserId: String?, private val finish: (CoachRequestOwner) -> Unit,
    private val revoke: (CoachTurnAuthorization) -> Unit,
    initialOwner: CoachRequestOwner? = null, initialAuthorization: CoachTurnAuthorization? = null,
) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<CoachRequestLoop>

    var userId: String? = initialUserId
        private set
    var requestOwner: CoachRequestOwner? = initialOwner
        private set
    var authorization: CoachTurnAuthorization? = initialAuthorization
        private set

    /** 首次自然语言工具调用建立请求后，只接受本循环所属的同一请求代次。 */
    fun bindRequest(owner: CoachRequestOwner?) {
        if (owner?.userId != userId || owner == null) return
        if (requestOwner == null || requestOwner == owner) requestOwner = owner
    }

    /** 保存本循环取得的授权代次，退出时不能撤销后续重试的权限。 */
    fun bindAuthorization(value: CoachTurnAuthorization?) {
        if (value?.messageId == userId) authorization = value
    }

    /** 新用户接管之前立即结束旧用户，避免复用授权和等待状态。 */
    fun replaceUser(nextUserId: String, nextAuthorization: CoachTurnAuthorization? = null) {
        if (nextUserId == userId) return
        close()
        userId = nextUserId
        bindAuthorization(nextAuthorization)
    }

    /** 即使当前用户没有调用教练工具，循环退出时也要撤销授权。 */
    fun close() {
        if (userId == null) return
        val owner = requestOwner
        val lease = authorization
        userId = null
        requestOwner = null
        authorization = null
        try { owner?.let(finish) } finally { lease?.let(revoke) }
    }
}

/** 用户回合与教练回合一一绑定，失败保留原始答案以供重试。 */
class CoachRequestTracker {
    private val mutableState = MutableStateFlow<CoachRequestState?>(null)
    val state: StateFlow<CoachRequestState?> = mutableState
    private var userId: String? = null
    private var before: CoachRequestSnapshot? = null
    private var lastFailure: Pair<String, String>? = null
    private val failedMutations = linkedMapOf<String, Pair<String, String>>()

    /** 忙碌时拒绝本次请求，不修改或取消已经运行的请求。 */
    @Synchronized fun begin(sessionId: String?, snapshot: CoachRequestSnapshot?, busy: Boolean = false): Boolean {
        if (mutableState.value?.isRunning == true) return false
        before = snapshot; userId = null; lastFailure = null; failedMutations.clear()
        mutableState.value = if (busy) CoachRequestState(sessionId, false,
            "主聊天正在处理其它请求。回答仍已保留，请稍后重试。", canRetry = true, reason = "chat_busy")
        else CoachRequestState(sessionId, true)
        return !busy
    }

    /** 发送成功后绑定数据库中的真实用户消息，旧回合不能结束新请求。 */
    @Synchronized fun bindUser(id: String, expectedRequestId: String? = mutableState.value?.requestId): Boolean {
        val current = mutableState.value ?: return false
        if (!current.isRunning || current.requestId != expectedRequestId || (userId != null && userId != id)) return false
        userId = id
        mutableState.value = current.copy(isAwaitingConfirmation = false)
        return true
    }

    /** 自然语言主聊天第一次调用教练工具时建立相同的跟踪。 */
    @Synchronized fun observe(id: String, sessionId: String?, snapshot: CoachRequestSnapshot?) {
        if (mutableState.value?.isRunning != true) begin(sessionId, snapshot)
        bindUser(id)
        if (userId == id && mutableState.value?.sessionId == null && sessionId != null) {
            before = snapshot
            mutableState.value = mutableState.value?.copy(sessionId = sessionId)
        }
    }

    /** 仅当前用户回合的失败可影响当前请求。 */
    @Synchronized fun toolFailure(id: String, reason: String, message: String, mutationKey: String? = null) {
        if (userId != id) return
        // 领域错误仍保留机器原因，页面只展示协议提供的可读说明。
        val payload = runCatching { JSONObject(message) }.getOrNull()
        val failure = ((payload?.opt("reason") as? String)?.takeIf { it.isNotBlank() } ?: reason) to
            ((payload?.opt("message") as? String)?.takeIf { it.isNotBlank() } ?: message)
        if (mutationKey == null) lastFailure = failure
        else failedMutations[mutationKey] = failure
    }

    /** 同一回合后续成功可修正工具参数错误，但领域推进仍需在结束时核对。 */
    @Synchronized fun toolSuccess(id: String, mutationKey: String? = null) {
        if (userId != id) return
        if (mutationKey != null) failedMutations.remove(mutationKey)
        else lastFailure = null
    }

    /** 等待主聊天压缩确认时保留同一请求身份，禁止重复发送。 */
    @Synchronized fun awaitConfirmation() {
        if (mutableState.value?.isRunning == true) mutableState.value = mutableState.value!!.copy(isAwaitingConfirmation = true)
    }

    /** 用户取消压缩确认时结束请求，原文交还输入框。 */
    @Synchronized fun cancelAwaiting() {
        val current = mutableState.value ?: return
        if (current.isAwaitingConfirmation) mutableState.value = current.copy(
            isRunning = false, isAwaitingConfirmation = false, canRetry = true,
            reason = "cancelled", error = "已取消本次教练请求，原内容已保留。")
    }

    /** answer/start成功后绑定新产生的待回复位置，而非写入前的旧快照。 */
    @Synchronized fun expectReply(id: String, snapshot: CoachRequestSnapshot) {
        if (userId != id || mutableState.value?.isRunning != true) return
        before = snapshot
        mutableState.value = mutableState.value?.copy(sessionId = snapshot.sessionId)
    }

    /** 现实报告和模拟作答都必须等待对应领域教练回复，纯文字点评不能结束请求。 */
    @Synchronized fun expectMutationReply(id: String, action: String, snapshot: CoachRequestSnapshot) {
        if (action in setOf("start", "answer", "action_report")) expectReply(id, snapshot)
    }

    /** 记录发送前置失败，不需要伪造用户消息或领域记录。 */
    @Synchronized fun reject(reason: String, message: String) {
        mutableState.value = (mutableState.value ?: CoachRequestState(null, false)).copy(
            isRunning = false, error = message, canRetry = true, reason = reason, isAwaitingConfirmation = false)
    }

    /** 回合结束检查setup和待评估答案，普通最终文字不能冒充领域提交。 */
    @Synchronized fun finish(owner: CoachRequestOwner?, after: CoachRequestSnapshot?, error: String? = null, cancelled: Boolean = false) {
        val current = mutableState.value ?: return
        if (!current.isRunning || owner == null || current.requestId != owner.requestId || userId != owner.userId) return
        val unchanged = before?.let { start -> after == null ||
            (start.pendingTurnId != null && after.pendingTurnId == start.pendingTurnId) ||
            (start.stage == "setup" && after.stage == "setup") } == true
        val operationFailure = failedMutations.values.lastOrNull() ?: lastFailure
        val failure = when {
            cancelled -> "cancelled" to "本轮请求已停止。已保存的回答保留，可以重试教练回应。"
            error != null -> "request_failed" to error
            unchanged -> operationFailure ?: ("reply_not_saved" to "教练回应未保存，原回答仍已保留。请重试，继续评估同一条回答。")
            operationFailure != null -> operationFailure
            else -> null
        }
        mutableState.value = current.copy(isRunning = false, error = failure?.second, isAwaitingConfirmation = false,
            canRetry = failure != null, reason = failure?.first)
    }

    /** 当前受跟踪的用户回合，仅用于生命周期核对。 */
    @Synchronized fun currentUserId(): String? = userId

    /** 捕获当前请求身份，异步收尾必须持有自己的快照，不能读取最新请求代替。 */
    @Synchronized fun currentOwner(): CoachRequestOwner? =
        mutableState.value?.let { CoachRequestOwner(it.requestId, userId) }

    /** 仅为所属真实用户返回身份，自然语言工具不能接管另一用户的请求。 */
    @Synchronized fun ownerForUser(id: String?): CoachRequestOwner? =
        currentOwner()?.takeIf { mutableState.value?.isRunning == true && it.userId == id }

    /** 销毁聊天或切换账户时清除临时授权状态。 */
    @Synchronized fun clear() { userId = null; before = null; lastFailure = null; failedMutations.clear(); mutableState.value = null }
}
