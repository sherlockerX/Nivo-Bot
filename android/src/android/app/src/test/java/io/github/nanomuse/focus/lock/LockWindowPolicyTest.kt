package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 移植FocusLock的窗口遮挡用例：小窗、桌面和设置被盖住，电话、键盘和白名单区域保持可触摸。 */
class LockWindowPolicyTest {
    private val access = LockAccessPolicy.Context(
        ownPackage = OWN,
        lockActivityClass = "io.github.nanomuse.ui.focus.FocusImmersiveActivity",
        phonePackages = setOf("dialer"),
        currentImePackage = "keyboard",
        launcherPackages = setOf("launcher"),
        installerPackages = setOf("installer", "com.android.settings"),
        assistantPackages = setOf("assistant"),
        whitelist = setOf("study"),
        usesWhitelist = true,
    )

    /** 锁页上方的禁用小窗即使没有焦点也要被遮挡。 */
    @Test fun should_blockFloatingApp_when_itFloatsAboveLockScreen() {
        val floating = LockWindowBounds(20, 10, 80, 70)
        val blocked = decide(listOf(window(1, OWN, layer = 1), window(2, "video", layer = 2, bounds = floating)))
        assertEquals(listOf(LockBlockedRegion(2, "video", 1, floating)), blocked)
    }

    /** 回到桌面时桌面整屏被遮挡，长按图标卸载在锁页回来之前就点不到。 */
    @Test fun should_blockLauncher_when_userLeavesForHomeScreen() {
        val blocked = decide(listOf(window(1, "launcher", focused = true)))
        assertEquals(listOf(LockBlockedRegion(1, "launcher", 1, FULL)), blocked)
    }

    /** 桌面、设置、安装器和助手即使被选进白名单也照样遮挡。 */
    @Test fun should_blockNeverAllowedPackages_when_whitelisted() {
        val forbidden = listOf("launcher", "com.android.settings", "installer", "assistant")
        val context = access.copy(whitelist = forbidden.toSet(), phonePackages = forbidden.toSet())
        val blocked = LockWindowPolicy.blockedRegions(forbidden.mapIndexed { i, p -> window(i, p) }, context)
        assertEquals(forbidden.indices.toSet(), blocked.map { it.id }.toSet())
    }

    /** 白名单应用、电话和本应用窗口不遮挡。 */
    @Test fun should_leaveTrustedWindowsTouchable_when_allowed() {
        assertTrue(decide(listOf(window(1, "study"), window(2, "dialer"), window(3, OWN))).isEmpty())
    }

    /** 计划关闭白名单时，原来选中的应用也被遮挡，电话仍可用。 */
    @Test fun should_blockWhitelistedApp_when_whitelistModeIsOff() {
        val blocked = LockWindowPolicy.blockedRegions(listOf(window(1, "study"), window(2, "dialer")),
            access.copy(usesWhitelist = false))
        assertEquals(listOf(1), blocked.map { it.id })
    }

    /** 外部悬浮层不能借系统窗口类型绕过白名单；SystemUI和android的系统窗口保留。 */
    @Test fun should_blockExternalSystemOverlay_when_packageIsNotSystem() {
        val blocked = decide(listOf(
            window(1, "sidebar", type = 3), window(2, "com.android.systemui", type = 3), window(3, "android", type = 3),
        ))
        assertEquals(listOf(1), blocked.map { it.id })
    }

    /** 系统包里的Activity可能是设置或权限页，不继承系统窗口豁免。 */
    @Test fun should_blockSystemPackageActivity_when_typeIsApplication() {
        val blocked = decide(listOf(window(1, "com.android.systemui", type = 1), window(2, "android", type = 1)))
        assertEquals(setOf(1, 2), blocked.map { it.id }.toSet())
    }

