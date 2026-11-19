package io.github.nanomuse.focus.lock

/** 强制期间AI的屏幕操作一律停用；Nivo自身也只开放锁页，不再有聊天豁免。 */
object LockScreenPolicy {
    /** 活动锁定一律拒绝屏幕自动化。 */
    fun requireAutomationAllowed(remainingMs:Long?) {
        if(remainingMs!=null && remainingMs>0) throw FocusLockedException()
    }
}
