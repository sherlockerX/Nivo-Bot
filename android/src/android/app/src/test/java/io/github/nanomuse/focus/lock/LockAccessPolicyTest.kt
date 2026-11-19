package io.github.nanomuse.focus.lock

import io.github.nanomuse.focus.lock.LockAccessPolicy.Decision
import io.github.nanomuse.focus.lock.LockAccessPolicy.WindowKind
import org.junit.Assert.assertEquals
import org.junit.Test

/** 验证应用、Activity和窗口豁免，全部输入来自宿主提供的元数据。 */
class LockAccessPolicyTest {
    private val context = LockAccessPolicy.Context(
        ownPackage = "io.github.nanomuse.app",
        lockActivityClass = "io.github.nanomuse.ui.focus.FocusImmersiveActivity",
        phonePackages = setOf("com.android.phone", "com.android.server.telecom", "test.dialer", "test.incall", "test.emergency"),
        currentImePackage = "test.keyboard",
        launcherPackages = setOf("test.launcher"),
        installerPackages = setOf("test.installer"),
        assistantPackages = setOf("test.assistant"),
        whitelist = setOf("test.study"),
        usesWhitelist = true
    )
    private val mainActivity = "com.openminis.app.MainActivity"

    /** 未锁定时不得应用系统禁包规则。 */
    @Test
    fun should_allowEveryPackage_when_noLockIsActive() {
        for (packageName in listOf("com.android.settings", "test.launcher", "test.video", context.ownPackage)) {
            assertEquals(Decision.ALLOW, decide(packageName, isLocked = false))
        }
    }

    /** 未锁定时，陈旧的剩余时长不会产生到期操作。 */
    @Test
    fun should_allowWithoutExpiry_when_noLockHasRemainingDuration() {
        assertEquals(Decision.ALLOW, decide("com.android.settings", isLocked = false, remainingMs = -1L))
    }

    /** 禁用应用也必须先到期，再做访问判定。 */
    @Test
    fun should_expireBeforeBlocking_when_remainingDurationIsZero() {
        assertEquals(Decision.EXPIRED, decide("com.android.settings", remainingMs = 0L))
    }

    /** 非法负值按已到期处理，不能继续锁住用户或发生绝对值溢出。 */
    @Test
    fun should_expireWithoutBlocking_when_remainingDurationIsNegative() {
        for (remainingMs in listOf(-1L, Long.MIN_VALUE)) {
            assertEquals(Decision.EXPIRED, decide("test.video", remainingMs = remainingMs))
        }
    }

    /** 电话豁免也必须先报告会话到期。 */
    @Test
    fun should_expireBeforeAllowingPhone_when_remainingDurationIsZero() {
        assertEquals(Decision.EXPIRED, decide("test.emergency", remainingMs = 0L))
    }

    /** 最大合法正值无需算术变换，仍代表活动会话。 */
    @Test
    fun should_blockForbiddenApp_when_positiveRemainingDurationIsLongMaximum() {
        assertEquals(Decision.BLOCK, decide("test.video", remainingMs = Long.MAX_VALUE))
    }

    /** 缺失包名可能来自电话窗口，不凭空推断禁用应用。 */
    @Test
    fun should_allowUnknownPackage_when_packageMetadataIsMissing() {
        for (packageName in listOf(null, "", "  ")) {
            assertEquals(Decision.ALLOW, decide(packageName))
        }
    }

    /** 缺失包名也不隐藏明确的到期状态。 */
    @Test
    fun should_expireUnknownPackage_when_remainingDurationIsZero() {
        assertEquals(Decision.EXPIRED, decide(null, remainingMs = 0L))
    }

    /** 应用ID与代码命名空间不同也能识别唯一锁页。 */
    @Test
    fun should_allowLockActivity_when_applicationIdDiffersFromNamespace() {
        assertEquals(Decision.ALLOW, decide(context.ownPackage, context.lockActivityClass))
        assertEquals(Decision.BLOCK, decide(context.ownPackage, mainActivity))
    }

