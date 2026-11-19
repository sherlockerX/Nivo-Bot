package io.github.nanomuse.focus.lock

/** 合并同一前台周期内的拉回请求，使用宿主提供的单调时钟。 */
class LockLaunchGate(private val retryAfterMs: Long = 1500L) {
    private var observedGeneration: Long? = null
    private var isLockUiFocused = false
    private var lastAttemptAt: Long? = null

    init {
        require(retryAfterMs > 0L) { "拉回重试间隔必须大于零" }
    }

    /** 接收前台身份代数与锁页焦点，旧代数不能覆盖新证据。 */
    @Synchronized
    fun observeForeground(evidenceGeneration: Long, isLockUiFocused: Boolean) {
        val previousGeneration = observedGeneration
        if (previousGeneration != null && evidenceGeneration < previousGeneration) return
        // 只有真实前台身份更新才开启新周期，普通窗口事件不能重置在途尝试。
        if (previousGeneration == null || evidenceGeneration > previousGeneration) {
            lastAttemptAt = null
        }
        observedGeneration = evidenceGeneration
        this.isLockUiFocused = isLockUiFocused
    }

    /** 申请一次拉回；点亮屏幕只越过焦点限制，仍需遵守去重窗口。 */
    @Synchronized
    fun claim(nowElapsedMs: Long, turnOnScreen: Boolean = false): Boolean {
        require(nowElapsedMs >= 0L) { "单调时刻不能为负数" }
        if (isLockUiFocused && !turnOnScreen) return false
        val previousAttemptAt = lastAttemptAt
        // 较早采样可能后进入同步区，不能当作重启放开去重；真实基线变化由宿主reset。
        if (previousAttemptAt != null) {
            if (nowElapsedMs < previousAttemptAt) return false
            if (nowElapsedMs - previousAttemptAt < retryAfterMs) return false
        }
        lastAttemptAt = nowElapsedMs
        return true
    }

    /** 会话切换时清除全部前台证据和在途请求。 */
    @Synchronized
    fun reset() {
        observedGeneration = null
        isLockUiFocused = false
        lastAttemptAt = null
    }
}
