package io.github.nanomuse.focus.lock

import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.openminis.app.R
import io.github.nanomuse.ui.focus.FocusImmersiveActivity
import kotlinx.coroutines.*

/** 强制期间每秒结算、每500毫秒检查前台，不使用屏幕常亮唤醒锁。 */
class LockGuardService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var loop: Job? = null
    private var hasWarned = false
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) { LockController.onWake(context) }
    }

    override fun onCreate() {
        super.onCreate()
        ContextCompat.registerReceiver(this, screenReceiver, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_USER_PRESENT)
        }, ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(),
                if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0)
        } catch (_: Exception) { stopSelf(); return START_NOT_STICKY }
        if (loop?.isActive == true) return START_STICKY
        loop = scope.launch {
            val monitor = LockForegroundMonitor(this@LockGuardService)
            var tick = 0
            while (isActive) {
                try {
                    if (tick % 2 == 0 && LockController.evaluate(this@LockGuardService) == null) {
                        stopSelf(); break
                    }
                    val snapshot = LockRuntime.state.value
                    if (snapshot != null && getSystemService(PowerManager::class.java).isInteractive) {
                        val generation = LockRuntime.foregroundGeneration
                        val activity = monitor.sample(snapshot.run.id)
                        if (activity != null && LockRuntime.state.value?.run?.id == snapshot.run.id &&
                            ForegroundEvidencePolicy.canUse(activity, generation, LockRuntime.foregroundGeneration,
                                LockRuntime.foregroundPackage, LockRuntime.foregroundClass, LockRuntime.foregroundObservedWall)) {
                            LockController.enforce(this@LockGuardService,
                                LockAccessPolicy.Foreground(activity.packageName, activity.className))
                        }
                    }
                    if (tick % 10 == 0) getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification())
                    if (tick % 30 == 0 && !LockPermissions.accessibilityConnected() && !hasWarned) {
                        hasWarned = true; LockDiagnostics.record(this@LockGuardService, LockDiagnosticAction.SERVICE_LOST)
                    }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) {
                    LockDiagnostics.record(this@LockGuardService, LockDiagnosticAction.RESTORE)
                    // 结算出错时不能一直按住屏幕：截止已过就先放开，下一轮继续尝试结算。
                    if (LockRuntime.state.value != null && LockRuntime.remaining(this@LockGuardService) == 0L) LockRuntime.publish(null)
                }
                tick++; delay(500)
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        scope.cancel(); runCatching { unregisterReceiver(screenReceiver) }
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    /** 划掉任务不改变会话，独立闹钟继续承担进程回收后的恢复。 */
    override fun onTaskRemoved(rootIntent: Intent?) {
        LockController.requestEvaluation(this)
        super.onTaskRemoved(rootIntent)
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, getString(R.string.nm_lock_title), NotificationManager.IMPORTANCE_LOW))
        val snapshot = LockRuntime.state.value
        val launch = snapshot?.let { FocusImmersiveActivity.intent(this, it.run.ownerKey, it.run.sessionId) }
        val content = launch?.let { PendingIntent.getActivity(this, NOTIFICATION_ID, it,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE) }
        val remaining = LockRuntime.remaining(this)
        val countsUp = snapshot?.countsUp == true
        return NotificationCompat.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.ic_lock_idle_lock)
            .setContentTitle(getString(R.string.nm_lock_title))
            .setContentText(getString(if (hasWarned) R.string.nm_lock_stale else R.string.nm_lock_running))
            .setContentIntent(content).setOngoing(true).setOnlyAlertOnce(true)
            .setWhen(if (countsUp) snapshot!!.run.startedAt else System.currentTimeMillis() + remaining)
            .setUsesChronometer(remaining > 0).setChronometerCountDown(!countsUp)
            .setCategory(NotificationCompat.CATEGORY_SERVICE).build()
    }

    companion object {
        private const val CHANNEL = "nanomuse_focus_lock"
        private const val NOTIFICATION_ID = 48220
        /** 宿主启动失败不伪造结束，落盘会话留给恢复入口处理。 */
        fun ensure(context: Context) {
            try { ContextCompat.startForegroundService(context, Intent(context, LockGuardService::class.java)) }
            catch (_: Exception) { LockDiagnostics.record(context, LockDiagnosticAction.RESTORE) }
        }
        /** 完成时移除常驻通知和循环。 */
        fun stop(context: Context) { context.stopService(Intent(context, LockGuardService::class.java)) }
    }
}
