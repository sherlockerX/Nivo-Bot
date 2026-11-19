package io.github.nanomuse.focus.lock

/** 开始入口共用的时长边界。 */
object LockSafetyRules {
    /** 在写入会话前验证正式上限和构建期上限。 */
    fun requireDuration(durationMs: Long, buildMaximumMs: Long) {
        require(durationMs in 1L..minOf(buildMaximumMs, LockRun.MAX_DURATION_MS)) { "invalid_lock_duration" }
    }
}
