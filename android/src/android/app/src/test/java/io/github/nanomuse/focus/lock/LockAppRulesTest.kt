package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 使用可信系统身份快照验证目录分类、电话兜底及本应用聊天边界。 */
class LockAppRulesTest {
    private val ownPackage = "test.nivo"
    private val identities = LockAppRules.Identities(
        defaultDialerPackages = setOf("test.dialer"),
        systemDialerPackages = setOf("test.systemdialer"),
        systemCallPackages = setOf("test.incall", "test.telecom"),
        systemEmergencyPackages = setOf("test.emergency"),
        launcherPackages = setOf("test.home"),
        installerPackages = setOf("test.installer"),
        assistantPackages = setOf("test.assistant"),
        settingsPackages = setOf("test.settings"),
        currentImePackage = "test.ime"
    )

    /** 电话集合只能由调用方已确认的系统角色形成。 */
    @Test
    fun should_allowTrustedPhonePackages_when_rolesAreResolved() {
        val context = context()
        assertEquals(
            setOf("test.dialer", "test.systemdialer", "test.incall", "test.telecom", "test.emergency"),
            context.phonePackages
        )
    }

    /** 任意注册DIAL的应用不能通过候选查询取得电话豁免。 */
    @Test
    fun should_rejectUnknownDialHandler_when_notAssignedPhoneRole() {
        val targets = listOf(target("test.video"), target("test.dialer"))
        assertEquals(listOf("test.dialer"), safeTargets(targets).map { it.packageName })
    }

    /** 拨号角色与永禁角色冲突时仍然禁止该包。 */
    @Test
    fun should_removeConflictingPhonePackages_when_alsoForbidden() {
        val conflict = identities.copy(
            defaultDialerPackages = setOf("test.home", "test.assistant", "test.settings", "test.installer")
        )
        val context = context(conflict)
        for (packageName in conflict.defaultDialerPackages) {
            assertFalse(packageName in context.phonePackages)
            assertEquals(LockAccessPolicy.Decision.BLOCK, decide(context, packageName))
        }
    }

    /** 默认电话与助手冲突后，系统电话与紧急入口仍可选。 */
    @Test
    fun should_keepFallbackDialers_when_defaultDialerIsForbidden() {
        val conflict = identities.copy(defaultDialerPackages = setOf("test.assistant"))
        val targets = listOf(target("test.assistant"), target("test.systemdialer"), target("test.emergency"))
        val allowed = LockAppRules.safeDialerTargets(context(conflict), targets)
        assertEquals(listOf("test.systemdialer", "test.emergency"), allowed.map { it.packageName })
    }

    /** 连紧急入口都不可用时必须报告空结果，由启动门槛拒绝开锁。 */
    @Test
    fun should_haveNoDialer_when_everyTargetIsForbidden() {
        val targets = listOf(target("test.home"), target("test.settings"))
        assertTrue(safeTargets(targets).isEmpty())
    }

    /** 隐藏或禁用Activity不应被canDial视为可打开的电话入口。 */
    @Test
    fun should_rejectUnavailableTargets_when_notExportedOrDisabled() {
        val targets = listOf(
            target("test.dialer").copy(isExported = false),
            target("test.systemdialer").copy(isEnabled = false),
            target("test.emergency")
        )
        assertEquals(listOf("test.emergency"), safeTargets(targets).map { it.packageName })
    }

    /** 不完整组件名不进入显式启动列表，重复候选只尝试一次。 */
    @Test
    fun should_removeInvalidAndDuplicateTargets_when_buildingDialerCandidates() {
        val target = target("test.dialer")
        val targets = listOf(target, target, target.copy(className = ""), target.copy(packageName = ""))
        assertEquals(listOf(target), safeTargets(targets))
    }

    /** OEM自定义设置包名不能借助白名单进入设置。 */
    @Test
    fun should_blockSettingsAndRolePackages_when_userWhitelistsThem() {
        val forbidden = setOf("test.home", "test.installer", "test.assistant", "test.settings")
        val context = context(whitelist = forbidden + "test.study")
        assertEquals(setOf("test.study"), context.whitelist)
        for (packageName in forbidden) {
            assertEquals(LockAccessPolicy.Decision.BLOCK, decide(context, packageName))
        }
    }

    /** 固定厂商永禁前缀和系统身份解析结果共用同一策略。 */
    @Test
    fun should_blockKnownForbiddenPrefixes_when_rolesAreMissing() {
        val forbidden = setOf("com.android.settings", "com.vivo.assistant", "com.oplus.launcher")
        val context = context(LockAppRules.Identities(), forbidden)
        assertTrue(context.whitelist.isEmpty())
        assertTrue(forbidden.all { LockAppRules.isForbidden(context, it) })
    }

