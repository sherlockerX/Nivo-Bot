package io.github.nanomuse.focus.lock

/** 亮屏只恢复受限前台，电话与白名单的正常使用优先。 */
object LockWakePolicy {
    /** 缺少前台证据时可恢复锁页，已知获准的应用保持原状。 */
    fun shouldRestore(isEnabled: Boolean, access: LockAccessPolicy.Context,
        foreground: LockAccessPolicy.Foreground?, remainingMs: Long): Boolean {
        if (!isEnabled || remainingMs <= 0) return false
        return foreground == null ||
            LockAccessPolicy.decide(access, foreground, true, remainingMs) == LockAccessPolicy.Decision.BLOCK
    }
}
