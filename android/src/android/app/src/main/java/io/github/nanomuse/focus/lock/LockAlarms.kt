package io.github.nanomuse.focus.lock

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.focus.FocusStore
import io.github.nanomuse.ui.focus.FocusImmersiveActivity

/** 独立于普通专注的闹钟身份，结束广播只请求重新结算，不能直接解除会话。 */
object LockAlarms {
    private val scheduled = mutableMapOf<String, Long>()

    /** 只在投影或账号变化时重设，避免每秒心跳反复取消临近闹钟。 */
    @Synchronized
    fun sync(context: Context, run: LockRun?) {
        if (run == null) {
            listOf("end", "elapsed-end", "watchdog").forEach { cancel(context, it) }
            return
        }
        val boot = FocusStore.boot(context).takeIf { it >= 0 } ?: LockRun.PROCESS_BOOT_COUNT
        val times = LockAlarmPolicy.deadlines(run, System.currentTimeMillis(), SystemClock.elapsedRealtime(), boot) ?: return
        schedule(context, "end", times.wallEnd, run)
        schedule(context, "elapsed-end", times.elapsedEnd, run)
        val old = scheduled["watchdog"]
        if (old == null || old <= SystemClock.elapsedRealtime()) schedule(context, "watchdog", times.watchdogElapsed, run)
    }

    /** 下一计划或权限重试与结束闹钟各自保存，互不覆盖。 */
    @Synchronized
    fun scheduleStart(context: Context, at: Long?) {
        if (at == null) cancel(context, "start") else schedule(context, "start", at, null)
    }

    /** 系统重启、时间变更或闹钟送达后清掉进程内缓存，保留持久会话。 */
    @Synchronized
    fun invalidate() { scheduled.clear() }

    private fun schedule(context: Context, kind: String, at: Long, run: LockRun?) {
        if (scheduled[kind]?.let { kotlin.math.abs(it - at) < 1000 } == true) return
        val manager = context.getSystemService(AlarmManager::class.java)
        val pending = pending(context, kind, run, PendingIntent.FLAG_UPDATE_CURRENT) ?: return
        try {
            val isElapsed = kind in setOf("elapsed-end", "watchdog")
            val exact = Build.VERSION.SDK_INT < 31 || manager.canScheduleExactAlarms()
            if (!isElapsed && exact) {
                val show = run?.let { FocusImmersiveActivity.intent(context, it.ownerKey, it.sessionId) }
                    ?: context.packageManager.getLaunchIntentForPackage(context.packageName)!!
                val content = PendingIntent.getActivity(context, 48241, show,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                manager.setAlarmClock(AlarmManager.AlarmClockInfo(at, content), pending)
            } else {
                val type = if (isElapsed) AlarmManager.ELAPSED_REALTIME_WAKEUP else AlarmManager.RTC_WAKEUP
                if (exact) manager.setExactAndAllowWhileIdle(type, at, pending)
                else manager.setAndAllowWhileIdle(type, at, pending)
            }
            scheduled[kind] = at
        } catch (_: Exception) { LockDiagnostics.record(context, LockDiagnosticAction.RESTORE) }
    }

    private fun pending(context: Context, kind: String, run: LockRun?, flags: Int): PendingIntent? {
        val intent = Intent(context, LockAlarmReceiver::class.java).setAction("io.github.nanomuse.focus.lock.ALARM")
            .setData(Uri.parse("nanomuse-lock://alarm/$kind"))
            .putExtra("owner", run?.ownerKey ?: AccountData.key(context)).putExtra("run", run?.id)
        return PendingIntent.getBroadcast(context, 48240, intent, flags or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun cancel(context: Context, kind: String) {
        pending(context, kind, null, PendingIntent.FLAG_NO_CREATE)?.let {
            context.getSystemService(AlarmManager::class.java).cancel(it); it.cancel()
        }
        scheduled.remove(kind)
    }
}
