package io.github.nanomuse.focus.lock

import java.util.Locale

/** 白名单目录的一项，后台应用保留在目录，图标由宿主按需读取。 */
data class InstalledApp(
    val packageName: String,
    val label: String,
    val isSystem: Boolean,
    val isLaunchable: Boolean,
    val isForbidden: Boolean,
    val isAlwaysAllowed: Boolean
)

/** 将系统确认的身份转为无Android依赖的目录和访问规则。 */
object LockAppRules {
    /** 宿主仅能将默认角色及校验过的系统通话组件放入电话集合。 */
    data class Identities(
        val defaultDialerPackages: Set<String> = emptySet(),
        val systemDialerPackages: Set<String> = emptySet(),
        val systemCallPackages: Set<String> = emptySet(),
        val systemEmergencyPackages: Set<String> = emptySet(),
        val launcherPackages: Set<String> = emptySet(),
        val installerPackages: Set<String> = emptySet(),
        val assistantPackages: Set<String> = emptySet(),
        val settingsPackages: Set<String> = emptySet(),
        val currentImePackage: String? = null
    )

    /** 可显式启动的拨号组件，不包含电话号码和窗口文字。 */
    data class DialerTarget(
        val packageName: String,
        val className: String,
        val isEmergency: Boolean = false,
        val isExported: Boolean = true,
        val isEnabled: Boolean = true
    )

    /** 将身份和用户白名单转为访问策略上下文。 */
    fun accessContext(
        ownPackage: String,
        identities: Identities,
        whitelist: Set<String>,
        usesWhitelist: Boolean
    ): LockAccessPolicy.Context {
        val base = LockAccessPolicy.Context(
            ownPackage = ownPackage,
            lockActivityClass = "io.github.nanomuse.ui.focus.FocusImmersiveActivity",
            phonePackages = emptySet(),
            currentImePackage = identities.currentImePackage,
            launcherPackages = identities.launcherPackages,
            // 现有P1没有设置集合字段，设置和安装器统一通过永禁入口集合传递。
            installerPackages = identities.installerPackages + identities.settingsPackages,
            assistantPackages = identities.assistantPackages,
            whitelist = emptySet(),
            usesWhitelist = usesWhitelist
        )
        val trustedPhonePackages = identities.defaultDialerPackages + identities.systemDialerPackages +
            identities.systemCallPackages + identities.systemEmergencyPackages
        return base.copy(
            phonePackages = trustedPhonePackages.filterTo(linkedSetOf()) {
                it.isNotBlank() && it != ownPackage && !isForbidden(base, it)
            },
            // 旧版本可能把Nivo自身存进白名单，强制期间Nivo只开放锁页，这里一律剔除。
            whitelist = whitelist.filterTo(linkedSetOf()) {
                it.isNotBlank() && it != ownPackage && !isForbidden(base, it)
            }
        )
    }

    /** 使用与守护相同的策略判定包级永禁属性。 */
    fun isForbidden(context: LockAccessPolicy.Context, packageName: String): Boolean {
        if (packageName == context.ownPackage) return false
        // 临时显式白名单只用于查询永禁规则，不修改真实会话策略。
        val probe = context.copy(whitelist = setOf(packageName), usesWhitelist = true)
        return LockAccessPolicy.decide(
            probe, LockAccessPolicy.Foreground(packageName), isLocked = true, remainingMs = 1L
        ) == LockAccessPolicy.Decision.BLOCK
    }

    /** 过滤电话候选组件，保留宿主给出的默认、系统和紧急拨号顺序。 */
    fun safeDialerTargets(
        context: LockAccessPolicy.Context,
        targets: List<DialerTarget>
    ): List<DialerTarget> = targets.filter {
        it.packageName.isNotBlank() && it.className.isNotBlank() &&
            it.packageName != context.ownPackage && it.isExported && it.isEnabled &&
            it.packageName in context.phonePackages && !isForbidden(context, it.packageName)
    }.distinctBy { it.packageName to it.className }

    /** 分类全部已安装包并稳定排序，不剔除无桌面入口的后台包。 */
    fun classifyApps(
        context: LockAccessPolicy.Context,
        apps: List<InstalledApp>
    ): List<InstalledApp> = apps.distinctBy { it.packageName }.map { app ->
        val isForbidden = isForbidden(context, app.packageName)
        app.copy(
            isForbidden = isForbidden,
            isAlwaysAllowed = !isForbidden && app.packageName in context.phonePackages
        )
    }.sortedWith(
        compareByDescending<InstalledApp> { it.isLaunchable }
            .thenBy { it.label.firstOrNull()?.isLetter() != true }
            .thenBy { it.label.lowercase(Locale.ROOT) }
            .thenBy { it.packageName }
    )
}
