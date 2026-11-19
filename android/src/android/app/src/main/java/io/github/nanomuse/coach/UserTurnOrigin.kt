package io.github.nanomuse.coach

/** 用户点击时固定的宿主、会话和重试消息，等待期间不重新借用前台状态。 */
data class UserTurnOrigin(
    val hostId: String,
    val sessionId: String,
    val retryMessageId: String? = null,
) {
    /** 只允许同一宿主的草稿首次落盘，不能跨已有会话或换到另一条重试消息。 */
    fun canBind(currentHostId: String, currentSessionId: String, messageId: String,
        isAccountCurrent: Boolean, isSessionVisible: Boolean, isTaskDispatch: Boolean): Boolean {
        if (!isAccountCurrent || !isSessionVisible || isTaskDispatch || currentHostId != hostId) return false
        if (messageId.isBlank() || messageId.startsWith("queued_msg_")) return false
        if (retryMessageId != null && retryMessageId != messageId) return false
        return sessionId == currentSessionId ||
            (sessionId == hostId && sessionId.startsWith("__new__") && currentSessionId.isNotBlank())
    }

    companion object {
        /** 只有真实前台用户入口可产生来源，后台派发不因应用恰在前台而获得权限。 */
        fun capture(hostId: String, sessionId: String, retryMessageId: String? = null,
            isForeground: Boolean, isAccountCurrent: Boolean, isSessionVisible: Boolean,
            isTaskDispatch: Boolean): UserTurnOrigin? =
            if (isForeground && isAccountCurrent && isSessionVisible && !isTaskDispatch)
                UserTurnOrigin(hostId, sessionId, retryMessageId) else null

        /** 合并队列只有全部来自同一宿主和会话时才能继承读取权限。 */
        fun merged(origins: List<UserTurnOrigin?>): UserTurnOrigin? {
            val first = origins.firstOrNull() ?: return null
            return first.takeIf { origins.all { it == first } }
        }
    }
}
