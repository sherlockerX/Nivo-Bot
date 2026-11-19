package io.github.nanomuse.focus.lock

import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Point
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityWindowInfo
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * 强制期间按窗口几何遮挡禁用区域，移植自FocusLock 1.4.2的WindowGuard（MIT）。
 *
 * 拉回锁页要经过系统的Activity启动；回到桌面后这段间隙足够长按图标卸载应用。遮挡层是
 * 无障碍窗口，在下一次扫描（约60毫秒）就盖住桌面、小窗、分屏或设置的触摸，不等锁页回来。
 * 遮挡层可见也让本应用拥有可见窗口，系统随后放行锁页的启动，不再受回桌面后的切换保护拖延。
 *
 * 只读取窗口的包名、类型、层级、焦点和几何，以及SystemUI面板的固定控件ID；不读取文字、
 * 控件描述或输入内容。
 */
internal class LockWindowGuard(private val service: AccessibilityService) {
    private val handler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { task -> Thread(task, "nivo-lock-window-scan").apply { isDaemon = true } }
    private val resolver = Executors.newFixedThreadPool(2) { task -> Thread(task, "nivo-lock-window-identity").apply { isDaemon = true } }
    private val resolvingCount = AtomicInteger(0)
    private val resolveAfter = ConcurrentHashMap<Int, Long>()
    private val packageCache = ConcurrentHashMap<Int, CachedPackage>()
    private val panelRevisions = ConcurrentHashMap<Int, Long>()
    private val shadeWindows = mutableMapOf<Int, Long>()
    private var visibleTypes: Map<Int, Int> = emptyMap()
    @Volatile private var panelEpoch = 0L
    @Volatile private var generation = 0
    @Volatile private var windowRevision = 0L
    private val keyguard = service.getSystemService(KeyguardManager::class.java)
    private val power = service.getSystemService(PowerManager::class.java)
    private val overlay = LockBlockedOverlay(service)
    private val panelCloser = LockPanelCloser(service, ::currentPanelBounds)
    private var isEnabled = false
    private var isScanning = false
    private var isQueued = false
    private var lastRecoveryAt = 0L
    private var lastShadeAt = 0L
    private var lastBlockedKey: Set<String> = emptySet()
    private val pulse = Runnable { isQueued = false; scan() }

    /** 由会话状态驱动，结束会话立即撤去遮挡，不等待下一次窗口事件。 */
    fun setEnabled(enabled: Boolean) {
        if (isEnabled == enabled) return
        isEnabled = enabled
        generation++
        handler.removeCallbacks(pulse)
        isQueued = false
        shadeWindows.clear()
        lastBlockedKey = emptySet()
        panelCloser.cancel()
        if (enabled) requestScan() else overlay.clear()
    }

    /** 包名事件提供快速窗口身份；电话出现时先撤去旧遮挡，避免异步快照盖住来电。 */
    fun onWindowEvent(packageName: String?, windowId: Int) {
        windowRevision++
        invalidatePanel(windowId)
        if (!packageName.isNullOrBlank() && windowId >= 0) {
            packageCache[windowId] = CachedPackage(packageName, -1, SystemClock.elapsedRealtime())
        }
        if (packageName != null && packageName in phonePackages()) {
            overlay.clear()
            shadeWindows.clear()
            panelCloser.cancel()
        }
        if (!isEnabled) return
        handler.removeCallbacks(pulse)
        // 已排队的事件保留原期限，持续拖动小窗不会把扫描无限往后推。
        if (!isQueued) requestScan() else handler.post(pulse)
    }

    /** 控制中心可能复用同一窗口，仅让该窗口的旧识别失效。 */
    fun onSystemContentChanged(windowId: Int) {
        invalidatePanel(windowId)
        requestScan()
    }

    /** 服务销毁后不允许滞后的异步结果重新添加遮挡。 */
    fun close() {
        setEnabled(false)
        generation++
        worker.shutdownNow()
        resolver.shutdown()
    }

    private fun requestScan() {
        if (!isEnabled || isQueued) return
        isQueued = true
        handler.postDelayed(pulse, 60)
    }

