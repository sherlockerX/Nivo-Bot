package com.openminis.app.scheduled

import android.content.Context
import com.openminis.app.MinisApp
import com.openminis.app.R // nanoMuse
import com.openminis.app.debug.HeadlessChatRunner
import com.openminis.app.logging.AppLogger
import com.openminis.app.service.AgentForegroundService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * [T-android-scheduled-tasks-design] Headless agent launch for scheduled
 * tasks. Mirrors the shape of iOS SendPromptIntent.perform():
 *
 *  - resolve a session id (NEW_SESSION → create row; APPEND_TO → reuse)
 *  - run the prompt through the existing agent loop (via [HeadlessChatRunner])
 *  - post a "completed" notification with a deep-link back to the session
 *  - hand the result preview back to [ScheduledTaskManager] for the row
 *
 * Concurrency: serialised per-session by [HeadlessChatRunner]'s VM cache —
 * two scheduled prompts hitting the same session id are queued via
 * ChatViewModel.enqueuePrompt.
 */
object ScheduledAgentRunner {

    private const val TAG = "ScheduledAgentRunner"
    private const val RUN_TIMEOUT_MS = 10 * 60 * 1000L  // 10 min ceiling

    /**
     * App-scoped scope for fire-and-forget completion work when a caller asks
     * NOT to wait (the "Run now" button). Outlives the editor screen so the
     * agent loop + completion notification finish even after the user leaves.
     */
    private val bgScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /**
     * Fire a scheduled task.
     *
     * @param waitForCompletion when true, suspend until the agent loop
     *   finishes, then mark-fired + post the completion notification before
     *   returning. When false, return as soon as the session is resolved and
     *   the prompt is dispatched — the agent keeps running in the background
     *   and the completion (mark-fired + notification) is finished off an
     *   app-scoped coroutine. Mirrors iOS SendPromptIntent's waitForResult
     *   flag.
     *
     *   [GH#197] NEVER pass true from a BroadcastReceiver. Waiting here can
     *   take up to [RUN_TIMEOUT_MS] (10 min) and the wait lands on the main
     *   thread (HeadlessChatRunner.prompt/retry are
     *   `withContext(Dispatchers.Main)`), so a receiver that waits blows its
     *   ~10s broadcast budget and gets the whole process ANR-killed, along
     *   with every PRoot sandbox child. The alarm path passing the default
     *   `true` was exactly that bug. Waiting is only safe off a broadcast —
     *   e.g. the minis-scheduled CLI, which runs in its own offload thread.
     * @param firedTriggerAtMs nanoMuse: [GH#557] the trigger instant the
     *   alarm was armed for, recorded on the run so the history can show
     *   which of the task's times it belongs to. Null for runs started by
     *   hand (Run now, the CLI), which belong to no scheduled time.
     * @return the session id once the action has been DISPATCHED (resolved +
     *   prompt sent), or null when the runner couldn't even start (no provider,
     *   target chat gone, MinisApp not initialized).
     */
    suspend fun run(
        context: Context,
        task: ScheduledTask,
        waitForCompletion: Boolean = true,
        firedTriggerAtMs: Long? = null,
        onResult: ((io.github.nanomuse.routines.ScheduledCompletion) -> Unit)? = null, // nanoMuse: 本轮结果收据不读取共享的最后一次状态。
        persistentRunId: String? = null, // nanoMuse: 自动派发使用已经持久化的运行身份。
        dryNotify: Boolean = false, // nanoMuse: 执行并记录，但不推送通知。
    ): String? {
        // [T-android-scheduled-lateinit-crash-156] `as? MinisApp` only rules out
        // a null / wrong-type Application — it does NOT mean the Application is
        // INITIALIZED, which is what the old comment here claimed. Every
        // `app.chatRepository` read below goes through a lateinit getter that
        // throws UninitializedPropertyAccessException when onCreate
        // early-returned (safe-mode) or aborted partway.
        //
        // GH#156: an alarm fires while the process is in that state and the app
        // crashes. A scheduled task is the worst case for this because the alarm
        // can START the process — Android creates the Application, onCreate
        // early-returns under safe-mode, and the receiver runs against a
        // permanently half-built app with no Activity anywhere in the picture
        // (so MainActivity's guard never gets a say).
        //
        // Skipping the run is the right degradation: the task stays scheduled
        // and its next occurrence was already armed by the receiver before this
        // call, so a skipped fire self-heals on the following launch.
        val app = context.applicationContext as? MinisApp ?: run {
            AppLogger.error(TAG, "Application is not MinisApp — skipping task ${task.id}")
            return null
        }
        if (!app.subsystemsReady()) {
            AppLogger.error(
                TAG,
                "MinisApp subsystems not initialized (safe-mode or failed init) — skipping task ${task.id}",
            )
            return null
        }

        // nanoMuse: 先完成会话检查，再启动前台服务，避免失败后空转并持有唤醒锁。
        val startedAtMs = System.currentTimeMillis() // nanoMuse: 本轮开始独立于界面与通知生命周期。
        if (firedTriggerAtMs != null) { // nanoMuse: 已结算但尚未清理pending的运行不可重放业务。
            val saved = ScheduledTaskStore(app).get(task.id)
            if (saved == null || io.github.nanomuse.routines.ScheduledRunRecorder.alreadySettled(saved, firedTriggerAtMs)) {
                io.github.nanomuse.routines.RoutineHeartbeat.finish(app, task.id, firedTriggerAtMs)
                return saved?.runHistory?.firstOrNull { it.scheduledForMs == firedTriggerAtMs }?.sessionId
            }
        }
        val runScope = io.github.nanomuse.routines.ScheduledRunScope(task.id, startedAtMs,
            if (firedTriggerAtMs == null) "manual" else "schedule", script = task.scriptId != null, providedRunId = persistentRunId) // nanoMuse
        val preflight = withContext(Dispatchers.IO) { io.github.nanomuse.routines.ScheduledScript.probe(app, task) }
        if (!preflight.getBoolean("can_run")) {
            val stateWriteError = recordStartFailure(app, task, firedTriggerAtMs, preflight.getJSONArray("reasons").toString(), runScope) // nanoMuse: 诊断写入失败也返回本次实际预检结果。
            onResult?.invoke(io.github.nanomuse.routines.ScheduledCompletion(io.github.nanomuse.routines.RunOutcome.FAILURE, 4, "preflight_failed", runScope.runId, stateWriteError))
            return null
        }
        // nanoMuse: 不建会话的运行用按任务固定的执行身份。Mosaic: 脚本任务也写进任务的专属对话，只有调试运行不建。
        val sessionless = task.scriptId != null && task.targetMode is ScheduledTargetMode.NewSession && task.debug
        val sessionId = (if (sessionless) io.github.nanomuse.routines.ScheduledResult.sessionless(task.id)
            else withContext(Dispatchers.IO) { resolveSessionId(app, task, runScope) }) ?: run {
            val stateWriteError = recordStartFailure(app, task, firedTriggerAtMs, "No model configured or target conversation unavailable", runScope) // nanoMuse
            onResult?.invoke(io.github.nanomuse.routines.ScheduledCompletion(io.github.nanomuse.routines.RunOutcome.FAILURE, 4, "preflight_failed", runScope.runId, stateWriteError))
            return null
        }
        AgentForegroundService.startService(context = app, sessionCount = 1,
            toolStatus = "Scheduled: ${task.label.ifBlank { "task" }}")

        AppLogger.info(
            TAG,
            "running task=${task.id} label=\"${task.label}\" " +
                "mode=${task.targetMode.encode()} session=$sessionId wait=$waitForCompletion",
        )

        if (waitForCompletion) {
            complete(app, task, sessionId, runScope, firedTriggerAtMs, onResult, dryNotify) // nanoMuse: 同步与后台共用结算和日志。
            return sessionId
        }

        // Fire-and-forget: the session is resolved and the FGS is up, so the
        // task HAS started. Run the actual dispatch + completion entirely off
        // the app scope (wait=true so we still mark-fired + notify when it
        // finishes), and return the session id immediately so the UI can show
        // "task started" without blocking on the agent loop. Leaving the editor
        // can't cancel it because bgScope outlives the screen.
        bgScope.launch {
            complete(app, task, sessionId, runScope, firedTriggerAtMs, onResult, dryNotify) // nanoMuse
        }
        return sessionId
    }

