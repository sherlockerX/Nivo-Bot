package io.github.nanomuse.focus

import android.app.*
import android.content.*
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import com.openminis.app.R
import kotlinx.coroutines.*

/** 使用系统闹钟唤醒结算，系统延迟只影响提示，不增加计时时长。 */
object FocusAlarm {
    private const val REQUEST=48110
    fun schedule(context:Context,row:FocusSession?) {
        val manager=context.getSystemService(AlarmManager::class.java)
        val intent=Intent(context,FocusAlarmReceiver::class.java)
        val existing=PendingIntent.getBroadcast(context,REQUEST,intent,PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
        existing?.let { manager.cancel(it);it.cancel() }
        if(row?.status!="running") return
        intent.putExtra("owner",row.ownerKey).putExtra("id",row.id)
        val pending=PendingIntent.getBroadcast(context,REQUEST,intent,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val deadline=SystemClock.elapsedRealtime()+(row.targetMs-FocusStore.elapsed(row,context)).coerceAtLeast(0)
        // 普通闹钟无需精确闹钟授权；省电模式下提示可能延后，UI说明这一限制。
        manager.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP,deadline,pending)
    }
}

/** 只结算当前账号的真实记录，通知不带用户任务文字。 */
class FocusAlarmReceiver:BroadcastReceiver() {
    override fun onReceive(context:Context,intent:Intent) {
        val pending=goAsync()
        CoroutineScope(SupervisorJob()+Dispatchers.IO).launch {
            try {
                val store=FocusStore.get(context)
                if(intent.getStringExtra("owner")!=store.ownerKey) return@launch
                val before=store.sessions().firstOrNull { it.id==intent.getStringExtra("id") } ?: return@launch
                store.refresh()
                if(before.status=="finished" && before.deletedAt==null) notifyFinished(context)
            } catch(cancelled:CancellationException) { throw cancelled }
            catch(_:Exception) { /* 账号切换或数据库不可用时不发布成功通知。 */ }
            finally { pending.finish() }
        }
    }
    private fun notifyFinished(context:Context) {
        val manager=context.getSystemService(NotificationManager::class.java)
        val channel="nanomuse_focus"
        manager.createNotificationChannel(NotificationChannel(channel,context.getString(R.string.nm_focus_title),NotificationManager.IMPORTANCE_DEFAULT))
        val launch=context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            action=Intent.ACTION_VIEW
            data=android.net.Uri.parse("nanomuse://views/focus")
        }
        val content=launch?.let { PendingIntent.getActivity(context,48111,it,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE) }
        val notification=NotificationCompat.Builder(context,channel).setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(context.getString(R.string.nm_focus_finished)).setContentText(context.getString(R.string.nm_focus_finished_hint))
            .setAutoCancel(true).setContentIntent(content).build()
        try { manager.notify(48111,notification) } catch(_:SecurityException) { /* 通知未授权时仍保留已结束记录。 */ }
    }
}