    /** 新身份已经可用时立即扫描，不再为已确认的禁用窗口多等一轮心跳。 */
    private fun requestImmediateScan() {
        if (!isEnabled) return
        handler.removeCallbacks(pulse)
        isQueued = true
        handler.post(pulse)
    }

    private fun scheduleHeartbeat() {
        if (isQueued) return
        isQueued = true
        handler.postDelayed(pulse, 600)
    }

    private fun phonePackages(): Set<String> = LockRuntime.state.value?.access?.phonePackages.orEmpty()

    private fun invalidatePanel(windowId: Int) {
        if (windowId >= 0) {
            panelRevisions.merge(windowId, 1L, Long::plus)
            if (packageCache[windowId]?.name == SYSTEM_UI) resolveAfter.remove(windowId)
            if (shadeWindows.remove(windowId) != null) panelCloser.cancel()
        } else {
            panelEpoch++
            shadeWindows.keys.toList().forEach { panelRevisions.merge(it, 1L, Long::plus) }
            shadeWindows.clear()
            panelCloser.cancel()
        }
    }

    private fun scan() {
        if (!isEnabled || !LockController.isGuardActive(service)) { overlay.clear(); return }
        if (power?.isInteractive != true) {
            overlay.clear()
            panelCloser.cancel()
            scheduleHeartbeat()
            return
        }
        dismissShade()
        if (isScanning) { scheduleHeartbeat(); return }
        isScanning = true
        val expectedGeneration = generation
        val expectedRevision = windowRevision
        val startedAt = SystemClock.elapsedRealtime()
        try {
            worker.execute {
                val snapshots = runCatching { readWindows() }.getOrNull()
                val keyboard = runCatching { InstalledApps.currentImePackage(service) }.getOrNull()
                handler.post {
                    isScanning = false
                    if (!isEnabled || !LockController.isGuardActive(service) || expectedGeneration != generation) {
                        if (!LockController.isGuardActive(service)) overlay.clear()
                        return@post
                    }
                    if (expectedRevision != windowRevision || SystemClock.elapsedRealtime() - startedAt > 1000) {
                        requestScan()
                        return@post
                    }
                    if (snapshots != null && power?.isInteractive == true) apply(snapshots, keyboard)
                    scheduleHeartbeat()
                }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            isScanning = false
        }
    }

    private fun readWindows(): List<LockWindowSnapshot> {
        val windows = service.windows
        return windows.mapNotNull { window ->
            try {
                val bounds = Rect()
                window.getBoundsInScreen(bounds)
                LockWindowSnapshot(window.id, readPackage(window), window.type, window.layer, window.isFocused,
                    LockWindowBounds(bounds.left, bounds.top, bounds.right, bounds.bottom))
            } finally {
                @Suppress("DEPRECATION")
                window.recycle()
            }
        }
    }

    private fun readPackage(window: AccessibilityWindowInfo): String? {
        val now = SystemClock.elapsedRealtime()
        val cached = packageCache[window.id]?.takeIf { it.type == -1 || it.type == window.type }
        if (cached?.name == SYSTEM_UI && window.isFocused) resolveIdentity(window, now)
        if (cached != null && now - cached.at < 10_000) return cached.name
        resolveIdentity(window, now)
        // 同一个仍存在的窗口刷新身份时沿用已确认包名，避免误遮电话或放开已知禁窗。
        return cached?.name
    }

    /** 慢节点单独补查，最多两条在途任务；不能拖住已知禁窗的遮挡。 */
    private fun resolveIdentity(window: AccessibilityWindowInfo, now: Long) {
        if (now < (resolveAfter[window.id] ?: 0L) || resolvingCount.get() >= 2) return
        resolveAfter[window.id] = now + if (packageCache[window.id]?.name == SYSTEM_UI) 1000 else 10_000
        resolvingCount.incrementAndGet()
        @Suppress("DEPRECATION")
        val copy = AccessibilityWindowInfo.obtain(window)
        val expectedGeneration = generation
        val expectedPanelRevision = panelRevisions[window.id] ?: 0L
        val expectedPanelEpoch = panelEpoch
        try {
            resolver.execute {
                var isShade = false
                val name = runCatching {
                    val root = if (Build.VERSION.SDK_INT >= 33) copy.getRoot(0) else copy.root
                    try {
                        val name = root?.packageName?.toString()
                        if (name == SYSTEM_UI && copy.isFocused && keyguard?.isKeyguardLocked != true && root != null) {
                            val bounds = Rect()
                            copy.getBoundsInScreen(bounds)
                            val screen = screenBounds()
                            isShade = LockPanelReader.isPanel(root, name, copy.type, copy.isFocused,
                                keyguard?.isKeyguardLocked == true,
                                LockWindowBounds(bounds.left, bounds.top, bounds.right, bounds.bottom),
                                screen.right - screen.left, screen.bottom - screen.top)
                        }
                        name
                    } finally {
                        @Suppress("DEPRECATION")
                        root?.recycle()
                    }
                }.getOrNull()
                val id = copy.id
                val type = copy.type
                @Suppress("DEPRECATION")
                copy.recycle()
                resolvingCount.decrementAndGet()
                handler.post { onIdentityResolved(id, type, name, isShade, now, expectedGeneration, expectedPanelRevision, expectedPanelEpoch) }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            resolvingCount.decrementAndGet()
            @Suppress("DEPRECATION")
            copy.recycle()
        }
    }

    private fun onIdentityResolved(
        id: Int, type: Int, name: String?, isShade: Boolean, startedAt: Long,
        expectedGeneration: Int, expectedPanelRevision: Long, expectedPanelEpoch: Long,
    ) {
        if (!isEnabled || expectedGeneration != generation) return
        if (visibleTypes[id] != type) {
            resolveAfter.remove(id)
            requestImmediateScan()
            return
        }
        val newer = packageCache[id]
        if (newer != null && newer.at > startedAt && newer.name != name) return
        // 首次根节点暂不可用通常发生在进场动画中，不能沿用已知身份的10秒刷新间隔。
        if (name == null && newer == null) {
            resolveAfter[id] = SystemClock.elapsedRealtime() + 300
            requestImmediateScan()
            return
        }
        if (name == null) return
        packageCache[id] = CachedPackage(name, type, SystemClock.elapsedRealtime())
        val isCurrentEvidence = expectedPanelEpoch == panelEpoch &&
            expectedPanelRevision == (panelRevisions[id] ?: 0L) && SystemClock.elapsedRealtime() - startedAt < 1500
        if (isCurrentEvidence) {
            if (isShade && isCurrentSystemWindow(id)) shadeWindows[id] = startedAt else shadeWindows.remove(id)
        }
        requestImmediateScan()
    }

    private fun apply(windows: List<LockWindowSnapshot>, keyboard: String?) {
        val access = LockRuntime.state.value?.access ?: run { overlay.clear(); return }
        visibleTypes = windows.associate { it.id to it.type }
        panelRevisions.keys.retainAll(visibleTypes.keys)
        packageCache.keys.retainAll(visibleTypes.keys)
        shadeWindows.keys.retainAll(visibleTypes.keys)
        val focusedSystemUi = windows.filter { it.focused && it.packageName == SYSTEM_UI }.map { it.id }.toSet()
        shadeWindows.keys.retainAll(focusedSystemUi)
        if (keyguard?.isKeyguardLocked == true) shadeWindows.clear()
        val now = SystemClock.elapsedRealtime()
        val knownShade = windows.firstOrNull {
            it.focused && it.packageName == SYSTEM_UI && now - (shadeWindows[it.id] ?: 0L) < 2500 &&
                keyguard?.isKeyguardLocked != true
        }
        // 系统面板通过原生收起或上滑处理，不在其上盖触摸层，否则收起手势会被自己吃掉。
        val guarded = windows.map { if (it == knownShade) it.copy(type = LockWindowPolicy.TYPE_SYSTEM) else it }
        val blocked = LockWindowPolicy.blockedRegions(guarded, access, keyboard ?: access.currentImePackage)
        overlay.update(blocked, screenBounds())
        recordBlocked(blocked)
        if (knownShade != null) panelCloser.closePanel(knownShade.id)
        // 身份还没读出来的窗口只遮挡、不拉回，避免锁页自己进场时被当成禁用窗口反复重启。
        val forbiddenFocus = windows.firstOrNull { window ->
            window.focused && window.packageName != null && blocked.any { it.id == window.id }
        }
        if (forbiddenFocus != null && now - lastRecoveryAt > 1200) {
            lastRecoveryAt = now
            // 不发送通用返回，避免焦点刚切换时影响电话或白名单应用；直接把锁页顶回前台。
            LockController.returnToLock(service)
        }
    }

    /** 只在被遮挡的窗口集合变化时写诊断，避免每次心跳都写盘。 */
    private fun recordBlocked(blocked: List<LockBlockedRegion>) {
        val key = blocked.mapTo(mutableSetOf()) { "${it.id}:${it.packageName}:${it.type}" }
        if (key == lastBlockedKey) return
        lastBlockedKey = key
        blocked.distinctBy { it.id }.forEach {
            LockDiagnostics.record(service, LockDiagnosticAction.WINDOW_BLOCK, it.packageName, it.type)
        }
    }

    /** 只检查目标窗口的最新身份与焦点；其他窗口的动画不会让确认结果永久失效。 */
    private fun isCurrentSystemWindow(windowId: Int): Boolean {
        if (keyguard?.isKeyguardLocked == true || packageCache[windowId]?.name != SYSTEM_UI) return false
        val current = service.windows
        return try {
            current.any { it.id == windowId && it.isFocused &&
                (it.type == AccessibilityWindowInfo.TYPE_SYSTEM || it.type == AccessibilityWindowInfo.TYPE_APPLICATION) }
        } finally {
            @Suppress("DEPRECATION")
            current.forEach { it.recycle() }
        }
    }

    /** 延迟手势执行前重新确认会话、目标身份、焦点和几何，未知窗口绝不注入手势。 */
    private fun currentPanelBounds(windowId: Int): LockWindowBounds? {
        if (!isEnabled || !LockController.isGuardActive(service) || power?.isInteractive != true ||
            keyguard?.isKeyguardLocked == true || packageCache[windowId]?.name != SYSTEM_UI ||
            SystemClock.elapsedRealtime() - (shadeWindows[windowId] ?: 0L) >= 2500) return null
        val current = service.windows
        return try {
            val window = current.firstOrNull { it.id == windowId && it.isFocused &&
                (it.type == AccessibilityWindowInfo.TYPE_SYSTEM || it.type == AccessibilityWindowInfo.TYPE_APPLICATION) }
                ?: return null
            if (current.any { it.isFocused && it.id != windowId }) return null
            val bounds = Rect()
            window.getBoundsInScreen(bounds)
            val screen = screenBounds()
            if (!bounds.intersect(Rect(screen.left, screen.top, screen.right, screen.bottom))) return null
            // 上层音量框或其他浮层可能吃掉手势；不清空它们，也不冒险滑过。
            val lane = Rect(bounds.centerX() - 2, bounds.top + bounds.height() * 12 / 100,
                bounds.centerX() + 2, bounds.top + bounds.height() * 88 / 100)
            if (current.any { other ->
                    if (other.id == windowId || other.layer <= window.layer) false else {
                        val otherBounds = Rect()
                        other.getBoundsInScreen(otherBounds)
                        Rect.intersects(otherBounds, lane)
                    }
                }) return null
            LockWindowBounds(bounds.left, bounds.top, bounds.right, bounds.bottom)
        } finally {
            @Suppress("DEPRECATION")
            current.forEach { it.recycle() }
        }
    }

    /** Android 12起有专用的收起通知栏动作，不触发返回或电源菜单。 */
    private fun dismissShade() {
        if (Build.VERSION.SDK_INT < 31) return
        val now = SystemClock.elapsedRealtime()
        if (now - lastShadeAt < 400) return
        lastShadeAt = now
        service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE)
    }

    private fun screenBounds(): LockWindowBounds = screenBounds(service.getSystemService(WindowManager::class.java))

    /** 短时补偿节点暂不可用；窗口移除或ID重用后不会长期信任旧包名。 */
    private data class CachedPackage(val name: String, val type: Int, val at: Long)

    companion object {
        private const val SYSTEM_UI = "com.android.systemui"

        internal fun screenBounds(manager: WindowManager): LockWindowBounds =
            if (Build.VERSION.SDK_INT >= 30) {
                manager.maximumWindowMetrics.bounds.let { LockWindowBounds(it.left, it.top, it.right, it.bottom) }
            } else {
                val size = Point()
                @Suppress("DEPRECATION")
                manager.defaultDisplay.getRealSize(size)
                LockWindowBounds(0, 0, size.x, size.y)
            }
    }
}

/** 只拦截禁用区域的触摸，不绘制图形或文字，也不盖住电话、输入法和白名单区域。 */
internal class LockBlockedOverlay(private val service: AccessibilityService) {
    private val manager = service.getSystemService(WindowManager::class.java)
    private val views = mutableMapOf<LockOverlaySlot, Entry>()