    /**
     * [T-android-scheduled-tasks-full] Branch on target mode, mirroring the iOS
     * App Intent set:
     *   NewSession / AppendToSession → HeadlessChatRunner.prompt (the prompt is
     *     sent as a fresh user turn; for append it lands in the existing
     *     session, for new it's the first turn of the freshly-created one).
     *   RerunMessage → HeadlessChatRunner.retry from the chosen message id (the
     *     message is replayed; task.prompt is ignored, matching iOS
     *     RetryRunIntent which has no prompt param).
     */
    private suspend fun dispatch(
        app: MinisApp,
        task: ScheduledTask,
        sessionId: String,
        wait: Boolean,
        runScope: io.github.nanomuse.routines.ScheduledRunScope,
        trigger: String,
    ): HeadlessChatRunner.PromptResult = runCatching {
        task.scriptId?.let { scriptId -> // nanoMuse: 脚本任务不经模型转述，直接使用执行器的退出码。
            val command = io.github.nanomuse.routines.ScheduledScript.command(scriptId, task.scriptArgs)
            val scriptVersion = withContext(Dispatchers.IO) { io.github.nanomuse.routines.ScheduledScript.readVersion(app, scriptId) }
            val assessment = withContext(Dispatchers.IO) { // nanoMuse: 文件脚本也评估实际副作用，不以解释器名绕过闸门。
                io.github.nanomuse.routines.ScheduledScript.assessment(scriptId, scriptVersion.toString(Charsets.UTF_8))
            }
            val gate = io.github.nanomuse.guard.RiskGate.check(sessionId, io.github.nanomuse.guard.GuardKind.SHELL, assessment, preview = command)
            if (gate is io.github.nanomuse.guard.GateOutcome.Denied) return@runCatching HeadlessChatRunner.PromptResult("Error", gate.message, false, 3)
            val job = kotlinx.coroutines.currentCoroutineContext()[kotlinx.coroutines.Job]
            val stop: () -> Unit = { job?.cancel() } // nanoMuse: 独立进程由捕获器的取消清理终止。
            val claimed = com.openminis.app.service.SessionActivityTracker.tryStartExclusive(sessionId, onStop = stop, brief = task.label)
            if (!claimed) return@runCatching HeadlessChatRunner.PromptResult("Error", "Target conversation is busy", false, 4)
            var completedSuccessfully = false // nanoMuse: 取消和超时不能留下成功完成点。
            try {
                val result = io.github.nanomuse.routines.ScheduledProcess.execute(app, sessionId, scriptId, task.scriptArgs, runScope, trigger, RUN_TIMEOUT_MS, scriptVersion)
                val empty = result.stdoutBytes == 0L
                // Mosaic: 对话里写的和通知一致：report --result 交出的结果优先于 stdout。
                val reported = runScope.result?.takeIf { it.isNotBlank() }
                val text = reported ?: if (empty && result.exitCode == 0) app.getString(R.string.nm_task_empty_output) else result.stdout.ifEmpty { result.stderrTail }
                val messageBytes = if (io.github.nanomuse.routines.ScheduledResult.isSessionless(sessionId)) 0L // nanoMuse: 不建会话时结果只进日志与通知。
                else try {
                    // Mosaic: 先写一行任务唤醒，每次运行的结果各成一条，不并进上一次的气泡。
                    io.github.nanomuse.routines.ScheduledOutputWriter.wake(app.chatRepository, sessionId, runScope, task.label.ifBlank { scriptId }, command)
                    io.github.nanomuse.routines.ScheduledOutputWriter.write(app.chatRepository, sessionId, runScope,
                    if (empty && result.exitCode == 0 && reported == null) "system" else "assistant", text) }
                catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
                catch (_: Exception) { return@runCatching HeadlessChatRunner.PromptResult("Error", "MESSAGE_WRITE_FAILED", false,
                    result.exitCode, scriptOutput = result, messageTextBytes = 0) }
                completedSuccessfully = result.exitCode == 0 && !(empty && task.requireOutput) && result.captureError == null
                return@runCatching HeadlessChatRunner.PromptResult(if (result.captureError != null) "Error" else if (result.exitCode == 0) { if (empty) "CompletedEmpty" else "Completed" } else if (result.exitCode == 124) "Timeout" else "Error",
                    text, result.exitCode == 124, result.exitCode, scriptOutput = result, messageTextBytes = messageBytes)
            } finally {
                com.openminis.app.service.SessionActivityTracker.releaseExclusive(sessionId, stop, !completedSuccessfully) // nanoMuse: 仅释放自己的占用与停止回调。
            }
        }
        val mode = task.targetMode
        if (mode is ScheduledTargetMode.RerunMessage) {
            HeadlessChatRunner.retry(
                context = app,
                sessionId = sessionId,
                messageId = mode.messageId,
                wait = wait,
                timeoutMs = RUN_TIMEOUT_MS,
                scheduledRunId = runScope.runId, // nanoMuse: 上报与会话独占绑定本轮宿主派发。
            )
        } else {
            // nanoMuse: the row this sends is the routine's, not the person's: the chat draws it as
            // a quiet line and the model is told so for this one turn (RoutineWakes).
            io.github.nanomuse.chat.RoutineWakes.arm(app, sessionId, task.label)
            HeadlessChatRunner.prompt(
                context = app,
                sessionId = sessionId,
                text = task.prompt,
                attachments = emptyList(),
                thinkingLevel = null,
                wait = wait,
                timeoutMs = RUN_TIMEOUT_MS,
                scheduledRunId = runScope.runId, // nanoMuse
            )
        }
    }.getOrElse { t ->
        if (t is kotlinx.coroutines.CancellationException) throw t // nanoMuse: 取消交由统一结算写入中断状态。
        AppLogger.error(TAG, "task ${task.id} dispatch failed: ${t.message}")
        HeadlessChatRunner.PromptResult(
            status = "Error",
            responseText = "Error: ${t.message}",
            timedOut = false,
        )
    }.also { if (it.status == "Error") io.github.nanomuse.chat.RoutineWakes.disarm(sessionId) } // nanoMuse: a prompt that never went out leaves no mark

