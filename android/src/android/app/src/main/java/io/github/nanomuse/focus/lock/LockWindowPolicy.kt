package io.github.nanomuse.focus.lock

/** 窗口在同一显示器内的屏幕矩形，右边界和下边界不计入区域。 */
data class LockWindowBounds(val left: Int, val top: Int, val right: Int, val bottom: Int)

/** 只包含窗口身份、层级和几何信息，不包含界面文字或节点。 */
data class LockWindowSnapshot(
    val id: Int,
    val packageName: String?,
    val type: Int,
    val layer: Int,
    val focused: Boolean,
    val bounds: LockWindowBounds,
)

/** 待遮挡区域保留原窗口身份；同一窗口可以拆为多个互不重叠的矩形。 */
data class LockBlockedRegion(
    val id: Int,
    val packageName: String?,
    val type: Int,
    val bounds: LockWindowBounds,
)

/**
 * 强制期间哪些窗口区域要盖上触摸遮挡，规则移植自FocusLock的WindowPolicy（MIT）。
 * 小窗、分屏、桌面和设置都是普通窗口，单靠拉回锁页无法覆盖，必须按窗口几何遮挡。
 * 放行与永禁沿用[LockAccessPolicy]，两条拦截路径对同一个包给出同样的判断。
 */
object LockWindowPolicy {
    // 与AccessibilityWindowInfo的类型常量一致，纯逻辑不依赖Android类。
    const val TYPE_APPLICATION = 1
    const val TYPE_INPUT_METHOD = 2
    const val TYPE_SYSTEM = 3
    const val TYPE_ACCESSIBILITY_OVERLAY = 4
    const val TYPE_SPLIT_SCREEN_DIVIDER = 5
    private const val MAX_BLOCKED_REGIONS = 64
    private val SYSTEM_PACKAGES = setOf("android", "com.android.systemui")

    /**
     * 计算同一显示器内需要拦截的区域，调用方负责确认仍处于强制会话。
     * 只扣除更高层的可信窗口；本应用的遮挡不参与扣除，防止自身引起显隐循环。
     * 超过64片时优先保留高层禁用窗口；宁可舍弃部分遮挡，也不盖住电话或输入法。
     */
    fun blockedRegions(
        windows: List<LockWindowSnapshot>,
        access: LockAccessPolicy.Context,
        keyboardPackage: String? = access.currentImePackage,
    ): List<LockBlockedRegion> {
        val classified = windows.filter { isValid(it.bounds) }
            .map { it.copy(packageName = it.packageName?.takeIf(String::isNotBlank)) }
            .sortedWith(compareByDescending<LockWindowSnapshot> { it.layer }.thenBy { it.id })
            .map { it to classify(it, access, keyboardPackage) }
        val trusted = classified.filter { it.second == Disposition.TRUST }.map { it.first }
        val blocked = mutableListOf<LockBlockedRegion>()
        for ((window, disposition) in classified) {
            if (disposition != Disposition.BLOCK) continue
            val capacity = MAX_BLOCKED_REGIONS - blocked.size
            if (capacity == 0) break
            val protectedBounds = trusted.filter { it.layer > window.layer }.map { it.bounds }
            blocked += subtractAll(window.bounds, protectedBounds, capacity)
                .map { LockBlockedRegion(window.id, window.packageName, window.type, it) }
        }
        return blocked
    }

    private fun classify(
        window: LockWindowSnapshot,
        access: LockAccessPolicy.Context,
        keyboardPackage: String?,
    ): Disposition {
        val packageName = window.packageName ?: return classifyUnknown(window)
        if (window.type == TYPE_ACCESSIBILITY_OVERLAY && packageName == access.ownPackage) return Disposition.IGNORE
        if (packageName != access.ownPackage && LockAccessPolicy.isNeverAllowedPackage(access, packageName)) {
            return Disposition.BLOCK
        }
        val isTrusted = when (window.type) {
            TYPE_APPLICATION -> isApplicationTrusted(packageName, access)
            TYPE_INPUT_METHOD -> packageName == keyboardPackage
            TYPE_SYSTEM -> packageName in SYSTEM_PACKAGES || packageName == access.ownPackage ||
                packageName in access.phonePackages
            TYPE_SPLIT_SCREEN_DIVIDER -> packageName in SYSTEM_PACKAGES
            else -> false
        }
        return if (isTrusted) Disposition.TRUST else Disposition.BLOCK
    }

    /** 包名暂不可读时：系统层可信；聚焦的普通窗口先遮住，未聚焦的不作判断。 */
    private fun classifyUnknown(window: LockWindowSnapshot): Disposition = when (window.type) {
        TYPE_SYSTEM, TYPE_SPLIT_SCREEN_DIVIDER -> Disposition.TRUST
        TYPE_APPLICATION -> if (window.focused) Disposition.BLOCK else Disposition.IGNORE
        else -> Disposition.IGNORE
    }

    /** 本应用窗口交给应用内守卫处理；系统包里的Activity可能是设置页，不继承系统窗口豁免。 */
    private fun isApplicationTrusted(packageName: String, access: LockAccessPolicy.Context): Boolean {
        if (packageName == access.ownPackage) return true
        if (packageName in SYSTEM_PACKAGES) return false
        return packageName in access.phonePackages || access.usesWhitelist && packageName in access.whitelist
    }

    private fun subtractAll(
        bounds: LockWindowBounds,
        protectedBounds: List<LockWindowBounds>,
        capacity: Int,
    ): List<LockWindowBounds> {
        var pieces = listOf(bounds)
        for (protected in protectedBounds) {
            // 截断之后仍继续扣除剩余可信窗口，不能因片数已满而遮住后来的电话区域。
            pieces = pieces.flatMap { subtract(it, protected) }.take(capacity)
            if (pieces.isEmpty()) break
        }
        return pieces
    }

