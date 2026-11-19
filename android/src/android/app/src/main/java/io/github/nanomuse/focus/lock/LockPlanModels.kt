package io.github.nanomuse.focus.lock

private const val MINUTES_PER_DAY = 1440

/** 一天的本地分钟区间；相同起止分钟表示完整一天。 */
data class TimeRange(val startMinute: Int, val endMinute: Int) {
    init {
        require(startMinute in 0 until MINUTES_PER_DAY) { "开始分钟必须位于一天之内" }
        require(endMinute in 0 until MINUTES_PER_DAY) { "结束分钟必须位于一天之内" }
    }

    /** 按日历分钟计算的区间长度，不代表夏令时切换日的实际毫秒数。 */
    val durationMinutes: Int
        get() = if (isCrossingMidnight) MINUTES_PER_DAY - startMinute + endMinute
        else endMinute - startMinute

    /** 结束位于次日，包括起止分钟相同的全天区间。 */
    val isCrossingMidnight: Boolean get() = endMinute <= startMinute

    /** 起止分钟相同的全天区间。 */
    val isWholeDay: Boolean get() = startMinute == endMinute
}

/** 当前账户的一条计划；星期使用周一为1、周日为7的日历值。 */
data class LockPlan(
    val id: String,
    val name: String,
    val days: Set<Int> = setOf(1, 2, 3, 4, 5),
    val ranges: List<TimeRange> = emptyList(),
    val isEnabled: Boolean = true,
    val usesWhitelist: Boolean = true,
    val title: String? = null,
    val taskId: String? = null,
    val ownerKey: String = "",
    val revision: Long = 1L
) {
    init {
        require(id.isNotBlank()) { "计划身份不能为空" }
        require(days.all { it in 1..7 }) { "星期必须位于周一至周日之间" }
        require(revision > 0L) { "计划修订号必须大于零" }
    }

    /** 每周各配置区间的分钟合计，重叠区间仍分别计数。 */
    val weeklyMinutes: Int
        get() = Math.toIntExact(days.size.toLong() * ranges.sumOf { it.durationMinutes.toLong() })
}

/** 同一账户此刻活动的合并窗口，保留全部计划及具体时段身份。 */
data class LockWindow(
    val planIds: Set<String>,
    val planNames: Set<String>,
    val startAt: Long,
    val endAt: Long,
    val usesWhitelist: Boolean,
    val occurrenceIds: Set<String>,
    val ownerKey: String = ""
)

/** 锁定会话的生命周期，结束状态不能再次计时。 */
enum class LockRunStatus { ACTIVE, COMPLETED, EMERGENCY }

/** 剩余时间和是否需要把当前时钟建立为新检查点。 */
data class LockRemaining(val milliseconds: Long, val requiresRebaseline: Boolean)

/** 固定截止的锁定记录，单调检查点只在同一次启动中有效。 */
data class LockRun(
    val ownerKey: String,
    val id: String,
    val sessionId: String,
    val planIds: Set<String>,
    val occurrenceIds: Set<String>,
    val startedAt: Long,
    val deadlineAt: Long,
    val durationMs: Long,
    val usesWhitelist: Boolean,
    val checkpointRemainingMs: Long,
    val checkpointElapsed: Long,
    val bootCount: Int,
    val status: LockRunStatus = LockRunStatus.ACTIVE,
    val endedAt: Long? = null
) {
    init {
        require(durationMs in 1L..MAX_DURATION_MS) { "单次强制时长必须大于零且不超过24小时" }
        require(deadlineAt > startedAt && deadlineAt - startedAt == durationMs) {
            "固定截止与开始时刻、原始时长必须一致且不能溢出"
        }
        require(checkpointRemainingMs in 0L..durationMs) { "检查点剩余量必须在会话时长内" }
    }

    /** 计算下一次决策的剩余时长，不修改原始截止时刻。 */
    fun remaining(nowWall: Long, nowElapsed: Long, currentBootCount: Int): LockRemaining {
        if (status != LockRunStatus.ACTIVE) return LockRemaining(0L, false)
        val hasKnownBoot = currentBootCount >= 0 || currentBootCount == PROCESS_BOOT_COUNT
        val isSameBoot = hasKnownBoot && currentBootCount == bootCount
        val isClockContinuous = checkpointElapsed >= 0L && nowElapsed >= checkpointElapsed
        if (isSameBoot && isClockContinuous) {
            val elapsedMs = nowElapsed - checkpointElapsed
            return LockRemaining((checkpointRemainingMs - elapsedMs).coerceAtLeast(0L), false)
        }
        return LockRemaining(recoverRemaining(nowWall), true)
    }

    private fun recoverRemaining(nowWall: Long): Long {
        if (nowWall >= deadlineAt) return 0L
        // 正差值超过Long上限时保留检查点上限，不能因溢出误判到期。
        val wallRemaining = try {
            Math.subtractExact(deadlineAt, nowWall)
        } catch (_: ArithmeticException) {
            Long.MAX_VALUE
        }
        return minOf(wallRemaining, checkpointRemainingMs)
    }

    companion object {
        const val MAX_DURATION_MS = 86_400_000L

        /** 仅当前进程内有效；持久化后必须按未知启动恢复。 */
        const val PROCESS_BOOT_COUNT = -2
    }
}