    // nanoMuse: 同步、后台、脚本和提示词共享结算；日志失败不改变业务结果。
    private suspend fun complete(app: MinisApp, task: ScheduledTask, sessionId: String,
        scope: io.github.nanomuse.routines.ScheduledRunScope, slot: Long?, callback: ((io.github.nanomuse.routines.ScheduledCompletion) -> Unit)?,
        dryNotify: Boolean = false) {
        val entered = io.github.nanomuse.routines.ScheduledRunScopes.enter(sessionId, scope)
        var cancelled = false
        try {
            val result = try {
                if (!entered || com.openminis.app.service.SessionActivityTracker.isActive(sessionId) || com.openminis.app.ui.chat.ChatViewModelStore.isSessionBusy(sessionId))
                    HeadlessChatRunner.PromptResult("Error", "TARGET_BUSY", false)
                else {
                    // Mosaic: 只有用户任务的回复是通知正文；内置教练和目标巡检的回复由应用解析，不注入"NO_OUTPUT/5行"约定。
                    // 教练例程按 id 认：旧版本建的例程没有来源字段，读出来是 legacy，会被当成用户任务。
                    if (task.scriptId == null && io.github.nanomuse.routines.ScheduledConversationGroup.isUserTask(task) &&
                        task.id != io.github.nanomuse.feed.FeedFlow.taskId(app)) io.github.nanomuse.chat.SessionAddenda.add(sessionId, "scheduled-report:${scope.runId}",
                        OUTPUT_CONTRACT, Int.MAX_VALUE) // nanoMuse: 输出约定随每次运行注入，旧任务同样适用。
                    dispatch(app, task, sessionId, true, scope, if (slot == null) "manual" else "schedule")
                }
            } catch (_: kotlinx.coroutines.CancellationException) {
                cancelled = true
                HeadlessChatRunner.PromptResult("Error", "RUN_ABORTED", false)
            }
            val failed = result.status in setOf("Error", "Timeout", "Aborted", "Cancelled")
            val outcome = io.github.nanomuse.routines.ScheduledRunScopes.outcome(scope, failed, result.exitCode,
                task.requireOutput && result.scriptOutput?.stdoutBytes == 0L)
            val reason = when {
                failed -> result.responseText?.takeIf { it in setOf("MESSAGE_WRITE_FAILED", "RUN_ABORTED", "TARGET_BUSY", "DISPATCH_NOT_STARTED") }
                    ?: result.scriptOutput?.captureError ?: if (task.scriptId == null) "MODEL_RUN_FAILED" else "SCRIPT_RUN_FAILED"
                task.requireOutput && result.scriptOutput?.stdoutBytes == 0L -> "EMPTY_OUTPUT"
                scope.report?.first == outcome -> scope.report?.second
                else -> null
            }
            val failedOutcome = outcome == io.github.nanomuse.routines.RunOutcome.FAILURE
            val sessionless = io.github.nanomuse.routines.ScheduledResult.isSessionless(sessionId)
            var stateWriteError = false
            var canonicalSettled = false // nanoMuse: 主状态提交失败保留恢复凭据，仅诊断失败不重执行业务。
            var produced = io.github.nanomuse.routines.ScheduledResult(null, "none")
            var decision: io.github.nanomuse.routines.ScheduledResultNotifier.Decision? = null
            withContext(kotlinx.coroutines.NonCancellable + Dispatchers.IO) {
                // nanoMuse: 结果与过程分离：通知只来自脚本 stdout、模型自报或最终回答，过程只进日志与会话。
                produced = when {
                    cancelled -> produced
                    // Mosaic: 脚本用 report --result 交出的结果优先于它碰巧打印的 stdout。
                    task.scriptId != null -> io.github.nanomuse.routines.ScheduledResult.prompt(scope.result, null).takeIf { it.text != null }
                        ?: io.github.nanomuse.routines.ScheduledResult.script(result.scriptOutput?.stdout)
                    else -> io.github.nanomuse.routines.ScheduledResult.prompt(scope.result, result.responseText?.let {
                        runCatching { app.chatRepository.dao.loadMessages(sessionId).lastOrNull { it.role == "assistant" }?.partsJson }.getOrNull()
                    })
                }
                val title = task.notifyTitle ?: task.label.ifBlank { "Scheduled task" }
                val body = if (failedOutcome) failureLine(app, result, scope.report?.takeIf { it.first == io.github.nanomuse.routines.RunOutcome.FAILURE }?.second, reason)
                    else produced.text.orEmpty()
                val firstFailure = (ScheduledTaskStore(app).get(task.id)?.consecutiveFailures ?: 0) == 0
                val made = io.github.nanomuse.routines.ScheduledResultNotifier.decide(app, task, produced, failedOutcome, firstFailure, task.debug || dryNotify)
                decision = made
                val preview = (if (failedOutcome) null else produced.text)?.take(200)
                    ?: result.responseText.orEmpty().take(200).ifBlank { "(no response)" }
                val details = runDetails(task, slot, result).put("result", produced.text?.take(io.github.nanomuse.routines.ScheduledResult.MAX_CHARS) ?: org.json.JSONObject.NULL)
                    .put("result_source", produced.source).put("result_bytes", produced.bytes).put("result_hash", produced.hash ?: org.json.JSONObject.NULL)
                    .put("result_truncated", (produced.text?.length ?: 0) > io.github.nanomuse.routines.ScheduledResult.MAX_CHARS || result.scriptOutput?.truncated == true)
                    .put("trace_chars", result.scriptOutput?.let { it.stdout.length + it.stderrTail.length } ?: result.responseText?.length ?: 0)
                    .put("debug", task.debug).put("dry_notify", dryNotify)
                made.write(details)
                try { val settled = ScheduledTaskManager(app).markFired(task.id, sessionId.takeUnless { sessionless }, preview, ok = !failedOutcome,
                    scheduledForMs = slot, startedAtMs = scope.startedAtMs, durationMs = (System.nanoTime() - scope.monotonicStart) / 1_000_000,
                    status = when { cancelled -> "aborted"; result.status == "CompletedEmpty" && task.requireOutput -> "empty_output_failed"; result.status == "CompletedEmpty" -> "CompletedEmpty"; result.timedOut -> "timed_out";
                        outcome == io.github.nanomuse.routines.RunOutcome.UNKNOWN -> "completed_unknown";
                        outcome == io.github.nanomuse.routines.RunOutcome.FAILURE -> "execution_failed"; else -> "succeeded" },
                    exitCode = result.exitCode, runId = scope.runId, outcome = outcome.wire, reason = reason, details = details, debug = task.debug)
                    stateWriteError = settled?.runtime?.logWriteError == true
                    canonicalSettled = true
                } catch (_: Exception) { stateWriteError = true }
                finally { if (canonicalSettled) runCatching { io.github.nanomuse.routines.RoutineHeartbeat.finish(app, task.id, slot) }
                    .onFailure { stateWriteError = true } } // nanoMuse: 已结算时间槽由持久终态兜底，不因诊断错误重放。
                // nanoMuse: 一次运行最多一条通知；动态任务的帖子由动态页自己告知。
                val feedTold = !(failedOutcome || task.debug || dryNotify) && io.github.nanomuse.feed.FeedFlow.notifyIfFeed(app, task)
                if (!feedTold) io.github.nanomuse.routines.ScheduledResultNotifier.deliver(app, task,
                    if (failedOutcome) app.getString(R.string.nm_sched_result_failed, title) else title, body,
                    if (failedOutcome) io.github.nanomuse.routines.ScheduledResult(body, "").hash else produced.hash, made,
                    sessionId.takeUnless { sessionless || failedOutcome }) // Mosaic: 结果通知点开进任务的对话，失败通知进运行记录。
            }
            callback?.invoke(io.github.nanomuse.routines.ScheduledCompletion(outcome, result.exitCode,
                when { outcome == io.github.nanomuse.routines.RunOutcome.UNKNOWN -> "CompletedUnknown"
                    outcome == io.github.nanomuse.routines.RunOutcome.FAILURE && result.status in setOf("Completed", "CompletedEmpty") -> "Failed"
                    else -> result.status }, scope.runId, stateWriteError,
                sessionId = sessionId.takeUnless { sessionless }, result = produced, notify = decision))
        } finally {
            if (entered) {
                io.github.nanomuse.routines.ScheduledRunScopes.leave(sessionId, scope)
                io.github.nanomuse.chat.SessionAddenda.remove(sessionId, "scheduled-report:${scope.runId}")
                withContext(kotlinx.coroutines.NonCancellable + Dispatchers.Main) {
                    com.openminis.app.ui.chat.ChatViewModelStore.existingViewModel(sessionId)?.nmResumeAfterTask()
                }
            }
        }
        if (cancelled) throw kotlinx.coroutines.CancellationException("Scheduled run aborted")
    }

