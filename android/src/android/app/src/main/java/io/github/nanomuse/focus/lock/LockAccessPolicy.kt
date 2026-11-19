package io.github.nanomuse.focus.lock

/** 仅根据包名、类名和窗口类别判断访问，不读取窗口文字。强制期间Nivo只有锁页可用，不提供聊天豁免。 */
object LockAccessPolicy {
    private val SYSTEM_WINDOW_PACKAGES = setOf("android", "com.android.systemui")
    private val FORBIDDEN_PREFIXES = listOf(
        "com.android.settings", "com.android.packageinstaller", "com.google.android.packageinstaller",
        "com.android.permissioncontroller", "com.google.android.permissioncontroller",
        "com.android.launcher", "com.google.android.apps.nexuslauncher", "com.oplus.launcher",
        "com.oppo.launcher", "com.coloros.launcher", "com.bbk.launcher", "com.vivo.launcher",
        "com.vivo.agent", "com.vivo.assistant", "com.coloros.assistant", "com.coloros.speechassist",
        "com.heytap.speechassist", "com.oplus.aiunit", "com.oplus.ocs", "com.coloros.ocs",
        "com.oplus.smartengine", "com.oplus.pantanal", "com.google.android.googlequicksearchbox",
        "com.google.android.apps.googleassistant"
    )

    /** 到期由宿主先解除会话，不能继续解释为需要拦截。 */
    enum class Decision { ALLOW, BLOCK, EXPIRED }

    /** 区分普通应用窗口与当前输入法窗口，不依赖Android窗口类型常量。 */
    enum class WindowKind { APPLICATION, INPUT_METHOD, OTHER }

    /** 宿主解析后的应用身份与已生效策略；电话集合只能包含经系统确认的通话组件包。 */
    data class Context(
        val ownPackage: String,
        val lockActivityClass: String,
        val phonePackages: Set<String>,
        val currentImePackage: String?,
        val launcherPackages: Set<String>,
        val installerPackages: Set<String>,
        val assistantPackages: Set<String>,
        val whitelist: Set<String>,
        val usesWhitelist: Boolean
    )

    /** 当前前台的可信元数据。 */
    data class Foreground(
        val packageName: String?,
        val className: String? = null,
        val windowKind: WindowKind = WindowKind.APPLICATION,
        val isActivity: Boolean = true
    )

    /** 无锁直接放行；活动锁先判断到期，再计算窗口和Activity访问策略。 */
    fun decide(
        context: Context,
        foreground: Foreground,
        isLocked: Boolean,
        remainingMs: Long,
        currentImePackage: String? = context.currentImePackage
    ): Decision {
        if (!isLocked) return Decision.ALLOW
        if (remainingMs <= 0L) return Decision.EXPIRED
        val packageName = foreground.packageName
        // 电话窗口可能不提供包名，证据缺失时不猜测身份或触发拦截。
        if (packageName.isNullOrBlank()) return Decision.ALLOW
        val access = if (foreground.windowKind == WindowKind.INPUT_METHOD)
            context.copy(currentImePackage = currentImePackage) else context
        return decideKnownForeground(access, foreground, packageName)
    }

    private fun decideKnownForeground(
        context: Context,
        foreground: Foreground,
        packageName: String
    ): Decision = when {
        // 本包不继承任何包级豁免：只有锁页可留在前台，聊天、设置等页面一律拉回锁页。
        packageName == context.ownPackage ->
            if (foreground.className == context.lockActivityClass) Decision.ALLOW else Decision.BLOCK
        isCurrentInputMethod(context, foreground, packageName) -> Decision.ALLOW
        isSystemWindow(foreground, packageName) -> Decision.ALLOW
        // Activity的永禁规则优先于冲突的包级分类，宿主不能把桌面当拨号器放行。
        isNeverAllowed(context, packageName) -> Decision.BLOCK
        packageName in context.phonePackages -> Decision.ALLOW
        context.usesWhitelist && packageName in context.whitelist -> Decision.ALLOW
        else -> Decision.BLOCK
    }

    private fun isCurrentInputMethod(
        context: Context,
        foreground: Foreground,
        packageName: String
    ): Boolean = packageName == context.currentImePackage &&
        foreground.windowKind == WindowKind.INPUT_METHOD

    private fun isSystemWindow(foreground: Foreground, packageName: String): Boolean =
        !foreground.isActivity && packageName in SYSTEM_WINDOW_PACKAGES

    /** 桌面、安装器、设置、权限页和语音助手，即使在白名单里也不放行；窗口遮挡与拉回共用这条规则。 */
    fun isNeverAllowedPackage(context: Context, packageName: String): Boolean = isNeverAllowed(context, packageName)

    private fun isNeverAllowed(context: Context, packageName: String): Boolean =
        packageName in context.launcherPackages || packageName in context.installerPackages ||
            packageName in context.assistantPackages ||
            FORBIDDEN_PREFIXES.any { packageName.startsWith(it) }
}
