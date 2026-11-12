package io.github.nanomuse.todo

/** 标签扇区同时保留权重和实际任务数，避免把均分权重解释成半个任务。 */
data class TodoTagSlice(val tag: String, val weight: Double, val taskCount: Int,
    val percentage: Double, val taskIds: List<String>)

/** 当前有效完成任务的标签分布。空标签由界面显示为本地化的未标记。 */
data class TodoStatisticsResult(val completedCount: Int, val slices: List<TodoTagSlice>)

/** 日周月年共用左闭右开日期范围，不按更新时间或碎片数量计数。 */
object TodoStatistics {
    /** 每项任务权重为1，多标签均分，完成时标签快照保持历史含义。 */
    fun calculate(tasks: List<TodoTask>, startDay: Long, endDayExclusive: Long): TodoStatisticsResult {
        require(endDayExclusive >= startDay)
        val completed = tasks.distinctBy { it.ownerKey to it.id }.filter {
            it.deletedAt == null && it.status == "done" &&
                it.completedDay?.let { day -> day >= startDay && day < endDayExclusive } == true
        }
        val weights = linkedMapOf<String, Double>()
        val ids = linkedMapOf<String, MutableList<String>>()
        completed.forEach { task ->
            val tags = parseTodoTags(task.completionTagsJson).ifEmpty { listOf("") }
            tags.forEach { tag ->
                weights[tag] = (weights[tag] ?: 0.0) + 1.0 / tags.size
                ids.getOrPut(tag) { mutableListOf() }.add(task.id)
            }
        }
        val slices = weights.map { (tag, weight) ->
            TodoTagSlice(tag, weight, ids.getValue(tag).size, weight / completed.size * 100, ids.getValue(tag))
        }.sortedWith(compareByDescending<TodoTagSlice> { it.weight }.thenBy { it.tag })
        return TodoStatisticsResult(completed.size, slices)
    }
}