    private fun runDetails(task: ScheduledTask, slot: Long?, result: HeadlessChatRunner.PromptResult?): org.json.JSONObject {
        val output = result?.scriptOutput
        return org.json.JSONObject().put("label", task.label).put("trigger", if (slot == null) "manual" else "schedule")
            .put("mode", if (task.scriptId == null) "prompt" else "script").put("script_id", task.scriptId ?: org.json.JSONObject.NULL)
            .put("script_args", org.json.JSONArray(task.scriptArgs)).put("stdout_bytes", output?.stdoutBytes ?: org.json.JSONObject.NULL)
            .put("stdout_sha256", output?.stdoutSha256 ?: org.json.JSONObject.NULL)
            .put("stderr_tail", output?.stderrTail.orEmpty()).put("message_text_bytes", result?.messageTextBytes ?: 0)
            .put("stderr_bytes_total", output?.stderrBytes ?: org.json.JSONObject.NULL) // Mosaic
            .put("stderr_truncated_from_head", output != null && output.stderrBytes > output.stderrTail.toByteArray(Charsets.UTF_8).size)
            .put("stdout_truncated", output?.truncated ?: false)
            .put("capture_error", output?.captureError ?: org.json.JSONObject.NULL)
            .put("capture_available", output != null)
            .put("error", if (result == null) "PREFLIGHT_FAILED" else if (result.responseText == "MESSAGE_WRITE_FAILED") "MESSAGE_WRITE_FAILED"
                else if (result.status == "Error") "EXECUTION_FAILED" else org.json.JSONObject.NULL)
            .apply { if (task.logStdout && output != null) put("stdout", output.stdout) }
    }

