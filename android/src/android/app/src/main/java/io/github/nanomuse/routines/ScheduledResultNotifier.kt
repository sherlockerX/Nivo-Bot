package io.github.nanomuse.routines

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import com.openminis.app.R
import com.openminis.app.scheduled.ScheduledTask
import org.json.JSONObject
import java.time.LocalTime

/**
 * 定时任务的结果通知：一次运行最多一条，同一任务在通知栏最多一条（固定 tag 替换）。
 * 是否推送由任务的通知策略、6 小时内的结果去重、限流和静音时段决定，决定本身写进运行日志。
 */
object ScheduledResultNotifier {
    private const val CHANNEL = "scheduled_result"
    private const val QUIET_CHANNEL = "scheduled_result_quiet"
    private const val GROUP = "scheduled_tasks"
    private const val SUMMARY_TAG = "sched:summary"
    private const val OVERFLOW_TAG = "sched:overflow"
    private const val DEDUP_MS = 6 * 60 * 60 * 1000L
    private const val TASK_MIN_INTERVAL_MS = 60_000L
    private const val HOUR_MS = 60 * 60 * 1000L
    private const val HOURLY_CAP = 10
    const val DEFAULT_QUIET_HOURS = "01:00-08:00"
    val POLICIES = listOf("always", "on_change", "on_failure", "never")

    /** 一次运行的通知决定；不推送时 [suppressed] 说明原因，推送但不响铃时 [silentReason] 说明原因。 */
    data class Decision(val notify: Boolean, val reason: String?, val suppressed: String?, val silentReason: String? = null) {
        fun write(target: JSONObject): JSONObject = target.put("notified", notify)
            .put("notify_reason", reason ?: JSONObject.NULL).put("notify_suppressed_reason", suppressed ?: JSONObject.NULL)
            .put("notify_silent_reason", silentReason ?: JSONObject.NULL)
    }

    fun tag(taskId: String) = "sched:$taskId"

    @Synchronized
    fun decide(context: Context, task: ScheduledTask, result: ScheduledResult, failed: Boolean, firstFailure: Boolean, debug: Boolean): Decision {
        if (debug) return Decision(false, null, "debug")
        if (task.notifyPolicy == "never") return Decision(false, null, "policy_never")
        val now = System.currentTimeMillis()
        val reason = if (failed) {
            // 连续失败由失败提醒（同样固定 tag）升级，不再推第二条结果通知。
            if (!firstFailure) return Decision(false, null, "failure_alert")
            "failure"
        } else {
            if (task.notifyPolicy == "on_failure") return Decision(false, null, "policy_on_failure")
            val hash = result.hash ?: return Decision(false, null, "empty")
            val prefs = prefs(context)
            if (task.notifyPolicy == "on_change" && prefs.getString("hash:${task.id}", null) == hash &&
                now - prefs.getLong("at:${task.id}", 0L) < DEDUP_MS) return Decision(false, null, "unchanged")
            if (task.notifyPolicy == "always") "always" else "changed"
        }
        if (recent(context, now).size >= HOURLY_CAP) return Decision(false, reason, "rate_limited")
        val silent = when {
            task.notifySilent -> "silent"
            inQuietHours(context, now) -> "quiet_hours"
            now - prefs(context).getLong("at:${task.id}", 0L) < TASK_MIN_INTERVAL_MS -> "rate_limited"
            else -> null
        }
        return Decision(true, reason, null, silent)
    }

    /** 按决定推送；超过每小时上限时只更新一条合并通知。 */
    @Synchronized
    fun deliver(context: Context, task: ScheduledTask, title: String, body: String, dedupHash: String?, decision: Decision, sessionId: String? = null) {
        runCatching {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            ensureChannels(context, manager)
            if (!decision.notify) {
                if (decision.suppressed == "rate_limited") overflow(context, manager)
                return@runCatching
            }
            manager.cancel(task.id.hashCode() and 0x7FFFFFFF) // 旧版本不带 tag 的同任务通知。
            val shown = body.take(ScheduledResult.MAX_CHARS)
            val others = siblings(manager, tag(task.id))
            manager.notify(tag(task.id), task.id.hashCode(), NotificationCompat.Builder(context, if (decision.silentReason == null) CHANNEL else QUIET_CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_nanomuse)
                .setLargeIcon(io.github.nanomuse.identity.NanoMuseIdentity.face(context))
                .setContentTitle(title)
                .setContentText(shown)
                .setStyle(NotificationCompat.BigTextStyle().bigText(shown))
                .setOnlyAlertOnce(true)
                .setAutoCancel(true)
                .apply { if (others.isNotEmpty()) setGroup(GROUP) } // Mosaic: 两条以上才成组。
                .setContentIntent(open(context, task.id, sessionId))
                .build())
            arrange(context, manager, others, title)
            val now = System.currentTimeMillis()
            prefs(context).edit().putString("hash:${task.id}", dedupHash).putLong("at:${task.id}", now)
                .putString("recent", (recent(context, now) + now).joinToString(",")).apply()
        }.onFailure { com.openminis.app.logging.AppLogger.warning("ScheduledResult", "notify failed: ${it.message}") }
    }