    /** 按目标窗口和片序号复用遮挡，先补齐新区域再移除旧区域，避免几何变化时反复创建窗口。 */
    fun update(regions: List<LockBlockedRegion>, screen: LockWindowBounds) {
        if (regions.isEmpty()) { clear(); return }
        val desired = LockOverlayLayout.plan(regions, screen)
        desired.forEach { (slot, bounds) -> place(slot, bounds) }
        (views.keys - desired.keys).forEach(::remove)
    }

    /** 会话结束、熄屏或服务解绑时立即移除所有遮挡。 */
    fun clear() {
        views.keys.toList().forEach(::remove)
    }

    private fun place(slot: LockOverlaySlot, bounds: LockWindowBounds) {
        val entry = views[slot]
        if (entry == null) { add(slot, bounds); return }
        if (entry.bounds == bounds) return
        try {
            manager.updateViewLayout(entry.view, layoutParams(bounds))
            entry.bounds = bounds
        } catch (_: RuntimeException) {
            // 更新失败时保留旧记录，后续扫描仍可重试或移除，不能遗失已挂载的遮挡。
        }
    }

    private fun add(slot: LockOverlaySlot, bounds: LockWindowBounds) {
        val view = View(service).apply {
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            setBackgroundColor(Color.TRANSPARENT)
            isClickable = true
            // 仅像素透明，View仍可见且窗口alpha为1，不能用不可见状态或不可触摸标志放开输入。
            setOnTouchListener { _, _ -> true }
        }
        try {
            manager.addView(view, layoutParams(bounds))
            views[slot] = Entry(view, bounds)
        } catch (_: RuntimeException) {
            // 服务刚断开时系统会拒绝添加，下一次扫描重试。
        }
    }

    private fun remove(slot: LockOverlaySlot) {
        val entry = views[slot] ?: return
        try {
            manager.removeViewImmediate(entry.view)
            views.remove(slot)
        } catch (_: IllegalArgumentException) {
            views.remove(slot)
        } catch (_: RuntimeException) {
            // 移除失败时保留记录，后续更新重试。
        }
    }

    private fun layoutParams(bounds: LockWindowBounds) = WindowManager.LayoutParams(
        bounds.right - bounds.left, bounds.bottom - bounds.top,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        PixelFormat.TRANSLUCENT,
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        x = bounds.left
        y = bounds.top
        title = "NivoFocusLockBlockedRegion"
        windowAnimations = 0
        alpha = 1f
        dimAmount = 0f
        if (Build.VERSION.SDK_INT >= 30) setFitInsetsTypes(0)
    }

    /** 保存已成功提交的几何，重复快照不触发WindowManager更新。 */
    private data class Entry(val view: View, var bounds: LockWindowBounds)
}