    private suspend fun resolveSessionId(app: MinisApp, task: ScheduledTask, scope: io.github.nanomuse.routines.ScheduledRunScope): String? {
        return when (val mode = task.targetMode) {
            is ScheduledTargetMode.AppendToSession -> {
                // Follow-up: the target session must still exist. If the user
                // deleted it, abort rather than silently spawning a new chat.
                if (app.chatRepository.getSession(mode.sessionId) == null) {
                    AppLogger.warning(TAG, "task ${task.id}: follow-up session ${mode.sessionId} gone — abort")
                    null
                } else {
                    mode.sessionId
                }
            }
            is ScheduledTargetMode.RerunMessage -> {
                if (app.chatRepository.getSession(mode.sessionId) == null) {
                    AppLogger.warning(TAG, "task ${task.id}: re-run session ${mode.sessionId} gone — abort")
                    null
                } else {
                    mode.sessionId
                }
            }
            ScheduledTargetMode.NewSession -> {
                // Mosaic: 每个任务固定一个对话：第一次运行时建，之后每次都写进去；删掉它，下次运行再建一个。
                // 任务改了模型时，对话跟着换绑定，和过去每次新建对话时一样用任务当前的模型。
                app.chatRepository.dao.latestSessionOfTask(task.id)?.let { bound ->
                    task.modelBinding?.takeIf { it != bound.modelBinding }?.let { app.chatRepository.updateSessionBinding(bound.id, it, bound.modelId) }
                    return bound.id
                }
                // Resolution priority (mirrors the UI's normal-chat boot):
                //   1. task.modelBinding (user picked a group or specific entry
                //      on the task editor) → write it through verbatim so the
                //      new session lights up the same group/entry chip.
                //   2. legacy task.modelId (pre-binding, kept for backcompat) →
                //      pin to that entry, no binding.
                //   3. default primary group → write a group binding so the
                //      session boots through the user's default group.
                //   4. first visible entry → last-resort fallback.
                val explicitBinding = task.modelBinding
                val pinnedModelId = task.modelId
                val defaultGroupId =
                    if (explicitBinding == null && pinnedModelId == null) {
                        app.providerRepository.defaultPrimaryGroupId
                    } else null

                // Derive the seed modelId for the session row (must be valid
                // even before restoreFromBinding runs).
                val seedModelId: String = (if (task.scriptId != null) "scheduled-script" else pinnedModelId)
                    ?: run {
                        // Try to peek a member from whichever binding we'll
                        // write — explicit takes priority, then default group.
                        val groupIdForSeed: String? = explicitBinding
                            ?.let { parseGroupIdFromBinding(it) }
                            ?: defaultGroupId
                        val entryIdForSeed: String? = explicitBinding
                            ?.let { parseEntryIdFromBinding(it) }

                        // Entry binding → use that entry's model id.
                        entryIdForSeed
                            ?.let { eid -> app.providerRepository.config.value.modelEntries.firstOrNull { it.id == eid }?.model?.id }
                            ?: groupIdForSeed
                                ?.let { gid -> app.providerRepository.group(gid) }
                                // [T-android-group-resolve-skip-uncredentialed]
                                // Credential-aware filter — a scheduled run
                                // seeded with an uncredentialed member would
                                // fail unattended, with no user around to see
                                // the auth error.
                                ?.let { g -> app.providerRepository.availableMemberEntries(g).firstOrNull()?.model?.id }
                    }
                    ?: app.providerRepository.allVisibleEntries().firstOrNull()?.baseModel?.id
                    ?: run {
                        AppLogger.warning(TAG, "task ${task.id}: no provider — abort")
                        return null
                    }
                // Mosaic: 专属对话以任务名为题，不再带每次运行的时间。
                val title = task.label.ifBlank { "Scheduled task" }
                val memoryOn = com.openminis.app.data.MemoryGlobalPrefs.isGlobalEnabled(app)
                val session = app.chatRepository.createSession(
                    modelId = seedModelId,
                    title = title,
                    memoryEnabled = memoryOn,
                    source = "scheduled", taskId = task.id, runId = scope.runId, // nanoMuse: 创建来源随会话原子落盘。
                    scheduledGroup = ScheduledTaskStore(app).get(task.id)?.takeIf {
                        io.github.nanomuse.routines.ScheduledConversationGroup.isUserTask(it) || it.debug // nanoMuse: 调试运行的会话同样不进主列表。
                    }?.let { io.github.nanomuse.routines.ScheduledConversationGroup.folder() },
                )

                // Write a model_binding when the task carried one OR when we
                // fell back to defaultPrimaryGroupId. Pinned modelId (no
                // binding) leaves modelBinding null so the chat layer treats
                // it as a hard-pinned entry, matching what the user picked.
                val bindingToWrite: String? = explicitBinding
                    ?: defaultGroupId?.let { """{"type":"group","groupId":"$it"}""" }
                if (bindingToWrite != null) {
                    app.chatRepository.updateSessionBinding(session.id, bindingToWrite, seedModelId)
                }
                session.id
            }
        }
    }

