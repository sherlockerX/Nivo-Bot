package io.github.nanomuse.routines

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import androidx.core.app.NotificationCompat
import com.openminis.app.R
import com.openminis.app.scheduled.ScheduledTask

/** 调度器直接发送有固定身份的失败提醒，不依赖模型或叠加相同任务通知。 */
object ScheduledRunAlerts {
    /** 连续失败至少两次时更新同一条提醒，自动停用时替换标题。 */
    fun changed(context: Context, task: ScheduledTask, outcome: String) {
        runCatching {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (outcome == "success") {
                manager.cancel("nm-task-failure:${task.id}", 1)
                return@runCatching
            }
            if (outcome != "failure" || task.consecutiveFailures < 2) return@runCatching
            manager.createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.nm_task_failures_channel), NotificationManager.IMPORTANCE_DEFAULT))
            // 升级提醒取代该任务的结果通知，同一任务在通知栏只留一条。
            ScheduledResultNotifier.withdraw(context, task.id)
            val title = if (!task.enabled && task.runtime.autoDisabledAtMs != null)
                context.getString(R.string.nm_task_auto_disabled, task.label)
            else context.getString(R.string.nm_task_failure_count, task.label, task.consecutiveFailures)
            manager.notify("nm-task-failure:${task.id}", 1, NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_notify_error).setContentTitle(title)
                .setContentText(task.runtime.lastReason.orEmpty())
                .setOnlyAlertOnce(task.runtime.autoDisabledAtMs != task.lastFiredAt).setAutoCancel(true).build())
        }
    }
    private const val CHANNEL = "nm-scheduled-failures"
}
