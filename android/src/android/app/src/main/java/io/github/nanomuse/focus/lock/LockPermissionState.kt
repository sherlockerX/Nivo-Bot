package io.github.nanomuse.focus.lock

/** 权限页与开始入口共用的授权快照，不依赖Android。 */
data class LockPermissionState(
    val sdk: Int, val isAccessibilityEnabled: Boolean, val isAccessibilityConnected: Boolean,
    val hasOverlay: Boolean, val hasUsageAccess: Boolean, val hasExactAlarms: Boolean,
    val hasNotifications: Boolean, val isBatteryUnrestricted: Boolean
) {
    /** 强制专注的最低系统版本与本次授权必须同时满足。 */
    val isReady: Boolean get() = sdk >= 30 && isAccessibilityEnabled && isAccessibilityConnected &&
        hasOverlay && hasUsageAccess && hasExactAlarms && hasNotifications
    /** 已开启但尚未实际连接时需要用户重开服务。 */
    val isAccessibilityStale: Boolean get() = isAccessibilityEnabled && !isAccessibilityConnected
}
