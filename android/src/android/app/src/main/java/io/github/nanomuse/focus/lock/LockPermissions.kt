package io.github.nanomuse.focus.lock

import android.app.AlarmManager
import android.app.AppOpsManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import com.openminis.app.accessibility.MinisAccessibilityService

/** 仅查询授权状态与系统连接，不读取无障碍窗口内容。 */
object LockPermissions {
    /** 权限中心展示的五项必需权限以及一项电池建议。 */
    enum class Kind { ACCESSIBILITY, OVERLAY, USAGE, EXACT_ALARM, NOTIFICATIONS, BATTERY }

    /** 每次回到权限页及每次开始前重新读取系统状态。 */
    fun read(context: Context): LockPermissionState = LockPermissionState(
        Build.VERSION.SDK_INT, accessibilityEnabled(context), accessibilityConnected(),
        safely { Settings.canDrawOverlays(context) }, usageAccess(context),
        safely { Build.VERSION.SDK_INT < 31 || context.getSystemService(AlarmManager::class.java).canScheduleExactAlarms() },
        safely { NotificationManagerCompat.from(context).areNotificationsEnabled() },
        safely { context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName) }
    )

    /** 服务实例在onCreate就存在，必须再向系统查询有效的连接信息。 */
    fun accessibilityConnected(): Boolean = safely {
        MinisAccessibilityService.getInstance()?.serviceInfo != null
    }

    /** 精确匹配系统已授权组件，避免子串碰撞。 */
    private fun accessibilityEnabled(context: Context): Boolean = safely {
        val target = ComponentName(context, MinisAccessibilityService::class.java)
        val enabled = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
        enabled.split(':').any { ComponentName.unflattenFromString(it) == target }
    }

    /** 使用情况访问只能通过特殊授权页开启。 */
    fun usageAccess(context: Context): Boolean = safely {
        val ops = context.getSystemService(AppOpsManager::class.java)
        val mode = if (Build.VERSION.SDK_INT >= 29) ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        else @Suppress("DEPRECATION") ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        mode == AppOpsManager.MODE_ALLOWED
    }

    /** 系统不提供专用页面时回退到应用详情，返回失败由页面显示。 */
    fun open(context: Context, kind: Kind): Boolean {
        val packageUri = Uri.parse("package:${context.packageName}")
        val intent = when (kind) {
            Kind.ACCESSIBILITY -> Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            Kind.OVERLAY -> Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, packageUri)
            Kind.USAGE -> Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            Kind.EXACT_ALARM -> if (Build.VERSION.SDK_INT >= 31) Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, packageUri)
                else Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri)
            Kind.NOTIFICATIONS -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            Kind.BATTERY -> Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, packageUri)
        }
        return launch(context, intent) || launch(context, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri))
    }

    private fun launch(context: Context, intent: Intent): Boolean = safely {
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true
    }
    private inline fun safely(block: () -> Boolean): Boolean = try { block() } catch (_: Exception) { false }
}