    /** 锁页类名不能让其他应用获得本应用豁免。 */
    @Test
    fun should_blockForeignPackage_when_lockActivityClassIsCopied() {
        assertEquals(Decision.BLOCK, decide("test.video", context.lockActivityClass))
    }

    /** 输入法设置页不属于键盘窗口豁免。 */
    @Test
    fun should_rejectKeyboardActivity_when_onlyKeyboardWindowIsAllowed() {
        assertEquals(Decision.BLOCK, decide("test.keyboard", "test.keyboard.Settings"))
    }

    /** 重复前台事件不改变纯决策结果。 */
    @Test
    fun should_keepBlocking_when_forbiddenActivityRemainsForeground() {
        repeat(2) { assertEquals(Decision.BLOCK, decide("test.video", "test.video.Main")) }
    }

    /** 白名单Activity与系统UI窗口都能正常使用。 */
    @Test
    fun should_allowWhitelistAndSystemWindows_when_active() {
        assertEquals(Decision.ALLOW, decide("test.study", "test.study.Main"))
        assertEquals(Decision.ALLOW, decide("com.android.systemui", "Dialog", isActivity = false))
        assertEquals(Decision.ALLOW, decide("android", "PermissionDialog", isActivity = false))
    }

    /** 系统窗口的豁免不能扩大为同包任意Activity。 */
    @Test
    fun should_blockSystemActivity_when_onlySystemWindowsAreExempt() {
        assertEquals(Decision.BLOCK, decide("com.android.systemui", "SettingsActivity"))
        assertEquals(Decision.BLOCK, decide("android", "ResolverActivity"))
    }

    /** 用户事先选择的普通应用在启用白名单时放行。 */
    @Test
    fun should_allowSelectedApp_when_sessionActive() {
        val accessContext = context.copy(whitelist = setOf("com.tencent.mm"))
        assertEquals(Decision.ALLOW, decide("com.tencent.mm", accessContext = accessContext))
    }

    /** 未选中的普通应用被拦截。 */
    @Test
    fun should_blockUnselectedApp_when_sessionActive() {
        assertEquals(Decision.BLOCK, decide("com.ss.android.ugc.aweme"))
    }

    /** 固定禁包规则覆盖常见OEM桌面。 */
    @Test
    fun should_blockVivoLauncher_when_sessionActive() {
        assertEquals(Decision.BLOCK, decide("com.bbk.launcher2"))
    }

    /** 宿主识别的默认拨号器无需用户加入白名单。 */
    @Test
    fun should_keepDialerAvailable_when_sessionActive() {
        val accessContext = context.copy(phonePackages = setOf("com.google.android.dialer"))
        assertEquals(Decision.ALLOW, decide("com.google.android.dialer", accessContext = accessContext))
    }

    /** 未启用白名单的会话同样禁止系统设置。 */
    @Test
    fun should_blockSettings_when_whitelistIsDisabled() {
        val accessContext = context.copy(usesWhitelist = false, whitelist = setOf("com.android.settings"))
        assertEquals(Decision.BLOCK, decide("com.android.settings", accessContext = accessContext))
    }

    /** 助手不会因为加入白名单而成为出口。 */
    @Test
    fun should_blockAssistant_when_whitelistContainsIt() {
        val accessContext = context.copy(whitelist = setOf("com.google.android.googlequicksearchbox"))
        assertEquals(Decision.BLOCK, decide("com.google.android.googlequicksearchbox", accessContext = accessContext))
    }

    /** 安装器不会因为加入白名单而成为出口。 */
    @Test
    fun should_blockInstaller_when_whitelistContainsIt() {
        val accessContext = context.copy(whitelist = setOf("com.android.packageinstaller"))
        assertEquals(Decision.BLOCK, decide("com.android.packageinstaller", accessContext = accessContext))
    }

