package io.github.nanomuse.focus.lock

/** 一次锁机结算的事实，调用方在同一数据库事务中保存会话和专注区间。 */
data class LockSettlement(val remainingMs: Long, val totalMs: Long, val deltaMs: Long,
    val shouldCheckpoint: Boolean, val isFinished: Boolean)

/** 固定时长计时与区间账本之间的纯计算边界。 */
object LockAccounting {
    /** 只增加真实推进量，重复心跳不重复记账。 */
    fun settle(run: LockRun, recordedMs: Long, wall: Long, elapsed: Long, boot: Int): LockSettlement {
        // 已记时长越界时按边界结算；这里抛异常会让每次结算失败，锁就过了截止也解不开。
        val recorded = recordedMs.coerceIn(0L, run.durationMs)
        val remaining = run.remaining(wall, elapsed, boot)
        val total = (run.durationMs - remaining.milliseconds).coerceAtLeast(recorded)
        val isFinished = remaining.milliseconds == 0L || total >= run.durationMs
        val shouldSave = isFinished || remaining.requiresRebaseline ||
            elapsed - run.checkpointElapsed >= CHECKPOINT_INTERVAL_MS
        return LockSettlement(run.durationMs - total, total, total - recorded, shouldSave, isFinished)
    }

    private const val CHECKPOINT_INTERVAL_MS = 15_000L
}
