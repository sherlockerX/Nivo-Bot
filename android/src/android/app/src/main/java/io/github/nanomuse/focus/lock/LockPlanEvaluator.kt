package io.github.nanomuse.focus.lock

import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/** 一条计划在某个原定本地日期展开的具体区间。 */
data class LockPlanInterval(
    val start: Long,
    val end: Long,
    val plan: LockPlan,
    val occurrenceId: String
)

/** 账户计划的纯日历计算，不访问Android状态或保存完成记录。 */
object LockPlanEvaluator {
    private const val PROJECTION_DAYS = 14L
    private const val MAX_PROJECTION_SPAN_DAYS = 366L
    private val MIN_EPOCH_INSTANT = Instant.ofEpochMilli(Long.MIN_VALUE)
    private val MAX_EPOCH_INSTANT = Instant.ofEpochMilli(Long.MAX_VALUE)

    /** 展开指定日期附近的区间；总跨度最多366天，包含中心日后最多367个日期。 */
    fun intervals(
        plans: List<LockPlan>,
        around: Long,
        backDays: Long = 2L,
        forwardDays: Long = 9L,
        zone: ZoneId = ZoneId.systemDefault()
    ): List<LockPlanInterval> {
        requireSingleOwner(plans)
        requireProjectionSpan(backDays, forwardDays)
        if (plans.isEmpty()) return emptyList()
        val today = Instant.ofEpochMilli(around).atZone(zone).toLocalDate()
        return plans.flatMap { plan ->
            expandPlan(plan, today, backDays, forwardDays, zone)
        }.sortedWith(compareBy<LockPlanInterval> { it.start }.thenBy { it.end }
            .thenBy { it.occurrenceId })
    }

    /** 按左闭右开边界合并此刻活动段，排除已经完成的稳定身份。 */
    fun activeWindow(
        plans: List<LockPlan>,
        now: Long,
        excludeOccurrenceIds: Set<String> = emptySet(),
        zone: ZoneId = ZoneId.systemDefault()
    ): LockWindow? {
        val active = intervals(plans, now, zone = zone).filter { interval ->
            now >= interval.start && now < interval.end &&
                interval.occurrenceId !in excludeOccurrenceIds
        }
        if (active.isEmpty()) return null
        return LockWindow(
            planIds = active.map { it.plan.id }.toSet(),
            planNames = active.map { it.plan.name }.toSet(),
            startAt = active.minOf { it.start },
            endAt = active.maxOf { it.end },
            usesWhitelist = active.all { it.plan.usesWhitelist },
            occurrenceIds = active.map { it.occurrenceId }.toSet(),
            ownerKey = active.first().plan.ownerKey
        )
    }

    /** 返回严格晚于当前时刻且未完成的最近开始段。 */
    fun nextWindow(
        plans: List<LockPlan>,
        now: Long,
        zone: ZoneId = ZoneId.systemDefault(),
        excludeOccurrenceIds: Set<String> = emptySet()
    ): LockPlanInterval? = intervals(plans, now, zone = zone).firstOrNull {
        it.start > now && it.occurrenceId !in excludeOccurrenceIds
    }

    /** 仅投影展示截止；空值表示有限投影范围没有空档，不修改当前会话。 */
    fun nextContinuousEnd(
        plans: List<LockPlan>,
        now: Long,
        currentEnd: Long,
        completedOccurrenceIds: Set<String> = emptySet(),
        currentOccurrenceIds: Set<String> = emptySet(),
        zone: ZoneId = ZoneId.systemDefault()
    ): Long? {
        requireSingleOwner(plans)
        if (currentEnd <= now) return currentEnd
        // 排除当前原日历段，墙钟回拨时它不能把自己的展示截止再次延长。
        val excluded = completedOccurrenceIds + currentOccurrenceIds
        val candidates = intervals(plans, currentEnd, forwardDays = PROJECTION_DAYS, zone = zone)
            .filterNot { it.occurrenceId in excluded }
        var projectedEnd = currentEnd
        for (interval in candidates) {
            if (interval.end <= projectedEnd) continue
            if (interval.start > projectedEnd) return projectedEnd
            projectedEnd = interval.end
        }
        val horizon = Instant.ofEpochMilli(currentEnd).atZone(zone).toLocalDate()
            .plusDays(PROJECTION_DAYS + 1L).atStartOfDay(zone).toInstant()
        // 展示查询边界可以超出Long毫秒范围，保留Instant比较即可，无需截断或抛错。
        return projectedEnd.takeIf { Instant.ofEpochMilli(it) < horizon }
    }