    /** 当前输入法的键盘窗口可用，它的设置Activity和其他输入法仍被遮挡。 */
    @Test fun should_trustOnlyCurrentKeyboardWindow_when_inputMethodsAppear() {
        val blocked = decide(listOf(window(1, "keyboard", type = 2), window(2, "keyboard", type = 1), window(3, "other", type = 2)))
        assertEquals(setOf(2, 3), blocked.map { it.id }.toSet())
    }

    /** 宿主读到更新后的输入法时，以新身份为准。 */
    @Test fun should_useRefreshedKeyboard_when_hostPassesIt() {
        val windows = listOf(window(1, "new.keyboard", type = 2))
        assertEquals(1, LockWindowPolicy.blockedRegions(windows, access).size)
        assertTrue(LockWindowPolicy.blockedRegions(windows, access, keyboardPackage = "new.keyboard").isEmpty())
    }

    /** 包名还读不出来的聚焦应用先遮住；未聚焦的未知窗口不判断，也不能给下层挖洞。 */
    @Test fun should_handleUnknownWindows_when_identityIsMissing() {
        assertEquals(listOf(1), decide(listOf(window(1, null, focused = true))).map { it.id })
        val blocked = decide(listOf(window(1, "video", layer = 1), window(2, null, layer = 2)))
        assertEquals(listOf(LockBlockedRegion(1, "video", 1, FULL)), blocked)
    }

    /** 读不到身份的系统窗口（电源菜单、来电）保持可触摸。 */
    @Test fun should_preserveUnknownSystemRegion_when_aboveBlockedApp() {
        val blocked = decide(listOf(window(1, "video", layer = 1), window(2, null, type = 3, layer = 2,
            bounds = LockWindowBounds(0, 0, 100, 30))))
        assertEquals(listOf(LockWindowBounds(0, 30, 100, 100)), blocked.map { it.bounds })
    }

    /** 来电窗口浮在禁用应用上时只挖掉电话区域，周围仍被遮挡。 */
    @Test fun should_cutOutPhoneRectangle_when_callOverlapsBlockedApp() {
        val phone = LockWindowBounds(25, 25, 75, 75)
        val blocked = decide(listOf(window(1, "video", layer = 1), window(2, "dialer", layer = 2, bounds = phone)))
        assertEquals(4, blocked.size)
        assertEquals(7_500L, blocked.sumOf { area(it.bounds) })
        assertTrue(blocked.all { it.id == 1 && !overlaps(it.bounds, phone) })
    }

    /** 键盘浮在禁用应用上方时，遮挡不侵入键盘区域。 */
    @Test fun should_preserveKeyboardRegion_when_aboveBlockedApp() {
        val blocked = decide(listOf(window(1, "video", layer = 1), window(2, "keyboard", type = 2, layer = 2,
            bounds = LockWindowBounds(0, 60, 100, 100))))
        assertEquals(listOf(LockWindowBounds(0, 0, 100, 60)), blocked.map { it.bounds })
    }

    /** 低层的电话不能从上层禁用窗口扣除区域。 */
    @Test fun should_keepFullBlock_when_trustedWindowIsBelow() {
        val blocked = decide(listOf(window(1, "video", layer = 3), window(2, "dialer", layer = 2)))
        assertEquals(listOf(LockBlockedRegion(1, "video", 1, FULL)), blocked)
    }

    /** 本应用自己的遮挡层不参与判断，避免显隐循环。 */
    @Test fun should_ignoreOwnOverlay_when_scanning() {
        assertTrue(decide(listOf(window(1, OWN, type = 4))).isEmpty())
        assertEquals(1, decide(listOf(window(1, "other", type = 4))).size)
    }

    /** 片数达到上限时保留高层窗口，并且不返回超过上限的矩形。 */
    @Test fun should_capRegions_when_manyBlockedWindowsAppear() {
        val windows = (0 until 80).map { window(it, "video$it", layer = it) }
        val blocked = decide(windows)
        assertEquals(64, blocked.size)
        assertTrue(blocked.all { it.id >= 16 })
    }

