package io.github.nanomuse.focus.lock

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.provider.Settings
import android.service.voice.VoiceInteractionService
import android.telecom.ConnectionService
import android.telecom.InCallService
import android.telecom.TelecomManager
import android.view.inputmethod.InputMethodManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** 读取已安装包和系统组件身份，不检查无障碍节点、窗口文字或控件内容。 */
object InstalledApps {
    private const val ICON_SIZE_PX = 132
    private const val ACTION_DIAL_EMERGENCY = "android.intent.action.DIAL_EMERGENCY"
    private const val ACTION_VOICE_ASSIST = "android.intent.action.VOICE_ASSIST"
    private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    private val SYSTEM_PHONE_PACKAGES = setOf("com.android.phone", "com.android.server.telecom")

    /** 列出系统可见的全部已安装包，包含后台包、禁用包和供聊天显式选择的本应用。 */
    suspend fun load(context: Context): List<InstalledApp> = withContext(Dispatchers.IO) {
        val packageManager = context.packageManager
        val installed = runCatching {
            packageManager.getInstalledApplications(PackageManager.MATCH_DISABLED_COMPONENTS)
        }.getOrDefault(emptyList())
        val access = accessContext(context, emptySet(), usesWhitelist = false)
        val apps = installed.map { info ->
            InstalledApp(
                packageName = info.packageName,
                label = runCatching { packageManager.getApplicationLabel(info).toString() }
                    .getOrDefault(info.packageName),
                isSystem = info.isSystemApplication(),
                isLaunchable = info.enabled && runCatching {
                    packageManager.getLaunchIntentForPackage(info.packageName) != null
                }.getOrDefault(false),
                isForbidden = false,
                isAlwaysAllowed = false
            )
        }
        LockAppRules.classifyApps(access, apps)
    }

    /** 按需载入单个图标并限制尺寸，避免应用列表同时保留数百个原始Drawable。 */
    suspend fun loadIcon(context: Context, packageName: String): Bitmap? =
        withContext(Dispatchers.IO) {
            runCatching {
                val drawable = context.packageManager.getApplicationIcon(packageName)
                Bitmap.createBitmap(ICON_SIZE_PX, ICON_SIZE_PX, Bitmap.Config.ARGB_8888).also {
                    drawable.setBounds(0, 0, ICON_SIZE_PX, ICON_SIZE_PX)
                    drawable.draw(Canvas(it))
                }
            }.getOrNull()
        }

    /** 解析实时系统身份；Nivo聊天必须同时启用白名单并显式包含本应用包名。 */
    fun accessContext(
        context: Context,
        whitelist: Set<String>,
        usesWhitelist: Boolean
    ): LockAccessPolicy.Context = LockAppRules.accessContext(
        context.packageName, resolveIdentities(context), whitelist, usesWhitelist
    )

    /** 预检至少一个已导出、已启用且不与永禁角色冲突的电话或紧急拨号入口。 */
    fun canDial(context: Context): Boolean = safeDialerTargets(context).isNotEmpty()

    /** 按默认电话、系统电话、紧急拨号依次尝试，只打开界面而不直接拨出号码。 */
    fun openDialer(context: Context): Boolean {
        for (target in safeDialerTargets(context)) {
            val action = if (target.isEmergency) ACTION_DIAL_EMERGENCY else Intent.ACTION_DIAL
            val intent = Intent(action).setClassName(target.packageName, target.className)
            if (startActivity(context, intent)) return true
        }
        return false
    }

    /** 启动普通白名单应用；本应用由宿主导航至受限聊天路由，永禁包始终拒绝。 */
    fun launch(context: Context, packageName: String): Boolean {
        if (packageName.isBlank() || packageName == context.packageName) return false
        val access = accessContext(context, emptySet(), usesWhitelist = false)
        if (LockAppRules.isForbidden(access, packageName)) return false
        val intent = runCatching {
            context.packageManager.getLaunchIntentForPackage(packageName)
        }.getOrNull() ?: return false
        val resolved = runCatching {
            context.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
        }.getOrNull()?.activityInfo ?: return false
        if (resolved.packageName != packageName || !canOpenActivity(context, resolved)) return false
        intent.component = ComponentName(resolved.packageName, resolved.name)
        intent.addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        return startActivity(context, intent)
    }

    private fun resolveIdentities(context: Context): LockAppRules.Identities {
        val telecom = context.getSystemService(TelecomManager::class.java)
        val defaultDialer = runCatching { telecom?.defaultDialerPackage }.getOrNull()
        val systemDialer = runCatching { telecom?.systemDialerPackage }.getOrNull()
        return LockAppRules.Identities(
            // Telecom的默认拨号器公开API读取系统角色结果，不将全部DIAL处理器当作角色。
            defaultDialerPackages = setOfNotNull(defaultDialer).filterTo(linkedSetOf()) {
                isInstalledAndEnabled(context, it)
            },
            systemDialerPackages = setOfNotNull(systemDialer).filterTo(linkedSetOf()) {
                isSystemPackage(context, it)
            },
            systemCallPackages = systemCallPackages(context),
            systemEmergencyPackages = queryActivities(context, Intent(ACTION_DIAL_EMERGENCY))
                .filter { it.applicationInfo.isSystemApplication() }
                .mapTo(linkedSetOf()) { it.packageName },
            launcherPackages = activityPackages(
                context, Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            ),
            installerPackages = installerPackages(context),
            assistantPackages = assistantPackages(context),
            settingsPackages = activityPackages(context, Intent(Settings.ACTION_SETTINGS)),
            currentImePackage = currentImePackage(context)
        )
    }

