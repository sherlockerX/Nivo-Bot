package io.github.nanomuse.focus.lock

import java.time.ZoneId

/** 空闲计划检查的纯决策，不创建系统闹钟或启动锁机会话。 */
object LockStartPolicy {
    private const val MAX_RECHECK_INTERVAL_MS = 60_000L
    private const val ACTIVE_RETRY_INTERVAL_MS = 30_000L

    /** 下一次检查的墙钟时刻，以及是否需要立即评估。 */
    data class Check(val nextCheckAt: Long?, val shouldEvaluate: Boolean)

    /** 活动窗口的重试不得越过结束点，未来窗口最多一分钟重查。 */
    fun nextCheck(
        plans: List<LockPlan>,
        isMasterEnabled: Boolean,
        isLocked: Boolean,
        now: Long,
        completedOccurrenceIds: Set<String> = emptySet(),
        zone: ZoneId = ZoneId.systemDefault()
    ): Check {
        LockPlanEvaluator.requireSingleOwner(plans)
        if (!isMasterEnabled || isLocked) return Check(null, false)
        val active = LockPlanEvaluator.activeWindow(plans, now, completedOccurrenceIds, zone)
        if (active != null) {
            return Check(minOf(nextAfter(now, ACTIVE_RETRY_INTERVAL_MS), active.endAt), true)
        }
        val next = LockPlanEvaluator.nextWindow(plans, now, zone, completedOccurrenceIds)
            ?: return recheckBeyondProjection(plans, now)
        return Check(minOf(next.start, nextAfter(now, MAX_RECHECK_INTERVAL_MS)), false)
    }

    private fun recheckBeyondProjection(plans: List<LockPlan>, now: Long): Check {
        val hasEnabledPlan = plans.any {
            it.isEnabled && it.days.isNotEmpty() && it.ranges.isNotEmpty()
        }
        // 已完成身份可能遮住整个有限搜索范围，不能因此取消更远的重复计划。
        val nextCheckAt = if (hasEnabledPlan) nextAfter(now, MAX_RECHECK_INTERVAL_MS) else null
        return Check(nextCheckAt, false)
    }

    private fun nextAfter(now: Long, delayMs: Long): Long =
        if (now > Long.MAX_VALUE - delayMs) Long.MAX_VALUE else now + delayMs
}