    /** 遮挡布局裁到屏幕内，同一窗口的重复矩形只保留一份，片序稳定。 */
    @Test fun should_clipAndOrderSlots_when_planningOverlays() {
        val screen = LockWindowBounds(0, 0, 100, 100)
        val plan = LockOverlayLayout.plan(listOf(
            LockBlockedRegion(2, "a", 1, LockWindowBounds(0, 50, 100, 150)),
            LockBlockedRegion(2, "a", 1, LockWindowBounds(0, 0, 100, 20)),
            LockBlockedRegion(2, "a", 1, LockWindowBounds(0, 0, 100, 20)),
            LockBlockedRegion(1, "b", 1, LockWindowBounds(-50, -50, -10, -10)),
        ), screen)
        assertEquals(mapOf(
            LockOverlaySlot(2, 0) to LockWindowBounds(0, 0, 100, 20),
            LockOverlaySlot(2, 1) to LockWindowBounds(0, 50, 100, 100),
        ), plan)
        assertTrue(LockOverlayLayout.plan(listOf(LockBlockedRegion(1, "a", 1, FULL)), LockWindowBounds(0, 0, 0, 0)).isEmpty())
    }

    /** 只收起聚焦、未锁屏、面积足够的SystemUI面板，电源和音量窗口除外。 */
    @Test fun should_closeOnlyRealPanels_when_evidenceIsChecked() {
        val panel = LockPanelEvidence("com.android.systemui", 3, focused = true, isKeyguardLocked = false,
            hasKnownPanelId = true, hasControlCenterId = false, hasBrightnessId = false, hasTileId = false,
            hasExcludedDialog = false, windowBounds = LockWindowBounds(0, 0, 1000, 1200), screenWidth = 1000, screenHeight = 2000)
        assertTrue(LockPanelPolicy.shouldClose(panel))
        assertFalse(LockPanelPolicy.shouldClose(panel.copy(isKeyguardLocked = true)))
        assertFalse(LockPanelPolicy.shouldClose(panel.copy(focused = false)))
        assertFalse(LockPanelPolicy.shouldClose(panel.copy(packageName = "other")))
        assertFalse(LockPanelPolicy.shouldClose(panel.copy(hasExcludedDialog = true)))
        assertFalse(LockPanelPolicy.shouldClose(panel.copy(windowBounds = LockWindowBounds(0, 0, 1000, 300))))
        assertFalse(LockPanelPolicy.shouldClose(panel.copy(hasKnownPanelId = false, hasBrightnessId = true)))
        assertTrue(LockPanelPolicy.shouldClose(panel.copy(hasKnownPanelId = false, hasBrightnessId = true, hasTileId = true)))
        assertTrue(LockPanelPolicy.shouldClose(panel.copy(hasKnownPanelId = false, hasControlCenterId = true, type = 1)))
        assertFalse(LockPanelPolicy.shouldClose(panel.copy(type = 2)))
    }

    private fun decide(windows: List<LockWindowSnapshot>) = LockWindowPolicy.blockedRegions(windows, access)

    private fun window(
        id: Int, packageName: String?, type: Int = 1, layer: Int = 1, focused: Boolean = false,
        bounds: LockWindowBounds = FULL,
    ) = LockWindowSnapshot(id, packageName, type, layer, focused, bounds)

    private fun area(bounds: LockWindowBounds) = (bounds.right - bounds.left).toLong() * (bounds.bottom - bounds.top)

    private fun overlaps(a: LockWindowBounds, b: LockWindowBounds) =
        maxOf(a.left, b.left) < minOf(a.right, b.right) && maxOf(a.top, b.top) < minOf(a.bottom, b.bottom)

    private companion object {
        const val OWN = "io.github.nanomuse.app"
        val FULL = LockWindowBounds(0, 0, 100, 100)
    }
}
