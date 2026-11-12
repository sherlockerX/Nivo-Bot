package io.github.nanomuse.coach

import java.util.UUID

/** 每次授权都有自己的代次，相同用户消息重试时也不能复用旧授权。 */
data class CoachTurnAuthorization(val messageId: String, val chatSessionId: String, val token: String = UUID.randomUUID().toString())

/** 将教练入口和工具调用的语音策略绑定到具体用户、助手消息。 */
class CoachTurnRouting {
    private val coachUserIds = linkedSetOf<String>()
    private val coachAssistantIds = linkedSetOf<String>()
    private val authorizedUsers = linkedMapOf<String, CoachTurnAuthorization>()

    /** 只由前台宿主在真实用户回合开始时授权，模型不能提供此标记。 */
    @Synchronized fun authorize(messageId: String, chatSessionId: String): CoachTurnAuthorization? {
        if (messageId.isBlank() || chatSessionId.isBlank()) return null
        val authorization = CoachTurnAuthorization(messageId, chatSessionId)
        authorizedUsers[messageId] = authorization
        if (authorizedUsers.size > MAX_TRACKED_IDS) authorizedUsers.remove(authorizedUsers.keys.first())
        return authorization
    }

    /** 回合结束立即撤销，不允许后台重放旧聊天取得权限。 */
    @Synchronized fun revoke(authorization: CoachTurnAuthorization) {
        if (authorizedUsers[authorization.messageId] == authorization) authorizedUsers.remove(authorization.messageId)
    }

    /** 同步停止当前回合时取得精确授权，异步任务必须保存先前取得的授权。 */
    @Synchronized fun currentAuthorization(messageId: String): CoachTurnAuthorization? = authorizedUsers[messageId]

    /** 返回精确拒绝原因；宿主确认的专题聊天沿用同一用户回合授权。 */
    @Synchronized fun denialReason(messageId: String?, chatSessionId: String, isMain: Boolean,
        isScheduled: Boolean, isTaskDispatch: Boolean, isForeground: Boolean,
        isBoundPractice: Boolean = false): String? = when {
        !isMain && !isBoundPractice -> "main_required"
        isScheduled -> "scheduled_forbidden"
        isTaskDispatch -> "dispatch_forbidden"
        messageId.isNullOrBlank() -> "user_required"
        !isForeground && authorizedUsers[messageId]?.chatSessionId != chatSessionId -> "foreground_required"
        authorizedUsers[messageId]?.chatSessionId != chatSessionId -> "user_turn_required"
        else -> null
    }

    /** 保存教练入口发出的用户消息标识。 */
    @Synchronized fun markUser(messageId: String) = remember(coachUserIds, messageId)

    /** 队列合并成持久化消息时保留原用户回合的策略。 */
    @Synchronized fun isCoachUser(messageId: String): Boolean = messageId in coachUserIds

    /** 新助手回合继承对应用户消息的策略。 */
    @Synchronized fun beginAssistant(assistantId: String, userMessageId: String?) {
        if (userMessageId in coachUserIds) remember(coachAssistantIds, assistantId)
    }

    /** 成功的原生教练工具将本条助手正文标为系统朗读。 */
    @Synchronized fun markAssistant(assistantId: String) = remember(coachAssistantIds, assistantId)

    /** 返回该助手消息是否属于教练回合。 */
    @Synchronized fun isCoach(assistantId: String): Boolean = assistantId in coachAssistantIds

    /** 随聊天宿主销毁释放所有标识。 */
    @Synchronized fun clear() {
        coachUserIds.clear()
        coachAssistantIds.clear()
        authorizedUsers.clear()
    }

    private fun remember(ids: MutableSet<String>, messageId: String) {
        if (messageId.isBlank()) return
        ids += messageId
        if (ids.size > MAX_TRACKED_IDS) ids.remove(ids.first())
    }

    companion object {
        private const val MAX_TRACKED_IDS = 256
        /** 主聊天或可信绑定专题的用户回合可访问，任务派发不继承授权。 */
        fun canAccess(isMain: Boolean, isScheduled: Boolean, isTaskDispatch: Boolean,
            hasUserMessage: Boolean, isForeground: Boolean = true, isBoundPractice: Boolean = false): Boolean =
            (isMain || isBoundPractice) && !isScheduled && !isTaskDispatch && hasUserMessage && isForeground
    }
}