    /** 所有固定设置、权限管理、桌面和助手前缀都覆盖恶意白名单。 */
    @Test
    fun should_blockFixedForbiddenPackages_when_whitelistContainsEveryPackage() {
        val forbiddenPackages = setOf(
            "com.android.settings", "com.android.settings.intelligence",
            "com.android.packageinstaller", "com.google.android.packageinstaller",
            "com.android.permissioncontroller", "com.google.android.permissioncontroller",
            "com.android.launcher3", "com.google.android.apps.nexuslauncher",
            "com.oplus.launcher", "com.oppo.launcher", "com.coloros.launcher",
            "com.bbk.launcher2", "com.vivo.launcher", "com.vivo.agent", "com.vivo.assistant",
            "com.coloros.assistant", "com.coloros.speechassist", "com.heytap.speechassist",
            "com.oplus.aiunit", "com.oplus.ocs", "com.coloros.ocs", "com.oplus.smartengine",
            "com.oplus.pantanal", "com.google.android.googlequicksearchbox",
            "com.google.android.apps.googleassistant"
        )
        val accessContext = context.copy(whitelist = forbiddenPackages)
        for (packageName in forbiddenPackages) {
            assertEquals(packageName, Decision.BLOCK, decide(packageName, accessContext = accessContext))
        }
    }

    /** 宿主解析出的第三方桌面、安装器和助手也覆盖白名单。 */
    @Test
    fun should_blockResolvedForbiddenPackages_when_whitelistContainsEveryPackage() {
        val forbiddenPackages = context.launcherPackages + context.installerPackages + context.assistantPackages
        val accessContext = context.copy(whitelist = forbiddenPackages)
        for (packageName in forbiddenPackages) {
            assertEquals(packageName, Decision.BLOCK, decide(packageName, accessContext = accessContext))
        }
    }

    /** 关闭白名单后，保留的配置不能继续开放普通应用。 */
    @Test
    fun should_blockSelectedApp_when_whitelistIsDisabled() {
        assertEquals(Decision.BLOCK, decide("test.study", accessContext = context.copy(usesWhitelist = false)))
    }

    /** 电话、拨号、来电和紧急通话均独立于白名单开关。 */
    @Test
    fun should_allowAllPhonePackages_when_whitelistIsDisabled() {
        val accessContext = context.copy(usesWhitelist = false)
        for (packageName in accessContext.phonePackages) {
            assertEquals(packageName, Decision.ALLOW, decide(packageName, accessContext = accessContext))
        }
    }

    /** 当前输入法窗口允许输入，不开放输入法包下的全部页面。 */
    @Test
    fun should_allowCurrentIme_when_inputMethodWindowIsShown() {
        assertEquals(Decision.ALLOW, decide("test.keyboard", windowKind = WindowKind.INPUT_METHOD))
    }

    /** 非Activity标记本身不能证明这是输入法窗口。 */
    @Test
    fun should_blockCurrentIme_when_nonActivityEventIsNotInputMethodWindow() {
        assertEquals(Decision.BLOCK, decide("test.keyboard", isActivity = false))
        assertEquals(Decision.BLOCK, decide("test.keyboard", windowKind = WindowKind.OTHER, isActivity = false))
        assertEquals(Decision.ALLOW, decide("test.keyboard", windowKind = WindowKind.INPUT_METHOD, isActivity = false))
    }

    /** 已停用输入法不继承当前输入法豁免。 */
    @Test
    fun should_blockOtherIme_when_inputMethodWindowIsNotCurrent() {
        assertEquals(Decision.BLOCK, decide("test.other.keyboard", windowKind = WindowKind.INPUT_METHOD))
    }

    /** 未知当前输入法时，不能仅凭窗口类型开放任意包。 */
    @Test
    fun should_blockUnresolvedIme_when_currentImePackageIsMissing() {
        val accessContext = context.copy(currentImePackage = null)
        assertEquals(Decision.BLOCK, decide("test.keyboard", windowKind = WindowKind.INPUT_METHOD, accessContext = accessContext))
    }