    /** 旧版本存进白名单的Nivo自身被剔除，强制期间Nivo的主窗口仍被拉回锁页。 */
    @Test
    fun should_dropOwnPackage_when_olderWhitelistContainsIt() {
        val context = context(whitelist = setOf(ownPackage, "test.study"))
        assertFalse(ownPackage in context.whitelist)
        assertTrue("test.study" in context.whitelist)
        assertEquals(LockAccessPolicy.Decision.BLOCK, LockAccessPolicy.decide(context,
            LockAccessPolicy.Foreground(ownPackage, "com.openminis.app.MainActivity"), true, 1L))
        assertEquals(LockAccessPolicy.Decision.ALLOW, LockAccessPolicy.decide(context,
            LockAccessPolicy.Foreground(ownPackage, context.lockActivityClass), true, 1L))
    }

    /** 即使宿主误入电话角色，本应用也不获得电话豁免。 */
    @Test
    fun should_excludeOwnPackageFromPhoneExemption_when_roleMetadataContainsIt() {
        val context = context(identities.copy(defaultDialerPackages = setOf(ownPackage)))
        assertFalse(ownPackage in context.phonePackages)
        assertTrue(LockAppRules.safeDialerTargets(context, listOf(target(ownPackage))).isEmpty())
    }

    /** 当前输入法只携带窗口身份，不自动放行输入法的普通Activity。 */
    @Test
    fun should_keepImeWindowBoundary_when_currentImeIsResolved() {
        val context = context()
        assertEquals("test.ime", context.currentImePackage)
        assertEquals(LockAccessPolicy.Decision.BLOCK, decide(context, "test.ime"))
        assertEquals(
            LockAccessPolicy.Decision.ALLOW,
            LockAccessPolicy.decide(
                context,
                LockAccessPolicy.Foreground("test.ime", windowKind = LockAccessPolicy.WindowKind.INPUT_METHOD),
                true,
                1L
            )
        )
    }

    /** 无桌面入口的后台应用及本应用均保留在白名单选择目录。 */
    @Test
    fun should_keepBackgroundAndOwnApps_when_buildingCatalog() {
        val catalog = LockAppRules.classifyApps(
            context(), listOf(app("test.background", launchable = false), app(ownPackage))
        )
        assertEquals(setOf("test.background", ownPackage), catalog.map { it.packageName }.toSet())
        assertFalse(catalog.first { it.packageName == "test.background" }.isLaunchable)
        assertFalse(catalog.first { it.packageName == ownPackage }.isForbidden)
    }

    /** 系统应用和输入法不因系统标记而整体豁免，电话身份才会始终允许。 */
    @Test
    fun should_markOnlyTrustedPhoneAppsAlwaysAllowed_when_classifyingCatalog() {
        val catalog = LockAppRules.classifyApps(
            context(), listOf(app("test.dialer"), app("test.ime"), app("test.system", isSystem = true))
        )
        assertEquals(listOf("test.dialer"), catalog.filter { it.isAlwaysAllowed }.map { it.packageName })
        assertTrue(catalog.first { it.packageName == "test.system" }.isSystem)
    }

    /** 禁用角色在目录中不可选，也不能同时显示为始终允许。 */
    @Test
    fun should_markConflictingRoleForbidden_when_classifyingCatalog() {
        val context = context(identities.copy(systemCallPackages = setOf("test.assistant")))
        val entry = LockAppRules.classifyApps(context, listOf(app("test.assistant"))).single()
        assertTrue(entry.isForbidden)
        assertFalse(entry.isAlwaysAllowed)
    }

    /** 目录先显示可启动应用，随后按文字标签排序并去除重复包名。 */
    @Test
    fun should_sortAndDeduplicateCatalog_when_labelsDiffer() {
        val catalog = LockAppRules.classifyApps(
            context(),
            listOf(
                app("test.z", label = "Zulu"), app("test.hidden", label = "A", launchable = false),
                app("test.number", label = "123"), app("test.a", label = "alpha"), app("test.a")
            )
        )
        assertEquals(listOf("test.a", "test.z", "test.number", "test.hidden"), catalog.map { it.packageName })
    }

    private fun context(
        roles: LockAppRules.Identities = identities,
        whitelist: Set<String> = emptySet()
    ) = LockAppRules.accessContext(ownPackage, roles, whitelist, true)

    private fun target(packageName: String) =
        LockAppRules.DialerTarget(packageName, "$packageName.DialActivity")

    private fun safeTargets(targets: List<LockAppRules.DialerTarget>) =
        LockAppRules.safeDialerTargets(context(), targets)

    private fun app(
        packageName: String,
        label: String = packageName,
        launchable: Boolean = true,
        isSystem: Boolean = false
    ) = InstalledApp(packageName, label, isSystem, launchable, false, false)

    private fun decide(context: LockAccessPolicy.Context, packageName: String) =
        LockAccessPolicy.decide(context, LockAccessPolicy.Foreground(packageName), true, 1L)


}
