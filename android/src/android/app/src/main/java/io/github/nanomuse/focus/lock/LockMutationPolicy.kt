package io.github.nanomuse.focus.lock

/** 所有计时写入入口共用的锁定拒绝，调用方必须先结算到期会话。 */
class FocusLockedException : IllegalStateException(CODE) {
    companion object { const val CODE = "focus_locked" }
}

/** 存储层的纯决策，不依赖页面、通知或模型是否隐藏按钮。 */
object LockMutationPolicy {
    /** 判断当前命令是否会绕过尚未到期的强制会话。 */
    fun requireCommandAllowed(action: String, remainingMs: Long?) {
        if (remainingMs != null && remainingMs > 0 &&
            action in setOf("start", "pause", "resume", "finish", "delete")) throw FocusLockedException()
    }

    /** 活动计划不能被编辑，白名单只能删减。 */
    fun requirePlanEditable(planId: String, activePlanIds: Set<String>) {
        if (planId in activePlanIds) throw FocusLockedException()
    }

    /** 新集合必须是原集合的子集，防止锁定期间扩大访问范围。 */
    fun requireWhitelistChange(old: Set<String>, next: Set<String>, isLocked: Boolean) {
        if (isLocked && !old.containsAll(next)) throw FocusLockedException()
    }
}
