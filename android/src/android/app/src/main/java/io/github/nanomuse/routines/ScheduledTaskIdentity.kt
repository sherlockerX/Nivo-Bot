package io.github.nanomuse.routines

import com.openminis.app.scheduled.ScheduledTask

/** 完全重复的任务才拒绝，名称相同但目标或内容不同不会被误删。 */
object ScheduledTaskIdentity {
    /** 判断两个计划的执行语义是否完全相同，不比较运行历史和ID。 */
    fun same(first: ScheduledTask, second: ScheduledTask): Boolean =
        first.label.trim() == second.label.trim() && first.timesOfDay == second.timesOfDay &&
            first.repeatMode == second.repeatMode && first.customDays == second.customDays &&
            first.startDateMs == second.startDateMs && first.endDateMs == second.endDateMs &&
            first.intervalMinutes == second.intervalMinutes && first.goalId == second.goalId &&
            first.prompt.trim() == second.prompt.trim() && first.scriptId == second.scriptId &&
            first.scriptArgs == second.scriptArgs && first.requireOutput == second.requireOutput && first.origin == second.origin &&
            first.targetMode.encode() == second.targetMode.encode() && first.modelBinding == second.modelBinding && first.modelId == second.modelId
}