    private fun systemCallPackages(context: Context): Set<String> {
        val systemCalls = SYSTEM_PHONE_PACKAGES.filterTo(linkedSetOf()) {
            isSystemPackage(context, it)
        }
        systemCalls += servicePackages(
            context, InCallService.SERVICE_INTERFACE, Manifest.permission.BIND_INCALL_SERVICE,
            requiresSystem = true
        )
        systemCalls += servicePackages(
            context, ConnectionService.SERVICE_INTERFACE, Manifest.permission.BIND_TELECOM_CONNECTION_SERVICE,
            requiresSystem = true
        )
        return systemCalls
    }

    private fun installerPackages(context: Context): Set<String> =
        activityPackages(context, Intent(Intent.ACTION_INSTALL_PACKAGE).setType(APK_MIME_TYPE)) +
            activityPackages(
                context, Intent(Intent.ACTION_VIEW)
                    .setDataAndType(Uri.parse("content://io.github.nanomuse.focus/package.apk"), APK_MIME_TYPE)
            )

    private fun assistantPackages(context: Context): Set<String> =
        activityPackages(context, Intent(Intent.ACTION_ASSIST)) +
            activityPackages(context, Intent(ACTION_VOICE_ASSIST)) +
            servicePackages(
                context, VoiceInteractionService.SERVICE_INTERFACE,
                Manifest.permission.BIND_VOICE_INTERACTION, requiresSystem = false
            ) + setOfNotNull(
                secureComponentPackage(context, "assistant"),
                secureComponentPackage(context, "voice_interaction_service")
            )

    /** 输入法窗口出现时单独刷新当前身份，不等待全量应用角色缓存过期。 */
    fun currentImePackage(context: Context): String? {
        val configuredPackage = secureComponentPackage(context, Settings.Secure.DEFAULT_INPUT_METHOD)
            ?: return null
        val inputMethods = runCatching {
            context.getSystemService(InputMethodManager::class.java)?.enabledInputMethodList
        }.getOrNull().orEmpty()
        // 设置值还须与系统启用输入法列表相符，普通Activity不因包名匹配而得到豁免。
        return configuredPackage.takeIf { candidate -> inputMethods.any { it.packageName == candidate } }
    }

    private fun secureComponentPackage(context: Context, settingName: String): String? =
        runCatching {
            val component = Settings.Secure.getString(context.contentResolver, settingName)
                ?: return@runCatching null
            ComponentName.unflattenFromString(component)?.packageName
        }.getOrNull()

    private fun safeDialerTargets(context: Context): List<LockAppRules.DialerTarget> {
        val identities = resolveIdentities(context)
        val access = LockAppRules.accessContext(context.packageName, identities, emptySet(), false)
        val dialerPackages = identities.defaultDialerPackages + identities.systemDialerPackages
        val targets = dialerPackages.flatMap { packageName ->
            dialerTargets(context, Intent(Intent.ACTION_DIAL).setPackage(packageName), isEmergency = false)
        } + dialerTargets(context, Intent(ACTION_DIAL_EMERGENCY), isEmergency = true)
        return LockAppRules.safeDialerTargets(access, targets)
    }

    private fun dialerTargets(
        context: Context,
        intent: Intent,
        isEmergency: Boolean
    ): List<LockAppRules.DialerTarget> =
        queryActivities(context, intent).map { activity ->
            LockAppRules.DialerTarget(
                packageName = activity.packageName,
                className = activity.name,
                isEmergency = isEmergency,
                isExported = activity.exported,
                isEnabled = canOpenActivity(context, activity)
            )
        }

    private fun activityPackages(context: Context, intent: Intent): Set<String> =
        queryActivities(context, intent).mapTo(linkedSetOf()) { it.packageName }

    private fun queryActivities(context: Context, intent: Intent): List<ActivityInfo> =
        runCatching {
            context.packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
        }.getOrDefault(emptyList()).mapNotNull { it.activityInfo }

    private fun servicePackages(
        context: Context,
        action: String,
        permission: String,
        requiresSystem: Boolean
    ): Set<String> = runCatching {
        context.packageManager.queryIntentServices(Intent(action), 0)
    }.getOrDefault(emptyList()).mapNotNull { resolved ->
        resolved.serviceInfo?.takeIf { service ->
            service.enabled && service.applicationInfo.enabled && service.permission == permission &&
                (!requiresSystem || service.applicationInfo.isSystemApplication())
        }?.packageName
    }.toSet()

    private fun isInstalledAndEnabled(context: Context, packageName: String): Boolean =
        runCatching { context.packageManager.getApplicationInfo(packageName, 0).enabled }
            .getOrDefault(false)

    private fun isSystemPackage(context: Context, packageName: String): Boolean =
        runCatching {
            val info = context.packageManager.getApplicationInfo(packageName, 0)
            info.enabled && info.isSystemApplication()
        }.getOrDefault(false)

    private fun ApplicationInfo.isSystemApplication(): Boolean =
        flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0

    private fun canOpenActivity(context: Context, activity: ActivityInfo): Boolean =
        activity.enabled && activity.applicationInfo.enabled && activity.exported &&
            (activity.permission.isNullOrBlank() ||
                context.checkSelfPermission(activity.permission) == PackageManager.PERMISSION_GRANTED)

    private fun startActivity(context: Context, intent: Intent): Boolean =
        runCatching {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        }.getOrDefault(false)
}
