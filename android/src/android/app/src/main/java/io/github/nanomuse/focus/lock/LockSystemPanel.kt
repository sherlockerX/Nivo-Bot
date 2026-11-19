package io.github.nanomuse.focus.lock

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import java.util.Locale

/**
 * 只检查SystemUI可见节点的资源ID结构，兼容各厂商独立的控制中心，移植自FocusLock的SystemPanelReader（MIT）。
 * 不访问文字、描述或输入内容。
 */
internal object LockPanelReader {
    private const val MAX_NODES = 512
    private const val MAX_DEPTH = 32
    private val CONTROL_CENTER = Regex("(^|_)(control_center|controlcenter|notification_shade)(_|$)")
    private val EXCLUDED = listOf("global_actions", "globalactions", "power_menu", "powermenu", "volume_dialog",
        "volumedialog", "volume_panel", "volumepanel", "biometric", "permission", "resolver", "chooser")

    /** 系统包、焦点、几何和锁屏条件共同成立，才把节点证据交给收起逻辑。 */
    fun isPanel(
        root: AccessibilityNodeInfo,
        packageName: String?,
        type: Int,
        focused: Boolean,
        isKeyguardLocked: Boolean,
        bounds: LockWindowBounds,
        screenWidth: Int,
        screenHeight: Int,
    ): Boolean {
        if (packageName != "com.android.systemui" || !focused || isKeyguardLocked) return false
        val ids = visibleResourceIds(root) ?: return false
        return LockPanelPolicy.shouldClose(LockPanelEvidence(packageName, type, focused, isKeyguardLocked,
            hasKnownPanelId = ids.any { it == "quick_settings_container" || it == "qs_frame" },
            hasControlCenterId = ids.any { CONTROL_CENTER.containsMatchIn(it) },
            hasBrightnessId = ids.any { it.contains("brightness") },
            hasTileId = ids.any { it.contains("tile_layout") || it.contains("tilelayout") ||
                it.startsWith("qs_panel") || it.contains("quick_setting") },
            hasExcludedDialog = ids.any { id -> EXCLUDED.any(id::contains) },
            windowBounds = bounds, screenWidth = screenWidth, screenHeight = screenHeight))
    }

    private fun visibleResourceIds(root: AccessibilityNodeInfo): Set<String>? {
        val found = mutableSetOf<String>()
        val queue = ArrayDeque<Pair<AccessibilityNodeInfo, Int>>()
        @Suppress("DEPRECATION")
        queue.add(AccessibilityNodeInfo.obtain(root) to 0)
        var visited = 0
        try {
            while (queue.isNotEmpty() && visited < MAX_NODES) {
                val (node, depth) = queue.removeFirst()
                visited++
                try {
                    if (node.isVisibleToUser) {
                        node.viewIdResourceName?.takeIf { it.startsWith("com.android.systemui:id/") }
                            ?.substringAfter(":id/")?.lowercase(Locale.ROOT)?.let(found::add)
                    }
                    if (depth >= MAX_DEPTH && node.childCount > 0) return null
                    if (depth < MAX_DEPTH) {
                        val available = (MAX_NODES - visited - queue.size).coerceAtLeast(0)
                        if (node.childCount > available) return null
                        repeat(minOf(node.childCount, available)) { index ->
                            node.getChild(index)?.let { queue.add(it to depth + 1) }
                        }
                    }
                } finally {
                    @Suppress("DEPRECATION")
                    node.recycle()
                }
            }
        } finally {
            @Suppress("DEPRECATION")
            queue.forEach { (node, _) -> node.recycle() }
        }
        return found
    }
}

/**
 * 优先系统原生的收起动作；独立控制中心仍可见时注入一次向上滑动，移植自FocusLock的SystemPanelCloser（MIT）。
 * 每次尝试后重新观察窗口，动作被系统接受不代表面板已经消失。
 */
internal class LockPanelCloser(
    private val service: AccessibilityService,
    private val currentBounds: (Int) -> LockWindowBounds?,
) {
    private val handler = Handler(Looper.getMainLooper())
    private var pendingWindowId: Int? = null
    private var generation = 0
    private var lastAttemptAt = 0L
    private var isGestureRunning = false

    fun closePanel(windowId: Int) {
        val now = SystemClock.elapsedRealtime()
        if (pendingWindowId != null || isGestureRunning || now - lastAttemptAt < 900) return
        if (currentBounds(windowId) == null) return
        lastAttemptAt = now
        pendingWindowId = windowId
        val expectedGeneration = generation
        if (Build.VERSION.SDK_INT >= 31) {
            service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE)
        }
        LockDiagnostics.record(service, LockDiagnosticAction.PANEL_CLOSE, "com.android.systemui")
        handler.postDelayed({
            if (generation != expectedGeneration) return@postDelayed
            pendingWindowId = null
            val bounds = currentBounds(windowId) ?: return@postDelayed
            swipeUp(windowId, bounds, expectedGeneration)
        }, 300)
    }

    /** 到期、熄屏、电话切入或服务销毁后取消尚未派发的动作。 */
    fun cancel() {
        generation++
        pendingWindowId = null
        isGestureRunning = false
        handler.removeCallbacksAndMessages(null)
    }

    private fun swipeUp(windowId: Int, bounds: LockWindowBounds, expectedGeneration: Int) {
        val width = bounds.right - bounds.left
        val height = bounds.bottom - bounds.top
        if (width <= 0 || height <= 0 || currentBounds(windowId) != bounds) return
        val x = bounds.left + width * 0.5f
        val path = Path().apply {
            moveTo(x, bounds.top + height * 0.88f)
            lineTo(x, bounds.top + height * 0.12f)
        }
        val gesture = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, 180))
            .build()
        isGestureRunning = true
        val accepted = service.dispatchGesture(gesture, object : AccessibilityService.GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                if (generation == expectedGeneration) isGestureRunning = false
            }
            override fun onCancelled(gestureDescription: GestureDescription?) {
                if (generation == expectedGeneration) isGestureRunning = false
            }
        }, handler)
        if (!accepted) {
            isGestureRunning = false
            if (currentBounds(windowId) != null) service.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
        }
    }
}
