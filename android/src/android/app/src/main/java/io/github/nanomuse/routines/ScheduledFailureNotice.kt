package io.github.nanomuse.routines

import android.content.Context
import com.openminis.app.scheduled.ScheduledTaskStore

/** 在真正进入对话时补充可持久恢复的连续失败提示，不依赖通知权限。 */
object ScheduledFailureNotice {
    /** 每个失败次数和执行时间组合只提示一次，不清除任务历史。 */
    @Synchronized fun pending(context: Context): String {
        val preferences = context.getSharedPreferences("nm_schedule_notices", Context.MODE_PRIVATE)
        val tasks = ScheduledTaskStore(context).all().filter { it.consecutiveFailures >= 2 }
        val unseen = tasks.filter { preferences.getString(it.id, null) != "${it.consecutiveFailures}:${it.lastFiredAt}" }.take(3)
        val edit = preferences.edit()
        unseen.forEach { edit.putString(it.id, "${it.consecutiveFailures}:${it.lastFiredAt}") }
        edit.apply()
        return unseen.take(3).joinToString("、") { "${it.label.take(30)}(${it.consecutiveFailures})" }
    }
}