    // Mirrors ChatViewModel.restoreFromBinding's JSON shape. Robust against
    // malformed JSON — both parsers return null and the caller fall-backs.
    private fun parseGroupIdFromBinding(json: String): String? = runCatching {
        val o = org.json.JSONObject(json)
        if (o.optString("type") == "group") {
            o.optString("groupId").takeIf { it.isNotEmpty() }
        } else null
    }.getOrNull()

    private fun parseEntryIdFromBinding(json: String): String? = runCatching {
        val o = org.json.JSONObject(json)
        if (o.optString("type") == "entry") {
            o.optString("entryId").takeIf { it.isNotEmpty() }
        } else null
    }.getOrNull()

    // nanoMuse: 失败通知的正文，截 120 字。Mosaic: 明确上报的失败原因优先，其次是错误输出的最后一行
    // （Python 等的异常在末尾），脚本没有错误输出时写退出码，最后才是内部原因。
    private fun failureLine(app: MinisApp, result: HeadlessChatRunner.PromptResult, reported: String?, reason: String?): String =
        (reported ?: result.scriptOutput?.let { output -> output.stderrTail.lines().lastOrNull { it.isNotBlank() }?.trim()
            ?: app.getString(R.string.nm_sched_run_no_stderr, output.exitCode).takeUnless { output.exitCode == 124 } }
            ?: reason ?: result.responseText.orEmpty())
            .take(120).ifBlank { "(no response)" }

