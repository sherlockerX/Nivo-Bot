package io.github.nanomuse.focus.lock

import android.app.*
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.app.NotificationCompat
import com.openminis.app.R
import io.github.nanomuse.account.AccountData
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** 独立完成回执使结束闹钟、服务与页面结算不重复提示。 */
object LockNotifications {
    private var warnedWindow: Set<String>? = null

    /** 同一时段只提示一次授权不足，30秒重试由独立闹钟负责。 */
    fun waitingPermissions(context: Context, window: LockWindow) {
        if (warnedWindow == window.occurrenceIds) return
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("nanomuse_focus_lock_setup", context.getString(R.string.nm_lock_permissions), NotificationManager.IMPORTANCE_DEFAULT))
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            action = Intent.ACTION_VIEW; data = Uri.parse("nanomuse://views/focus")
        }
        val content = launch?.let { PendingIntent.getActivity(context, 48252, it,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE) }
        runCatching { manager.notify(48252, NotificationCompat.Builder(context, "nanomuse_focus_lock_setup")
            .setSmallIcon(android.R.drawable.ic_lock_idle_lock).setContentTitle(context.getString(R.string.nm_lock_permissions))
            .setContentText(context.getString(R.string.nm_lock_schedule_waiting)).setContentIntent(content).setAutoCancel(true).build())
            warnedWindow = window.occurrenceIds
        }
    }
    /** 实际结束按运行身份通知，冷启动只补近期历史，不因改墙钟漏掉自然到期。 */
    suspend fun completed(context: Context, store: LockStore, previousRunId: String? = null) = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        val runs = store.runs()
        val eligible = runs.filter { LockCompletionPolicy.shouldNotify(it.status, it.id, it.endedAt, now, previousRunId) }
        val run = eligible.firstOrNull { it.id == previousRunId } ?: eligible.firstOrNull() ?: return@withContext
        if (AccountData.epoch.value != store.ownerEpoch || AccountData.key(context) != run.ownerKey) return@withContext
        synchronized(this@LockNotifications) {
            val preferences = context.getSharedPreferences("focus-lock-notifications", Context.MODE_PRIVATE)
            val receipt = "${run.ownerKey}:${run.id}"
            val seen = preferences.getStringSet("delivered", emptySet()).orEmpty()
            if (receipt in seen) return@synchronized
            if (!preferences.edit().putStringSet("delivered", (seen.takeLastBounded() + receipt).toSet()).commit()) return@synchronized
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel("nanomuse_focus", context.getString(R.string.nm_focus_title), NotificationManager.IMPORTANCE_DEFAULT))
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                action = Intent.ACTION_VIEW; data = Uri.parse("nanomuse://views/focus")
            }
            val content = launch?.let { PendingIntent.getActivity(context, 48251, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE) }
            val notification = NotificationCompat.Builder(context, "nanomuse_focus")
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm).setContentTitle(context.getString(R.string.nm_focus_finished))
                .setContentText(context.getString(R.string.nm_focus_finished_hint)).setOnlyAlertOnce(true)
                .setContentIntent(content).setAutoCancel(true).build()
            runCatching { manager.notify(48251, notification) }
        }
    }

    private fun Set<String>.takeLastBounded(): List<String> = toList().takeLast(127)
}
