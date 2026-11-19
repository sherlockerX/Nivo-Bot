package io.github.nanomuse.focus

import io.github.nanomuse.todo.TodoTask
import io.github.nanomuse.todo.parseTodoTags
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.roundToLong

/** 一个任务在所选时段内的实际专注时长，任务已删除时沿用开始专注时的标题。 */
data class FocusTaskShare(val taskId: String?, val title: String, val durationMs: Long, val sessionCount: Int)

/** 一个待办分组占所选时段总专注时长的比重；空分组名表示未分组或没有关联任务。 */
data class FocusGroupShare(
    val group: String,
    val durationMs: Long,
    val percentage: Double,
    val sessionCount: Int,
    val tasks: List<FocusTaskShare>,
)

/** 所选时段的专注汇总：总时长、次数、平均每次时长和按分组的占比。 */
data class FocusGroupSummary(
    val totalMs: Long,
    val sessionCount: Int,
    val groups: List<FocusGroupShare>,
) {
    val averageMs: Long get() = if (sessionCount == 0) 0 else totalMs / sessionCount
}

/** 专注时间按什么归类：待办分组，或待办标签。 */
enum class FocusShareBy { GROUP, TAG }

/**
 * 专注统计沿用待办的分组和标签：待办页看各分组、标签占任务的比重，这里看它们占专注时间的比重。
 *
 * 分组和标签以任务当前的设置为准，任务改了分组或标签，历史专注随之归类；任务已删除时退回开始专注时
 * 记下的快照。一次专注有多个标签时，时长平均分给这些标签，与待办统计的算法一致，各项占比合计为100%。
 * 时长按真实计时区间与时段的交集计算，跨午夜的专注分到两天，休息、未结束和已删除的记录不计入。
 */
object FocusGroupStatistics {
    fun calculate(
        sessions: List<FocusSession>,
        spans: List<FocusSpan>,
        tasks: List<TodoTask>,
        start: LocalDate,
        endExclusive: LocalDate,
        zone: ZoneId = ZoneId.systemDefault(),
        by: FocusShareBy = FocusShareBy.GROUP,
    ): FocusGroupSummary {
        val from = start.atStartOfDay(zone).toInstant().toEpochMilli()
        val until = endExclusive.atStartOfDay(zone).toInstant().toEpochMilli()
        val counted = sessions.filter { it.status == "finished" && it.mode != "break" && it.deletedAt == null }
            .associateBy { it.id }
        val liveTasks = tasks.filter { it.deletedAt == null }.associateBy { it.id }
        val bySession = mutableMapOf<String, Long>()
        for (span in spans) {
            if (span.sessionId !in counted) continue
            val overlap = minOf(span.startedAt + span.durationMs, until) - maxOf(span.startedAt, from)
            if (overlap > 0) bySession.merge(span.sessionId, overlap, Long::plus)
        }
        val total = bySession.values.sum()
        // 每次专注归入哪些类别、各占多少份；空字符串表示未分组或未标记。
        fun categories(session: FocusSession): List<String> {
            val task = session.taskId?.let(liveTasks::get)
            return when (by) {
                FocusShareBy.GROUP -> listOf((task?.groupName ?: session.groupName).trim())
                // 快照损坏时按未标记处理，统计不能因为一条旧数据失败。
                FocusShareBy.TAG -> runCatching { task?.tags() ?: parseTodoTags(session.tagsJson) }.getOrDefault(emptyList())
                    .ifEmpty { listOf("") }
            }
        }
        val parts = bySession.flatMap { (sessionId, duration) ->
            val session = counted.getValue(sessionId)
            val keys = categories(session)
            keys.map { key -> Triple(key, session, duration.toDouble() / keys.size) }
        }
        val groups = parts.groupBy { it.first }.map { (key, items) ->
            val duration = items.sumOf { it.third }
            val taskShares = items.groupBy { (_, session, _) ->
                session.taskId?.takeIf { it in liveTasks } ?: "title:${session.title}"
            }.map { (_, rows) ->
                val session = rows.first().second
                val task = session.taskId?.let(liveTasks::get)
                FocusTaskShare(task?.id, task?.title ?: session.title, rows.sumOf { it.third }.roundToLong(), rows.size)
            }.sortedWith(compareByDescending<FocusTaskShare> { it.durationMs }.thenBy { it.title })
            FocusGroupShare(key, duration.roundToLong(), if (total > 0) duration * 100.0 / total else 0.0, items.size, taskShares)
        }.sortedWith(compareByDescending<FocusGroupShare> { it.durationMs }.thenBy { it.group.isEmpty() }.thenBy { it.group })
        return FocusGroupSummary(total, bySession.size, groups)
    }
}