    private fun recordStartFailure(app: MinisApp, task: ScheduledTask, slot: Long?, reason: String, scope: io.github.nanomuse.routines.ScheduledRunScope): Boolean { // nanoMuse: 没有创建会话也留下失败记录，元数据异常不吞掉运行回执。
        val decision = io.github.nanomuse.routines.ScheduledResultNotifier.decide(app, task, io.github.nanomuse.routines.ScheduledResult(null, "none"),
            failed = true, firstFailure = task.consecutiveFailures == 0, debug = task.debug) // nanoMuse: 与正常结算同一套通知决定。
        val failed = runCatching {
            ScheduledTaskManager(app).markFired(task.id, null, reason, ok = false, scheduledForMs = slot, status = "preflight_failed",
                runId = scope.runId, startedAtMs = scope.startedAtMs, reason = reason, details = decision.write(runDetails(task, slot, null)), debug = task.debug)
        }.onFailure { AppLogger.warning(TAG, "preflight state write failed for task=${task.id}") }.isFailure
        if (!failed) io.github.nanomuse.routines.RoutineHeartbeat.finish(app, task.id, slot) // nanoMuse: 未提交的主结算不丢弃恢复身份。
        val title = task.notifyTitle ?: task.label.ifBlank { "Scheduled task" }
        io.github.nanomuse.routines.ScheduledResultNotifier.deliver(app, task, app.getString(R.string.nm_sched_result_failed, title),
            reason.take(120), io.github.nanomuse.routines.ScheduledResult(reason, "").hash, decision)
        return failed
    }

    // nanoMuse: 提示词任务的输出约定。最终回复就是通知正文，过程说明不进通知。
    private const val OUTPUT_CONTRACT = "This is a scheduled task. Your final reply is shown to the user as the notification body, " +
        "so write only the result they need, in the language of the task. Do not describe what you did or how, do not mention run ids, " +
        "task ids or report status, and do not write lines such as \"done\", \"reported\" or \"the task finished\". " +
        "If there is nothing worth showing, reply with exactly NO_OUTPUT. If the result is longer than 500 characters, keep only the 5 most important lines. " +
        "After the requested work, report a verified outcome with minis-scheduled report --status success or --status failure --reason TEXT, " +
        "and you may hand over the result text itself with --result TEXT (it then replaces your final reply as the notification body). " +
        "Do not claim success without evidence. If the outcome cannot be verified, leave the status unreported. " +
        "Never print task environment variables or runtime tokens."
}
