package io.github.nanomuse.routines

import com.openminis.app.data.db.FolderEntity
import com.openminis.app.scheduled.ScheduledTask

/** 只整理已明确标记为用户创建的任务，不根据scheduled或名称猜测。 */
object ScheduledConversationGroup {
    /**
     * 内置和隐藏的任务不自动产生系统分组归属。Mosaic: 记录来源之前建的任务（legacy）只要不隐藏、不属于目标，
     * 就是人建的：内置的动态任务追加到动态对话，目标巡检是隐藏的，都不走这里。
     */
    fun isUserTask(task: ScheduledTask): Boolean = task.origin in setOf("user_ui", "user_cli", "user_idea", "legacy") && !task.hidden && task.goalId == null

    /** 交给数据库事务与会话一并写入，不先创建会话再补分组。 */
    fun folder(): FolderEntity {
        val now = System.currentTimeMillis()
        val name = if (java.util.Locale.getDefault().language == "zh") "定时任务" else "Scheduled tasks"
        return FolderEntity(id = io.github.nanomuse.chat.GroupNamePolicy.SYSTEM_ID, name = name,
            origin = "system", createdAt = now, updatedAt = now)
    }
}