    /** 普通输入法设置Activity可以通过事先选择的白名单访问。 */
    @Test
    fun should_allowKeyboardSettings_when_explicitWhitelistContainsIt() {
        val accessContext = context.copy(whitelist = setOf("test.keyboard"))
        assertEquals(Decision.ALLOW, decide("test.keyboard", "test.keyboard.Settings", accessContext = accessContext))
    }

    /** 输入法设置Activity仍受系统禁包规则约束。 */
    @Test
    fun should_blockKeyboardSettings_when_packageIsForbiddenDespiteWhitelist() {
        val accessContext = context.copy(
            currentImePackage = "com.android.settings.inputmethod",
            whitelist = setOf("com.android.settings.inputmethod")
        )
        assertEquals(Decision.BLOCK, decide("com.android.settings.inputmethod", "Settings", accessContext = accessContext))
    }

    /** Nivo默认只开放沉浸式专注页，即使用户把本包加入白名单。 */
    @Test
    fun should_blockOwnMainActivity_when_ownPackageIsWhitelisted() {
        val accessContext = context.copy(whitelist = setOf(context.ownPackage))
        assertEquals(Decision.BLOCK, decide(context.ownPackage, mainActivity, accessContext = accessContext))
    }

    /** 本包即使被错误混入宿主豁免集合，也不能获得全部页面访问权。 */
    @Test
    fun should_blockOwnMainActivity_when_ownPackageAppearsInPackageExemptions() {
        val accessContext = context.copy(
            phonePackages = context.phonePackages + context.ownPackage,
            currentImePackage = context.ownPackage
        )
        assertEquals(Decision.BLOCK, decide(context.ownPackage, mainActivity, accessContext = accessContext))
        assertEquals(Decision.BLOCK, decide(context.ownPackage, mainActivity, windowKind = WindowKind.INPUT_METHOD, accessContext = accessContext))
    }

    /** 固定禁包或桌面不能靠冲突的电话分类开放Activity。 */
    @Test
    fun should_blockForbiddenActivity_when_phoneClassificationConflicts() {
        val forbiddenPackages = setOf("com.android.settings", "test.launcher", "test.installer", "test.assistant")
        val accessContext = context.copy(phonePackages = context.phonePackages + forbiddenPackages,
            whitelist = forbiddenPackages)
        for (packageName in forbiddenPackages) {
            assertEquals(packageName, Decision.BLOCK, decide(packageName, accessContext = accessContext))
        }
        assertEquals(Decision.ALLOW, decide("test.emergency", accessContext = accessContext))
    }

    /** 强制期间Nivo只开放锁页：聊天主窗口、其他页面和缺失类名一律拉回。 */
    @Test
    fun should_blockEveryOwnActivityExceptLock_when_locked() {
        val accessContext = context.copy(whitelist = setOf(context.ownPackage))
        for (className in listOf(mainActivity, "io.github.nanomuse.SettingsActivity", null)) {
            assertEquals(className.toString(), Decision.BLOCK, decide(context.ownPackage, className, accessContext = accessContext))
        }
        assertEquals(Decision.ALLOW, decide(context.ownPackage, context.lockActivityClass, accessContext = accessContext))
    }

    /** 外部应用借用Nivo主入口类名也不能获得豁免。 */
    @Test
    fun should_blockExternalApp_when_ownClassNameIsCopied() {
        assertEquals(Decision.BLOCK, decide("test.video", mainActivity))
    }

    private fun decide(
        packageName: String?,
        className: String? = "test.MainActivity",
        isLocked: Boolean = true,
        remainingMs: Long = 60_000L,
        windowKind: WindowKind = WindowKind.APPLICATION,
        isActivity: Boolean = true,
        accessContext: LockAccessPolicy.Context = context
    ): Decision = LockAccessPolicy.decide(
        context = accessContext,
        foreground = LockAccessPolicy.Foreground(
            packageName = packageName,
            className = className,
            windowKind = windowKind,
            isActivity = isActivity
        ),
        isLocked = isLocked,
        remainingMs = remainingMs
    )
}
