package io.github.nanomuse.focus.lock

/** 最近一次Activity进入前台的元数据，不包含页面内容。 */
internal data class ForegroundActivity(
    val packageName: String,
    val className: String?,
    val timestamp: Long
)

/** 仅保留影响Activity前台状态的生命周期事件。 */
internal enum class ForegroundLifecycle { RESUMED, PAUSED, STOPPED }

/** 保留事件时间水位和同毫秒去重记录，重叠查询不会复活已经退出的Activity。 */
internal class UsageForegroundTracker {
    var current: ForegroundActivity? = null
        private set
    private var latestTimestamp = Long.MIN_VALUE
    private val eventsAtLatestTime = mutableSetOf<EventIdentity>()

    /** 按时间接收生命周期；公开API只提供包名和类名，离开事件仅撤销对应Activity。 */
    fun accept(
        type: ForegroundLifecycle,
        packageName: String?,
        className: String?,
        timestamp: Long
    ) {
        if (packageName.isNullOrBlank() || timestamp < latestTimestamp) return
        if (timestamp > latestTimestamp) {
            latestTimestamp = timestamp
            eventsAtLatestTime.clear()
        }
        if (!eventsAtLatestTime.add(EventIdentity(type, packageName, className))) return
        if (type == ForegroundLifecycle.RESUMED) {
            current = ForegroundActivity(packageName, className, timestamp)
        } else if (matchesCurrent(packageName, className)) {
            current = null
        }
    }

    /** 新会话或墙钟跳变后丢弃旧时基上的状态。 */
    fun reset() {
        current = null
        latestTimestamp = Long.MIN_VALUE
        eventsAtLatestTime.clear()
    }

    private fun matchesCurrent(packageName: String, className: String?): Boolean {
        val activity = current ?: return false
        return activity.packageName == packageName && activity.className == className
    }

    /** 同毫秒的不同事件仍按首次查询顺序处理，跨查询重放同一事件则忽略。 */
    private data class EventIdentity(
        val type: ForegroundLifecycle,
        val packageName: String,
        val className: String?
    )
}

/** 较新的可靠前台观察优先于旧使用记录，不按固定年龄放开仍在前台的禁用应用。 */
internal object ForegroundEvidencePolicy {
    /** 查询中发生切换或结果不新于相矛盾的观察时，旧结果不能触发拉回。 */
    fun canUse(
        activity: ForegroundActivity,
        queriedGeneration: Long,
        observedGeneration: Long,
        observedPackage: String?,
        observedClass: String?,
        observedWall: Long
    ): Boolean {
        if (queriedGeneration != observedGeneration) return false
        if (activity.timestamp > observedWall || observedPackage.isNullOrBlank()) return true
        if (activity.packageName != observedPackage) return false
        return activity.className == null || observedClass == null || activity.className == observedClass
    }
}
