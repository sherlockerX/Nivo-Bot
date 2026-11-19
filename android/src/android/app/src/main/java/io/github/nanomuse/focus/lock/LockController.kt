package io.github.nanomuse.focus.lock

import android.accessibilityservice.AccessibilityService
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityWindowInfo
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.ui.focus.FocusImmersiveActivity
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** 顺序组织恢复、到期结算与拦截，不在无障碍回调里访问数据库。 */
object LockController {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutex = Mutex()
    private val gate = LockLaunchGate()
    private var isInitialized = false
    private var accessReadAt = 0L
    /** 窗口守护跟随无障碍服务实例；服务重建时换新实例，旧实例的遮挡随之撤去。 */
    private var guard: LockWindowGuard? = null
    private var guardService: AccessibilityService? = null

    /** 应用初始化后恢复当前账号，其他账号的快照立即清空。 */
    fun init(application: Application) {
        if (isInitialized) return
        isInitialized = true
        application.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) { LockRuntime.ownActivityClass = activity.javaClass.name }
            override fun onActivityPaused(activity: Activity) { }
            override fun onActivityCreated(activity: Activity, state: Bundle?) { }
            override fun onActivityStarted(activity: Activity) { }
            override fun onActivityStopped(activity: Activity) { }
            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) { }
            override fun onActivityDestroyed(activity: Activity) { }
        })
        // 开始或结束强制时立即开关遮挡，不等下一次窗口事件。
        scope.launch { LockRuntime.state.map { it?.run?.id }.distinctUntilChanged().collect { id ->
            guard?.setEnabled(id != null && isGuardActive(application))
        } }
        scope.launch { AccountData.epoch.collectLatest {
            LockRuntime.publish(null); gate.reset(); accessReadAt = 0; LockAlarms.invalidate()
            while (isActive) {
                try {
                    evaluate(application)
                    val store = LockStore.get(application)
                    combine(store.observeWhitelist(), store.observePlans()) { _, _ -> Unit }.collectLatest {
                        accessReadAt = 0; evaluate(application)
                    }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) {
                    LockDiagnostics.record(application, LockDiagnosticAction.RESTORE)
                    delay(2000)
                }
            }
        } }
    }

    /** 闹钟及系统回调均进入同一串行结算路径。 */
    fun requestEvaluation(context: Context) { scope.launch {
        try { evaluate(context.applicationContext) }
        catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { LockDiagnostics.record(context, LockDiagnosticAction.RESTORE) }
    } }

    /** 亮屏先结算再看前台证据，不能用恢复设置打断电话或白名单应用。 */
    fun onWake(context: Context) { scope.launch {
        try {
            val run = evaluate(context) ?: return@launch
            val snapshot = LockRuntime.state.value ?: return@launch
            val activity = LockForegroundMonitor(context).sample(run.id)
            val foreground = activity?.let { LockAccessPolicy.Foreground(it.packageName, it.className) }
                ?: LockRuntime.foregroundPackage?.let { LockAccessPolicy.Foreground(it, LockRuntime.foregroundClass) }
            if (LockRuntime.state.value?.run?.id == run.id &&
                LockWakePolicy.shouldRestore(LockSettings.showOnWake(context), snapshot.access, foreground,
                    LockRuntime.remaining(context))) show(context, run)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { LockDiagnostics.record(context, LockDiagnosticAction.RESTORE) }
    } }

    /** 用户在锁页结束强制正计时：结算并完成会话，再走一次评估解除守护。 */
    suspend fun finishStopwatch(context: Context, runId: String) {
        LockStore.get(context).finishStopwatch(runId)
        evaluate(context)
    }

    /** 内部启动只接受定长与已就绪授权，不接受模型传入的历史时长。 */
    suspend fun startManual(context: Context, title: String, taskId: String?, durationMs: Long,
        mode: String = "pomodoro", prepareScreen: suspend (String) -> Unit = {}): LockRun = mutex.withLock {
        LockSafetyRules.requireDuration(durationMs, LockDevelopment.maximumDurationMs)
        check(LockPermissions.read(context).isReady) { "lock_permissions_required" }
        check(withContext(Dispatchers.IO) { InstalledApps.canDial(context) }) { "lock_dialer_required" }
        val run = LockStore.get(context).start(title, taskId, durationMs, mode = mode)
        refreshSnapshot(context, run, forceAccess = true)
        LockAlarms.sync(context, run)
        LockDiagnostics.record(context, LockDiagnosticAction.START)
        LockGuardService.ensure(context)
        // 背景绑定必须早于首屏读取；准备失败也必须展示已生效的锁页。
        try { prepareScreen(run.sessionId) } finally { show(context, run) }
        run
    }

    /** 每次返回前落盘到期结算；已完成时只解除守护，不再启动锁页。 */
    suspend fun evaluate(context: Context): LockRun? = mutex.withLock {
        val previous = LockRuntime.state.value?.run
        val store = LockStore.get(context)
        var run = store.active()
        val decision = LockScheduleDecision.evaluate(store.plans(), store.runs(), run, System.currentTimeMillis())
        if (run != null) run = store.tighten(run.id, decision.activePlanIds, decision.usesWhitelist)
        if (run == null && decision.window != null && decision.startDurationMs != null) {
            if (LockPermissions.read(context).isReady && withContext(Dispatchers.IO) { InstalledApps.canDial(context) }) {
                val selected = store.plans().firstOrNull { it.id in decision.window.planIds }
                val duration = minOf(decision.startDurationMs, LockDevelopment.maximumDurationMs)
                val title = selected?.title?.takeIf { it.isNotBlank() } ?: selected?.name ?: context.getString(com.openminis.app.R.string.nm_lock_title)
                run = try { store.start(title, selected?.taskId, duration, decision.window.usesWhitelist,
                    decision.window.planIds, decision.window.occurrenceIds) }
                catch (failure: IllegalStateException) {
                    if (failure.message != "task_not_found") throw failure
                    store.start(title, null, duration, decision.window.usesWhitelist,
                        decision.window.planIds, decision.window.occurrenceIds)
                }
                LockDiagnostics.record(context, LockDiagnosticAction.START)
            } else LockNotifications.waitingPermissions(context, decision.window)
        }
        refreshSnapshot(context, run)
        LockAlarms.sync(context, run)
        LockAlarms.scheduleStart(context, if (run == null && decision.window != null) decision.retryAt else decision.nextStartAt)
        if (run == null || previous?.id != run.id) LockNotifications.completed(context, store, previous?.id)
        if (run == null && previous != null) {
            gate.reset(); LockDiagnostics.record(context, LockDiagnosticAction.COMPLETE)
            LockGuardService.stop(context)
        }
        if (run != null && previous?.id != run.id) { LockGuardService.ensure(context); show(context, run) }
        run
    }

    /** 守护是否应当生效：有当前账号的活动会话且尚未到期。 */
    fun isGuardActive(context: Context): Boolean {
        val snapshot = LockRuntime.state.value ?: return false
        return LockRuntime.remaining(context, snapshot) > 0
    }

    /**
     * 只复制事件的包名、类名与窗口类型，不访问任何节点、文字或描述。
     * 窗口变化先交给窗口守护盖遮挡，再按前台Activity决定是否拉回锁页。
     */
    fun onAccessibilityEvent(service: AccessibilityService, event: AccessibilityEvent?) {
        if (event == null) return
        val eventType = event.eventType
        if (eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
            eventType != AccessibilityEvent.TYPE_WINDOWS_CHANGED &&
            eventType != AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) return
        // 白名单里播放视频时内容变化事件极多；只有SystemUI的面板识别需要它们，其余直接丢弃。
        if (eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED &&
            event.packageName?.toString() != "com.android.systemui") return
        val snapshot = LockRuntime.state.value
        if (snapshot == null) { guard?.setEnabled(false); return }
        val windowGuard = guardFor(service)
        windowGuard.setEnabled(LockRuntime.remaining(service, snapshot) > 0)
        if (eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) {
            // 控制中心可能复用同一窗口，内容变化时重新识别这个窗口。
            windowGuard.onSystemContentChanged(event.windowId)
            return
        }
        windowGuard.onWindowEvent(event.packageName?.toString(), event.windowId)
        if (eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        val packageName = event.packageName?.toString() ?: return
        val className = event.className?.toString()
        val type = runCatching { service.windows.firstOrNull { it.id == event.windowId }?.type }.getOrNull()
        // 某些输入法弹窗没有窗口类型，只有系统确认的Activity才能当作应用拦截。
        if (type == null && !isDeclaredActivity(service, packageName, className)) return
        val kind = if (type == AccessibilityWindowInfo.TYPE_INPUT_METHOD) LockAccessPolicy.WindowKind.INPUT_METHOD
            else if (type == AccessibilityWindowInfo.TYPE_SYSTEM) LockAccessPolicy.WindowKind.OTHER else LockAccessPolicy.WindowKind.APPLICATION
        val ownClass = if (packageName == service.packageName && className?.startsWith("android.") == true)
            LockRuntime.ownActivityClass else className
        val foreground = LockAccessPolicy.Foreground(packageName, ownClass, kind,
            isActivity = kind == LockAccessPolicy.WindowKind.APPLICATION)
        if (kind == LockAccessPolicy.WindowKind.APPLICATION) LockRuntime.observeForeground(packageName, ownClass, System.currentTimeMillis())
        enforce(service, foreground, type)
    }

    /** 无障碍服务销毁时撤去它名下的遮挡和后台线程。 */
    fun onAccessibilityServiceGone(service: AccessibilityService) {
        if (guardService !== service) return
        guard?.close()
        guard = null
        guardService = null
    }

    private fun guardFor(service: AccessibilityService): LockWindowGuard {
        val current = guard
        if (current != null && guardService === service) return current
        current?.close()
        return LockWindowGuard(service).also { guard = it; guardService = service }
    }

    /**
     * 使用情况兜底与无障碍共用到期检查和去重。拉回在主线程立即发起，不排队等数据库：
     * 判断只用内存快照和单调钟，到期或紧急退出由随后的结算撤销守护。
     */
    fun enforce(context: Context, foreground: LockAccessPolicy.Foreground, windowType: Int? = null) {
        val snapshot = LockRuntime.state.value ?: return
        val remaining = LockRuntime.remaining(context, snapshot)
        val decision = decideForeground(context, snapshot.access, foreground, remaining)
        if (decision == LockAccessPolicy.Decision.EXPIRED) { requestEvaluation(context); return }
        gate.observeForeground(LockRuntime.foregroundGeneration,
            foreground.packageName == context.packageName && foreground.className == snapshot.access.lockActivityClass)
        if (decision != LockAccessPolicy.Decision.BLOCK || !gate.claim(SystemClock.elapsedRealtime())) return
        LockDiagnostics.record(context, LockDiagnosticAction.BLOCK, foreground.packageName, windowType)
        show(context, snapshot.run)
        requestEvaluation(context)
    }

    /** 窗口守护发现禁用窗口仍有焦点（例如小窗）时调用，与前台拦截共用去重。 */
    internal fun returnToLock(context: Context) {
        val snapshot = LockRuntime.state.value ?: return
        if (LockRuntime.remaining(context, snapshot) <= 0) { requestEvaluation(context); return }
        if (!gate.claim(SystemClock.elapsedRealtime())) return
        show(context, snapshot.run)
    }

    private fun decideForeground(context: Context, access: LockAccessPolicy.Context,
        foreground: LockAccessPolicy.Foreground, remainingMs: Long): LockAccessPolicy.Decision {
        // 只为实际输入法窗口刷新系统身份，输入法设置Activity仍走普通永禁规则。
        val currentIme = if (remainingMs > 0 && foreground.windowKind == LockAccessPolicy.WindowKind.INPUT_METHOD)
            InstalledApps.currentImePackage(context) else access.currentImePackage
        return LockAccessPolicy.decide(access, foreground, true, remainingMs, currentIme)
    }

    private suspend fun refreshSnapshot(context: Context, run: LockRun?, forceAccess: Boolean = false) {
        if (run == null) { LockRuntime.publish(null); return }
        val ownerEpoch = AccountData.epoch.value
        if (AccountData.key(context) != run.ownerKey) { LockRuntime.publish(null); return }
        val old = LockRuntime.state.value
        val now = SystemClock.elapsedRealtime()
        val access = if (!forceAccess && old?.run?.id == run.id && now - accessReadAt < 15_000 && old.run.usesWhitelist == run.usesWhitelist) old.access
        else withContext(Dispatchers.IO) {
            InstalledApps.accessContext(context, LockStore.get(context).whitelist(), run.usesWhitelist)
        }.also { accessReadAt = now }
        if (ownerEpoch == AccountData.epoch.value && AccountData.key(context) == run.ownerKey)
            LockRuntime.publish(LockSnapshot(run, access, ownerEpoch, countsUp = if (old?.run?.id == run.id) old.countsUp
                else withContext(Dispatchers.IO) { io.github.nanomuse.mosaic.MosaicDatabase.get(context).focusDao()
                    .session(run.ownerKey, run.sessionId)?.mode == "stopwatch" }))
    }

    /** 零转场拉回锁页，用户看不到被拦截应用和锁页之间的切换动画。 */
    private fun show(context: Context, run: LockRun) {
        if (LockRuntime.remaining(context) <= 0) return
        try {
            val options = android.app.ActivityOptions.makeCustomAnimation(context, 0, 0).toBundle()
            context.startActivity(FocusImmersiveActivity.intent(context, run.ownerKey, run.sessionId), options)
            LockDiagnostics.record(context, LockDiagnosticAction.RETURN)
        } catch (_: Exception) { LockDiagnostics.record(context, LockDiagnosticAction.RETURN_FAILED) }
    }

    private fun isDeclaredActivity(context: Context, packageName: String, className: String?): Boolean {
        if (className == null) return false
        return runCatching {
            context.packageManager.getActivityInfo(android.content.ComponentName(packageName, className), 0)
        }.isSuccess
    }
}