    private fun subtract(bounds: LockWindowBounds, protected: LockWindowBounds): List<LockWindowBounds> {
        val intersection = LockWindowBounds(
            maxOf(bounds.left, protected.left), maxOf(bounds.top, protected.top),
            minOf(bounds.right, protected.right), minOf(bounds.bottom, protected.bottom),
        )
        if (!isValid(intersection)) return listOf(bounds)
        // 上下片使用全宽，左右片仅使用交集高度，保证同一窗口的输出矩形互不重叠。
        return listOf(
            LockWindowBounds(bounds.left, bounds.top, bounds.right, intersection.top),
            LockWindowBounds(bounds.left, intersection.bottom, bounds.right, bounds.bottom),
            LockWindowBounds(bounds.left, intersection.top, intersection.left, intersection.bottom),
            LockWindowBounds(intersection.right, intersection.top, bounds.right, intersection.bottom),
        ).filter(::isValid)
    }

    private fun isValid(bounds: LockWindowBounds): Boolean = bounds.left < bounds.right && bounds.top < bounds.bottom

    /** IGNORE不直接拦截，也不能作为可信区域抵消其他禁用窗口。 */
    private enum class Disposition { BLOCK, TRUST, IGNORE }
}

/** 遮挡层以源窗口和稳定片序定位，不把会变化的矩形当作窗口身份。 */
data class LockOverlaySlot(val windowId: Int, val partIndex: Int)

/** 仅规范遮挡层布局，不扩大覆盖范围，也不改变可信窗口扣除结果。 */
object LockOverlayLayout {
    /** 裁剪屏幕外区域并固定片序；同一窗口的重复矩形只保留一次，不合成外包矩形。 */
    fun plan(regions: List<LockBlockedRegion>, screen: LockWindowBounds): Map<LockOverlaySlot, LockWindowBounds> {
        if (screen.left >= screen.right || screen.top >= screen.bottom) return emptyMap()
        val desired = linkedMapOf<LockOverlaySlot, LockWindowBounds>()
        for ((windowId, parts) in regions.groupBy { it.id }.toSortedMap()) {
            parts.mapNotNull { clip(it.bounds, screen) }.distinct()
                .sortedWith(compareBy<LockWindowBounds> { it.top }.thenBy { it.left }.thenBy { it.bottom }.thenBy { it.right })
                .forEachIndexed { index, region -> desired[LockOverlaySlot(windowId, index)] = region }
        }
        return desired
    }

    private fun clip(bounds: LockWindowBounds, screen: LockWindowBounds): LockWindowBounds? {
        val clipped = LockWindowBounds(
            maxOf(bounds.left, screen.left), maxOf(bounds.top, screen.top),
            minOf(bounds.right, screen.right), minOf(bounds.bottom, screen.bottom),
        )
        return clipped.takeIf { it.left < it.right && it.top < it.bottom }
    }
}

/**
 * 系统面板的纯元数据证据，不包含页面文字、控件描述或输入内容。
 * 排除标志用于电源、音量、生物识别、权限、选择器等不能当作面板收起的窗口。
 */
data class LockPanelEvidence(
    val packageName: String?,
    val type: Int,
    val focused: Boolean,
    val isKeyguardLocked: Boolean,
    val hasKnownPanelId: Boolean,
    val hasControlCenterId: Boolean,
    val hasBrightnessId: Boolean,
    val hasTileId: Boolean,
    val hasExcludedDialog: Boolean,
    val windowBounds: LockWindowBounds,
    val screenWidth: Int,
    val screenHeight: Int,
)

/** 判断聚焦的SystemUI窗口是否是可以收起的通知栏或控制中心，移植自FocusLock的PanelPolicy（MIT）。 */
object LockPanelPolicy {
    private const val SYSTEM_UI_PACKAGE = "com.android.systemui"
    private const val MIN_WIDTH_PERCENT = 70L
    private const val MIN_HEIGHT_PERCENT = 35L

    /** 已知面板ID或控制中心ID可独立提供证据，亮度ID必须与快捷开关ID同时出现。 */
    fun shouldClose(evidence: LockPanelEvidence): Boolean {
        if (evidence.packageName != SYSTEM_UI_PACKAGE || !evidence.focused || evidence.isKeyguardLocked ||
            evidence.hasExcludedDialog) return false
        if (evidence.type != LockWindowPolicy.TYPE_APPLICATION && evidence.type != LockWindowPolicy.TYPE_SYSTEM) return false
        if (!hasSufficientVisibleBounds(evidence)) return false
        return evidence.hasKnownPanelId || evidence.hasControlCenterId || (evidence.hasBrightnessId && evidence.hasTileId)
    }

    private fun hasSufficientVisibleBounds(evidence: LockPanelEvidence): Boolean {
        if (evidence.screenWidth <= 0 || evidence.screenHeight <= 0) return false
        val bounds = evidence.windowBounds
        // 先裁剪屏幕外区域，再用Long计算比例，避免越界窗口和整数溢出扩大证据。
        val visibleWidth = bounds.right.coerceAtMost(evidence.screenWidth).toLong() - bounds.left.coerceAtLeast(0).toLong()
        val visibleHeight = bounds.bottom.coerceAtMost(evidence.screenHeight).toLong() - bounds.top.coerceAtLeast(0).toLong()
        if (visibleWidth <= 0L || visibleHeight <= 0L) return false
        return visibleWidth * 100 >= evidence.screenWidth.toLong() * MIN_WIDTH_PERCENT &&
            visibleHeight * 100 >= evidence.screenHeight.toLong() * MIN_HEIGHT_PERCENT
    }
}
