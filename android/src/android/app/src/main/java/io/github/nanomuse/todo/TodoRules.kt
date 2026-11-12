package io.github.nanomuse.todo

import java.time.LocalDate

/** 任务编辑的纯业务规则，所有写入路径共用。 */
object TodoRules {
    val STATUSES = setOf("todo", "in_progress", "done")

    /** 校验归属与日期，保存完成时快照，重开时清除有效完成。 */
    fun update(input: TodoTask, old: TodoTask?, owner: String, id: String, now: Long, today: Long): TodoTask {
        require(input.ownerKey == owner) { "Task belongs to another account" }
        require(input.status in STATUSES) { "Invalid task status" }
        require(input.title.trim().isNotEmpty() && input.title.length <= 500) { "Task title is required and must fit 500 characters" }
        require(input.notes.length <= 100_000 && input.groupName.length <= 200) { "Task text is too long" }
        listOfNotNull(input.scheduledDay, input.dueDay).forEach(::validateDay)
        val tags = todoTagsJson(parseTodoTags(input.tagsJson))
        val normalized = input.copy(id = id, title = input.title.trim(), groupName = input.groupName.trim(),
            tagsJson = tags, revision = (old?.revision ?: 0) + 1,
            createdAt = old?.createdAt ?: now, updatedAt = now, deletedAt = old?.deletedAt)
        if (input.status != "done") return normalized.copy(completedDay = null, completedAt = null, completionTagsJson = "[]")
        if (old?.status == "done") return normalized.copy(completedDay = old.completedDay,
            completedAt = old.completedAt, completionTagsJson = old.completionTagsJson)
        val completedDay = input.completedDay ?: today
        validateDay(completedDay)
        require(completedDay <= today) { "Completion date cannot be in the future" }
        return normalized.copy(completedDay = completedDay, completedAt = now, completionTagsJson = tags)
    }

    /** 日期采用公历epoch day，拒绝超出界面可表达的年份。 */
    fun validateDay(day: Long) {
        require(LocalDate.ofEpochDay(day).year in 1..9999) { "Date must use year 1 through 9999" }
    }
}