    /** 删除任务时撤回它留在通知栏里的结果。 */
    fun cancel(context: Context, taskId: String) {
        runCatching {
            withdraw(context, taskId)
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).cancel(taskId.hashCode() and 0x7FFFFFFF)
            prefs(context).edit().remove("hash:$taskId").remove("at:$taskId").apply()
        }
    }

    /** Mosaic: 只撤回这条结果通知（失败提醒取代它时也用），去重记录保留。 */
    @Synchronized
    fun withdraw(context: Context, taskId: String) {
        runCatching {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val others = siblings(manager, tag(taskId))
            manager.cancel(tag(taskId), taskId.hashCode())
            arrange(context, manager, others, null)
        }
    }

    /** 通知栏里其他定时任务结果（含合并通知），不含摘要和刚变化的这一条：notify 与 cancel 是异步的，它按调用方给的状态计。 */
    private fun siblings(manager: NotificationManager, changedTag: String) = manager.activeNotifications
        .filter { it.tag?.startsWith("sched:") == true && it.tag != SUMMARY_TAG && it.tag != changedTag }

    /**
     * Mosaic: 两条以上时成组并发摘要，写明条数和最近一条的标题；只剩一条或没有时撤掉摘要，
     * 不在通知栏留一行空白的“定时任务”。系统撤摘要会连同组内子通知一起撤，所以先把剩下的那条
     * 原地更新为不分组（只提醒一次，不再响），再撤摘要。[postedTitle] 非空表示刚发出一条，为空表示刚撤回一条。
     */
    private fun arrange(context: Context, manager: NotificationManager, others: List<android.service.notification.StatusBarNotification>, postedTitle: String?) {
        val count = others.size + if (postedTitle != null) 1 else 0
        val grouped = count >= 2
        others.filter { (it.notification.group == GROUP) != grouped }.forEach { sbn ->
            manager.notify(sbn.tag, sbn.id, android.app.Notification.Builder.recoverBuilder(context, sbn.notification)
                .setGroup(if (grouped) GROUP else null).build())
        }
        if (!grouped) { manager.cancel(SUMMARY_TAG, 0); return }
        val latest = postedTitle ?: others.maxBy { it.postTime }.notification.extras.getCharSequence(android.app.Notification.EXTRA_TITLE)
        manager.notify(SUMMARY_TAG, 0, NotificationCompat.Builder(context, QUIET_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_nanomuse)
            .setContentTitle(context.getString(R.string.nm_sched_result_overflow, count))
            .setContentText(latest)
            .setGroup(GROUP).setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
            .setContentIntent(open(context, null))
            .build())
    }

    fun quietHours(context: Context): String = prefs(context).getString("quiet_hours", null) ?: DEFAULT_QUIET_HOURS

    /** `HH:MM-HH:MM` 或 `off`。 */
    fun setQuietHours(context: Context, value: String) {
        require(value == "off" || parseRange(value) != null) { "--quiet-hours must be HH:MM-HH:MM or off" }
        prefs(context).edit().putString("quiet_hours", value).apply()
    }

    private fun inQuietHours(context: Context, now: Long): Boolean {
        val (start, end) = parseRange(quietHours(context)) ?: return false
        val minute = java.time.Instant.ofEpochMilli(now).atZone(java.time.ZoneId.systemDefault()).toLocalTime().let { it.hour * 60 + it.minute }
        return if (start <= end) minute in start until end else minute >= start || minute < end
    }

    private fun parseRange(value: String): Pair<Int, Int>? = runCatching {
        val (from, to) = value.split("-").map { LocalTime.parse(it.trim()) }
        from.hour * 60 + from.minute to to.hour * 60 + to.minute
    }.getOrNull()

    private fun recent(context: Context, now: Long): List<Long> = prefs(context).getString("recent", "").orEmpty()
        .split(",").mapNotNull { it.toLongOrNull() }.filter { now - it < HOUR_MS }

    private fun overflow(context: Context, manager: NotificationManager) {
        val prefs = prefs(context)
        val now = System.currentTimeMillis()
        val count = if (now - prefs.getLong("overflow_since", 0L) < HOUR_MS) prefs.getInt("overflow", 0) + 1 else 1
        if (count == 1) prefs.edit().putLong("overflow_since", now).apply()
        prefs.edit().putInt("overflow", count).apply()
        val title = context.getString(R.string.nm_sched_result_overflow, count)
        val others = siblings(manager, OVERFLOW_TAG)
        manager.notify(OVERFLOW_TAG, 0, NotificationCompat.Builder(context, QUIET_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_nanomuse)
            .setContentTitle(title)
            .setOnlyAlertOnce(true).setAutoCancel(true)
            .apply { if (others.isNotEmpty()) setGroup(GROUP) } // Mosaic
            .setContentIntent(open(context, null))
            .build())
        arrange(context, manager, others, title)
    }

    /** 点击进任务的运行记录（结果全文、退出码、错误输出）。Mosaic: 结果写进了任务的对话时进这个对话。 */
    private fun open(context: Context, taskId: String?, sessionId: String? = null): PendingIntent {
        val link = Uri.parse(when {
            sessionId != null -> "minis://session/$sessionId"
            taskId == null -> "minis://settings/scheduled_tasks"
            else -> "minis://settings/scheduled_tasks/$taskId"
        })
        val intent = io.github.nanomuse.deeplink.OwnScheme.intent(context, link, Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(context, (taskId ?: "sched:list").hashCode(), intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun ensureChannels(context: Context, manager: NotificationManager) {
        if (manager.getNotificationChannel(CHANNEL) == null) manager.createNotificationChannel(
            NotificationChannel(CHANNEL, context.getString(R.string.nm_sched_result_channel), NotificationManager.IMPORTANCE_DEFAULT))
        if (manager.getNotificationChannel(QUIET_CHANNEL) == null) manager.createNotificationChannel(
            NotificationChannel(QUIET_CHANNEL, context.getString(R.string.nm_sched_result_quiet_channel), NotificationManager.IMPORTANCE_LOW))
    }

    private fun prefs(context: Context) = context.getSharedPreferences("nm_scheduled_notify", Context.MODE_PRIVATE)
}
