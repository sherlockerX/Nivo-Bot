package io.github.nanomuse.focus.lock

/** 来自已完成、未删除且非休息专注的实际区间投影。 */
data class LockMeasuredSpan(val sessionId: String, val startedAt: Long, val durationMs: Long)

/** 强制统计不以计划时长或目标倒计时替代已经计量的专注。 */
object LockStatistics {
    /** 周期内的实际时长与紧急结束次数。 */
    data class Summary(val durationMs: Long, val emergencyCount: Int)

    /** 输入均须由宿主按账号读取，周期按开始包含、结束不包含计算。 */
    fun summarize(runs: List<LockRun>, visibleSessionIds: Set<String>, spans: List<LockMeasuredSpan>,
        start: Long, endExclusive: Long): Summary {
        require(endExclusive >= start)
        val finished = runs.filter { it.status != LockRunStatus.ACTIVE && it.sessionId in visibleSessionIds }.distinctBy { it.id }
        val forcedIds = finished.map { it.sessionId }.toSet()
        val duration = spans.filter { it.sessionId in forcedIds }.sumOf {
            (minOf(Math.addExact(it.startedAt, it.durationMs), endExclusive) - maxOf(it.startedAt, start)).coerceAtLeast(0)
        }
        val emergencyCount = finished.count { it.status == LockRunStatus.EMERGENCY &&
            it.endedAt?.let { time -> time >= start && time < endExclusive } == true }
        return Summary(duration, emergencyCount)
    }
}