    /** 返回与指定本地日相交的区间，包括前一天开始的跨午夜段。 */
    fun todayIntervals(
        plans: List<LockPlan>,
        now: Long,
        zone: ZoneId = ZoneId.systemDefault()
    ): List<LockPlanInterval> {
        val expanded = intervals(plans, now, zone = zone)
        val day = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        val dayStart = day.atStartOfDay(zone).toInstant()
        val dayEnd = day.plusDays(1L).atStartOfDay(zone).toInstant()
        return expanded.filter {
            Instant.ofEpochMilli(it.end) > dayStart && Instant.ofEpochMilli(it.start) < dayEnd
        }
    }

    /** 所有入口先验证完整输入，停用或空时段计划也不能绕过账号隔离。 */
    internal fun requireSingleOwner(plans: List<LockPlan>) {
        val ownerKey = plans.firstOrNull()?.ownerKey ?: return
        require(plans.all { it.ownerKey == ownerKey }) { "一次只能评估同一账户的计划" }
    }

    private fun requireProjectionSpan(backDays: Long, forwardDays: Long) {
        require(backDays in 0L..MAX_PROJECTION_SPAN_DAYS) { "向前回溯天数必须位于0至366之间" }
        require(forwardDays in 0L..MAX_PROJECTION_SPAN_DAYS) { "向后投影天数必须位于0至366之间" }
        // 两侧先分别验证，再用减法检查总量，极大调用参数不能通过加法溢出绕过上限。
        require(backDays <= MAX_PROJECTION_SPAN_DAYS - forwardDays) { "总投影跨度不能超过366天" }
    }

    private fun expandPlan(
        plan: LockPlan,
        today: LocalDate,
        backDays: Long,
        forwardDays: Long,
        zone: ZoneId
    ): List<LockPlanInterval> {
        if (!plan.isEnabled || plan.days.isEmpty() || plan.ranges.isEmpty()) return emptyList()
        val expanded = mutableListOf<LockPlanInterval>()
        for (offset in -backDays..forwardDays) {
            val date = today.plusDays(offset)
            if (date.dayOfWeek.value !in plan.days) continue
            // 整日不存在时不能补到次日；正常DST缺失小时仍在原日期内顺延。
            if (date.atStartOfDay(zone).toLocalDate() != date) continue
            expanded += plan.ranges.mapNotNull { intervalAt(plan, date, it, zone) }
        }
        return expanded
    }

    private fun intervalAt(
        plan: LockPlan, date: LocalDate, range: TimeRange, zone: ZoneId
    ): LockPlanInterval? {
        val start = localMinuteAt(date, range.startMinute, zone) ?: return null
        val endDate = if (range.isCrossingMidnight) date.plusDays(1L) else date
        val end = localMinuteAt(endDate, range.endMinute, zone) ?: return null
        // 春季缺失时刻顺延后可能与结束重合或越过结束，此时不能补锁。
        if (end <= start) return null
        val identity = "occ:v1:${plan.id.length}:${plan.id}:$date:${range.startMinute}:${range.endMinute}"
        return LockPlanInterval(start, end, plan, identity)
    }

    private fun localMinuteAt(date: LocalDate, minute: Int, zone: ZoneId): Long? {
        val localTime = LocalTime.of(minute / 60, minute % 60)
        // 使用日历解析：缺失时刻顺延，重复时刻取较早偏移，不能用午夜加固定毫秒。
        return epochMillisOrNull(date.atTime(localTime).atZone(zone).toInstant())
    }

    private fun epochMillisOrNull(instant: Instant): Long? {
        // 仅丢弃无法完整表示的端点，不能把越界区间截断成一个新锁定时段。
        if (instant < MIN_EPOCH_INSTANT || instant > MAX_EPOCH_INSTANT) return null
        return instant.toEpochMilli()
    }
}
