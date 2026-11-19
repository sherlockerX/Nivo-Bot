package io.github.nanomuse.focus.lock

import java.time.ZoneId

/** 自动开始与活动白名单收紧的纯决策，系统权限交给宿主检查。 */
object LockScheduleDecision {
    /** 固定开始时长只在空闲时给出，活动会话只接收更严格的策略。 */
    data class Result(val window: LockWindow?, val startDurationMs: Long?, val nextStartAt: Long?,
        val retryAt: Long?, val usesWhitelist: Boolean, val activePlanIds: Set<String>)

    /** 已完成身份始终排除；正在计时的固定截止不受日历重新展开影响。 */
    fun evaluate(plans: List<LockPlan>, history: List<LockRun>, active: LockRun?, now: Long,
        zone: ZoneId = ZoneId.systemDefault()): Result {
        val completed = history.filter { it.status != LockRunStatus.ACTIVE }.flatMap { it.occurrenceIds }.toSet()
        val window = LockPlanEvaluator.activeWindow(plans, now, completed, zone)
        val next = LockPlanEvaluator.nextWindow(plans, now, zone, completed)?.start
        if (active != null) return Result(window, null, next, null,
            active.usesWhitelist && window?.usesWhitelist != false,
            active.planIds + window?.planIds.orEmpty())
        val duration = window?.let { (it.endAt - now).coerceAtMost(LockRun.MAX_DURATION_MS) }
        return Result(window, duration, next, window?.let { minOf(now + 30_000, it.endAt) },
            window?.usesWhitelist ?: true, window?.planIds.orEmpty())
    }

    /** 紧急退出同时消费此刻的重叠时段，避免确认后立即被同一组计划重新锁住。 */
    fun emergencyOccurrences(plans: List<LockPlan>, history: List<LockRun>, active: LockRun,
        now: Long, zone: ZoneId = ZoneId.systemDefault()): Set<String> {
        val completed = history.filter { it.status != LockRunStatus.ACTIVE }.flatMap { it.occurrenceIds }.toSet()
        return active.occurrenceIds + LockPlanEvaluator.activeWindow(plans, now, completed, zone)?.occurrenceIds.orEmpty()
    }
}
