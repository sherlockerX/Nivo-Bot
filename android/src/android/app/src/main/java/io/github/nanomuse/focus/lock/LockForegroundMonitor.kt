package io.github.nanomuse.focus.lock

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.SystemClock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.abs

/** 每500毫秒由守护调用，使用事件生命周期兜底，不访问无障碍内容。 */
internal class LockForegroundMonitor(private val context: Context) {
    private var session: String? = null
    private var lastWall = 0L
    private var lastElapsed = 0L
    private val tracker = UsageForegroundTracker()

    /** 同一服务串行调用；会话切换或墙钟跳变时丢弃旧查询基线。 */
    suspend fun sample(sessionId: String): ForegroundActivity? = withContext(Dispatchers.IO) {
        if (!LockPermissions.usageAccess(context)) return@withContext null
        val wall = System.currentTimeMillis()
        val elapsed = SystemClock.elapsedRealtime()
        if (session != sessionId || lastWall > 0 && abs((wall - lastWall) - (elapsed - lastElapsed)) > 5000) {
            session = sessionId; lastWall = 0; tracker.reset()
        }
        val manager = context.getSystemService(UsageStatsManager::class.java)
        val events = manager.queryEvents((if (lastWall == 0L) wall - 30_000 else lastWall - 2000).coerceAtLeast(0), wall)
            ?: return@withContext null
        val event = UsageEvents.Event()
        while (events.hasNextEvent()) {
            if (!events.getNextEvent(event)) break
            val type = when (event.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> ForegroundLifecycle.RESUMED
                UsageEvents.Event.ACTIVITY_PAUSED -> ForegroundLifecycle.PAUSED
                UsageEvents.Event.ACTIVITY_STOPPED -> ForegroundLifecycle.STOPPED
                else -> null
            }
            if (type != null) tracker.accept(type, event.packageName, event.className, event.timeStamp)
        }
        lastWall = wall; lastElapsed = elapsed
        tracker.current
    }
}
