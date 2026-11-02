package com.openminis.app.sandbox.offload

import android.content.Context
import com.openminis.app.logging.AppLogger
import com.openminis.app.sandbox.NativeOffloadHandler
import com.openminis.app.sandbox.NativeOffloadRequest
import com.openminis.app.sandbox.NativeOffloadResult
import com.openminis.app.scheduled.ScheduledRepeatMode
import com.openminis.app.scheduled.ScheduledTargetMode
import com.openminis.app.scheduled.ScheduledTask
import com.openminis.app.scheduled.ScheduledTaskManager
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

/**
 * [T-android-scheduled-tasks-full] minis-scheduled — CLI surface for the
 * Scheduled Tasks feature, exposing the same option set as the editor UI and
 * the iOS Shortcuts intents so the agent can create / inspect / fire timed
 * AI actions from a prompt.
 *
 *   minis-scheduled list
 *   minis-scheduled create --label L --time HH:MM [--time HH:MM ...] --prompt "..."
 *                          [--repeat once|daily|weekdays|custom --days mon,tue,...]
 *                          [--target new|follow-up|rerun]
 *                          [--session <id>] [--message <id>]
 *                          [--model <modelId>]
 *                          [--start YYYY-MM-DD] [--end YYYY-MM-DD]
 *                          [--disabled]
 *   minis-scheduled delete --id <taskId>
 *   minis-scheduled enable  --id <taskId>
 *   minis-scheduled disable --id <taskId>
 *   minis-scheduled run     --id <taskId>     (fire immediately, off-schedule)
 *
 * Target modes mirror iOS App Intents:
 *   new        ≈ SendPrompt(no session)   — run prompt in a fresh chat
 *   follow-up  ≈ FollowUpSession           — append prompt to --session
 *   rerun      ≈ RetryRun                  — re-run --session from --message
 */
class ScheduledTaskOffloadHandler(private val context: Context) : NativeOffloadHandler {

    private val manager get() = ScheduledTaskManager(context)

    override fun handle(request: NativeOffloadRequest): NativeOffloadResult {
        val args = OffloadArgs(
            request.argv.drop(1),
            booleanFlags = setOf("disabled", "h", "help", "auto-disable-on-failure", "log-stdout", "require-output",
                "debug", "session-output", "silent", "dry-notify"), // nanoMuse
            literalValueFlags = setOf("script-arg"),
        )
        // [T-offload-defaults-batch-android] Help only on explicit
        // --help/-h; no subcommand defaults to `list`.
        if (args.hasFlag("h", "help")) {
            return NativeOffloadResult(0, HELP)
        }
        return try {
            when (val sub = args.positional.firstOrNull() ?: "list") {
                "list" -> handleList()
                "create", "add" -> handleCreate(args)
                "delete", "remove", "rm" -> handleDelete(args)
                "enable" -> handleSetEnabled(args, true)
                "disable" -> handleSetEnabled(args, false)
                "run" -> handleRun(args)
                "report" -> { // nanoMuse: 只接受仍在本次任务上下文中的上报；--result 交出通知正文。
                    NativeOffloadResult(0, io.github.nanomuse.routines.ScheduledRunScopes.report(request.sessionId, request.env,
                        args.get("status"), args.get("reason"), request.peerPid, args.get("result")))
                }
                "update" -> handleUpdate(args) // nanoMuse
                "settings" -> { // nanoMuse: 全局静音时段。
                    args.get("quiet-hours")?.let { io.github.nanomuse.routines.ScheduledResultNotifier.setQuietHours(context, it) }
                    NativeOffloadResult(0, JSONObject().put("quiet_hours", io.github.nanomuse.routines.ScheduledResultNotifier.quietHours(context)).toString())
                }
                "logs" -> { // nanoMuse: 查询主机落盘日志，不通过Shell读取或执行脚本。
                    val format = args.get("format") ?: "json"
                    require(format in setOf("json", "text")) { "INVALID_FORMAT" }
                    val last = args.get("last")?.let { it.toIntOrNull() ?: throw IllegalArgumentException("INVALID_LIMIT") } ?: 20
                    val result = io.github.nanomuse.routines.ScheduledRunRecorder.journal(context).query(
                        requireNotNull(args.get("id")) { "--id required" }, last, args.get("since"))
                    val text = "status: ${result.getString("status")}\nqueried: ${result.getJSONObject("queried")}\n" +
                        result.optJSONArray("runs")?.let { rows -> (0 until rows.length()).joinToString("\n") { index ->
                            val row = rows.getJSONObject(index)
                            "${row.optLong("started_at_ms")} ${row.optString("outcome")} exit=${row.opt("exit_code")} run=${row.optString("run_id")}"
                        } }.orEmpty()
                    NativeOffloadResult(0, if (format == "text") text else result.toString())
                }
                "probe" -> { // nanoMuse: 无副作用预检。
                    val task = requireNotNull(manager.get(requireNotNull(args.get("id")) { "--id required" })) { "Task not found" }
                    val result = io.github.nanomuse.routines.ScheduledScript.probe(context, task)
                    NativeOffloadResult(if (result.getBoolean("can_run")) 0 else 4, result.toString())
                }
                else -> NativeOffloadResult(2, "minis-scheduled: unknown subcommand '$sub'\n$HELP")
            }
        } catch (e: IllegalArgumentException) {
            NativeOffloadResult(2, "minis-scheduled: ${e.message}")
        } catch (e: Throwable) {
            AppLogger.warning(TAG, "handle failed: ${e.message}")
            NativeOffloadResult(1, "minis-scheduled: ${e.message}")
        }
    }

    private fun handleList(): NativeOffloadResult {
        val arr = JSONArray()
        for (t in manager.list()) arr.put(taskJson(t))
        val out = JSONObject().put("tasks", arr).put("count", arr.length())
        return NativeOffloadResult(0, out.toString(2))
    }

    private fun handleCreate(args: OffloadArgs): NativeOffloadResult {
        val label = args.get("label", "l") ?: ""
        // nanoMuse: [GH#557] --time may repeat: the first value is the
        // task's primary time, the rest become its additional times.
        val times = args.getAll("time", "t").map { parseTime(it) }
        if (times.isEmpty()) throw IllegalArgumentException("--time HH:MM required")
        val (hour, minute) = times.first()
        val repeat = parseRepeat(args.get("repeat", "r"))
        val customDays = if (repeat == ScheduledRepeatMode.CUSTOM) {
            parseDays(args.get("days") ?: throw IllegalArgumentException("--days required for custom repeat"))
        } else emptySet()
        val target = parseTarget(args)
        val prompt = args.get("prompt", "p") ?: ""
        if (target !is ScheduledTargetMode.RerunMessage && prompt.isBlank() && args.get("script") == null) {
            throw IllegalArgumentException("--prompt required (except for rerun target)")
        }
        val task = ScheduledTask(
            label = label,
            timeOfDayHour = hour,
            timeOfDayMinute = minute,
            // nanoMuse: [GH#557]
            additionalTimes = times.drop(1),
            repeatMode = repeat,
            customDays = customDays,
            prompt = prompt,
            targetMode = target,
            modelId = args.get("model", "m"),
            enabled = !args.hasFlag("disabled"),
            startDateMs = args.get("start")?.let { parseDate(it) },
            endDateMs = args.get("end")?.let { parseDate(it) },
            scriptId = args.get("script"), autoDisableOnFailure = args.hasFlag("auto-disable-on-failure"), // nanoMuse
            scriptArgs = args.getAll("script-arg"), requireOutput = args.hasFlag("require-output"), logStdout = args.hasFlag("log-stdout"), origin = "user_cli",
            notifyPolicy = parsePolicy(args.get("notify")) ?: "on_change", notifyTitle = args.get("notify-title")?.takeIf { it.isNotBlank() }, // nanoMuse
            notifySilent = args.hasFlag("silent"), sessionOutput = args.hasFlag("session-output"), debug = args.hasFlag("debug"),
        )
        task.scriptId?.let { io.github.nanomuse.routines.ScheduledProcess.argv(it, task.scriptArgs) } // nanoMuse: 即使禁用保存也校验参数。
        require(!args.hasFlag("script-arg")) { "SCRIPT_ARG_INVALID" }
        require(task.scriptId != null || task.scriptArgs.isEmpty()) { "SCRIPT_ARG_INVALID" }
        if (task.enabled && task.scriptId != null) require(io.github.nanomuse.routines.ScheduledScript.probe(context, task).getBoolean("can_run")) { "Script preflight failed; use probe or save --disabled" }
        manager.create(task)
        val out = JSONObject().put("created", taskJson(task))
        if (task.scriptId == null && Regex("(?i)(\\bexec\\b|\\bpython[23]?\\s+|\\b(?:sh|bash)\\s+|\\.(?:py|sh)\\b)").containsMatchIn(prompt)) // nanoMuse: 仅建议，不猜测脚本或阻止提示词任务。
            out.put("advice", "This task appears to run a script; use --script for exit-code and failure detection.")
        return NativeOffloadResult(0, out.toString(2))
    }

    private fun handleDelete(args: OffloadArgs): NativeOffloadResult {
        val id = args.get("id") ?: throw IllegalArgumentException("--id required")
        if (manager.get(id) == null) return NativeOffloadResult(1, "minis-scheduled: no task with id=$id")
        manager.delete(id)
        return NativeOffloadResult(0, JSONObject().put("deleted", id).toString())
    }

    private fun handleSetEnabled(args: OffloadArgs, enabled: Boolean): NativeOffloadResult {
        val id = args.get("id") ?: throw IllegalArgumentException("--id required")
        if (manager.get(id) == null) return NativeOffloadResult(1, "minis-scheduled: no task with id=$id")
        manager.setEnabled(id, enabled)
        return NativeOffloadResult(0, JSONObject().put("id", id).put("enabled", enabled).toString())
    }

    private fun handleRun(args: OffloadArgs): NativeOffloadResult {
        val id = args.get("id") ?: throw IllegalArgumentException("--id required")
        val task = manager.get(id) ?: return NativeOffloadResult(1, "minis-scheduled: no task with id=$id")
        // Fire immediately, off-schedule. Blocks until the agent loop finishes
        // (ScheduledAgentRunner waits internally). Mirrors the editor "Run now".
        var resultCode = 1 // nanoMuse: 取得会话ID只代表启动，不代表脚本成功。
        var resultStatus = "start_failed"
        var actualExitCode: Int? = null // nanoMuse: CLI退出码与脚本真实退出码分开。
        var receipt: io.github.nanomuse.routines.ScheduledCompletion? = null
        val dryNotify = args.hasFlag("dry-notify") // nanoMuse: 执行并记录，但不推送。
        val started = runBlocking {
            com.openminis.app.scheduled.ScheduledAgentRunner.run(context, task, onResult = { result ->
                receipt = result
                resultCode = result.cliExitCode()
                resultStatus = result.status
                actualExitCode = result.exitCode
            }, dryNotify = dryNotify)
        }
        val produced = receipt?.result
        val out = JSONObject()
            .put("id", id)
            .put("ran", started != null)
            .put("status", resultStatus).put("exit_code", actualExitCode ?: JSONObject.NULL)
            .put("outcome", receipt?.outcome?.wire ?: "failure").put("run_id", receipt?.runId ?: JSONObject.NULL)
            .put("state_write_error", receipt?.stateWriteError ?: false) // nanoMuse: 全部来自本轮，不重读共享last状态。
            .put("sessionId", receipt?.sessionId ?: JSONObject.NULL) // nanoMuse: 不建会话的脚本运行为 null。
            .put("result_source", produced?.source ?: "none")
            .put(if (task.debug || dryNotify) "result" else "result_preview", // nanoMuse: 调试运行把结果直接交给命令行。
                produced?.text?.let { if (task.debug || dryNotify) it else it.take(200) } ?: JSONObject.NULL)
            .put("log_path", "/var/minis/home/logs/scheduled/$id/")
        receipt?.notify?.write(out)
        return NativeOffloadResult(resultCode, out.toString(2))
    }

    // nanoMuse: 修改已有任务的通知与会话设置，不改计划，不重排闹钟。
    private fun handleUpdate(args: OffloadArgs): NativeOffloadResult {
        val id = args.get("id") ?: throw IllegalArgumentException("--id required")
        val policy = parsePolicy(args.get("notify"))
        fun toggle(name: String): Boolean? = args.getBool(name) ?: if (args.hasFlag(name)) true else null
        val updated = manager.store().mutate(id) { task ->
            task.copy(notifyPolicy = policy ?: task.notifyPolicy,
                notifyTitle = args.get("notify-title")?.let { it.ifBlank { null } } ?: task.notifyTitle,
                notifySilent = toggle("silent") ?: task.notifySilent, sessionOutput = toggle("session-output") ?: task.sessionOutput,
                debug = toggle("debug") ?: task.debug)
        } ?: return NativeOffloadResult(1, "minis-scheduled: no task with id=$id")
        return NativeOffloadResult(0, JSONObject().put("updated", taskJson(updated)).toString(2))
    }

    private fun parsePolicy(value: String?): String? = value?.lowercase()?.also {
        require(it in io.github.nanomuse.routines.ScheduledResultNotifier.POLICIES) { "--notify must be always|on_change|on_failure|never" }
    }

    // ── parsing helpers ──

    private fun parseTime(s: String): Pair<Int, Int> {
        val parts = s.split(":")
        require(parts.size == 2) { "--time must be HH:MM" }
        val h = parts[0].toIntOrNull()?.takeIf { it in 0..23 }
            ?: throw IllegalArgumentException("bad hour in --time")
        val m = parts[1].toIntOrNull()?.takeIf { it in 0..59 }
            ?: throw IllegalArgumentException("bad minute in --time")
        return h to m
    }

    private fun parseRepeat(s: String?): ScheduledRepeatMode = when (s?.lowercase()) {
        null, "once" -> ScheduledRepeatMode.ONCE
        "daily" -> ScheduledRepeatMode.DAILY
        "weekdays" -> ScheduledRepeatMode.WEEKDAYS
        "custom" -> ScheduledRepeatMode.CUSTOM
        else -> throw IllegalArgumentException("--repeat must be once|daily|weekdays|custom")
    }

    private fun parseDays(s: String): Set<Int> {
        val map = mapOf(
            "sun" to Calendar.SUNDAY, "mon" to Calendar.MONDAY, "tue" to Calendar.TUESDAY,
            "wed" to Calendar.WEDNESDAY, "thu" to Calendar.THURSDAY, "fri" to Calendar.FRIDAY,
            "sat" to Calendar.SATURDAY,
        )
        return s.split(",").mapNotNull { map[it.trim().lowercase().take(3)] }.toSet()
    }

    private fun parseTarget(args: OffloadArgs): ScheduledTargetMode {
        return when (args.get("target")?.lowercase() ?: "new") {
            "new" -> ScheduledTargetMode.NewSession
            "follow-up", "followup", "follow" -> {
                val sid = args.get("session", "s")
                    ?: throw IllegalArgumentException("--session required for follow-up target")
                ScheduledTargetMode.AppendToSession(sid)
            }
            "rerun", "re-run", "retry" -> {
                val sid = args.get("session", "s")
                    ?: throw IllegalArgumentException("--session required for rerun target")
                val mid = args.get("message")
                    ?: throw IllegalArgumentException("--message required for rerun target")
                ScheduledTargetMode.RerunMessage(sid, mid)
            }
            else -> throw IllegalArgumentException("--target must be new|follow-up|rerun")
        }
    }

    /** YYYY-MM-DD → local start-of-day epoch ms. */
    private fun parseDate(s: String): Long {
        val parts = s.split("-")
        require(parts.size == 3) { "--start/--end must be YYYY-MM-DD" }
        val y = parts[0].toInt(); val mo = parts[1].toInt(); val d = parts[2].toInt()
        return Calendar.getInstance().apply {
            clear(); set(y, mo - 1, d, 0, 0, 0)
        }.timeInMillis
    }

    private fun taskJson(t: ScheduledTask): JSONObject = JSONObject().apply {
        put("id", t.id)
        put("label", t.label)
        // nanoMuse: [GH#557] one time prints as "time", several as "times".
        val taskTimes = t.timesOfDay
        if (taskTimes.size > 1) {
            put("times", JSONArray().apply {
                taskTimes.forEach { (h, m) -> put("%02d:%02d".format(h, m)) }
            })
        } else {
            put("time", "%02d:%02d".format(t.timeOfDayHour, t.timeOfDayMinute))
        }
        put("repeat", t.repeatMode.name.lowercase())
        if (t.customDays.isNotEmpty()) put("days", JSONArray(t.customDays.toList()))
        put("prompt", t.prompt)
        put("target", t.targetMode.encode())
        if (t.modelId != null) put("model", t.modelId)
        put("enabled", t.enabled)
        put("script_id", t.scriptId ?: JSONObject.NULL) // nanoMuse: CLI可检查脚本类型和连续失败策略。
        put("script_args", JSONArray(t.scriptArgs)).put("require_output", t.requireOutput).put("log_stdout", t.logStdout).put("origin", t.origin) // nanoMuse
        val state = io.github.nanomuse.routines.ScheduledRunRecorder.state(t)
        state.keys().forEach { key -> put(key, state.get(key)) }
        put("outcome_kind", if (t.scriptId == null) "self_report" else "exit_code")
        put("consecutive_failures", t.consecutiveFailures).put("total_failures", t.totalFailures)
        put("auto_disable_on_failure", t.autoDisableOnFailure).put("failure_threshold", t.failureThreshold)
        put("notify_policy", t.notifyPolicy).put("notify_title", t.notifyTitle ?: JSONObject.NULL).put("silent", t.notifySilent) // nanoMuse
        put("session_output", t.sessionOutput).put("debug", t.debug)
        t.nextTriggerMs()?.let { put("nextTriggerMs", it) }
        if (t.startDateMs != null) put("startDateMs", t.startDateMs)
        if (t.endDateMs != null) put("endDateMs", t.endDateMs)
        if (t.lastFiredAt != null) put("lastFiredAt", t.lastFiredAt)
        if (t.lastResultPreview != null) put("lastResultPreview", t.lastResultPreview)
        if (t.lastResultSessionId != null) put("lastResultSessionId", t.lastResultSessionId)
    }

    companion object {
        private const val TAG = "ScheduledTaskOffload"
        private val HELP = """
            minis-scheduled — manage timed AI tasks (mirrors the in-app Scheduled Tasks).

            (no subcommand)  Same as `list` (default subcommand)
            list
            create --time HH:MM [--time HH:MM ...] [--prompt "..." | --script NAME.sh] [--label L]
                   [--repeat once|daily|weekdays|custom --days mon,tue,...]
                   [--target new|follow-up|rerun --session <id> --message <id>]
                   [--model <modelId>] [--start YYYY-MM-DD] [--end YYYY-MM-DD] [--disabled]
            delete  --id <taskId>
            enable  --id <taskId>
            disable --id <taskId>
            run     --id <taskId> [--dry-notify]   fire immediately, off-schedule; --dry-notify runs and logs without notifying
            probe   --id <taskId>          inspect script/interpreter or model credentials without running
            report  [--status success|failure [--reason TEXT]] [--result TEXT]  report from the current task run;
                    --result hands over the text shown as the notification body; in a script run it takes
                    precedence over stdout, and report prints nothing (exit 0 means it was accepted)
            logs    --id <taskId> [--last N] [--since YYYY-MM-DD] [--format json|text]
            update  --id <taskId> [--notify P] [--notify-title T] [--silent=true|false] [--session-output=true|false] [--debug=true|false]
            settings [--quiet-hours HH:MM-HH:MM|off]   notifications arrive silently in these hours (default 01:00-08:00)
            Script options: --script-arg VALUE (repeatable, max 16), --require-output, --log-stdout.
            Notification options: --notify always|on_change|on_failure|never (default on_change: an unchanged
            result within 6 hours is not sent again), --notify-title T, --silent (no sound).
            Each task keeps one chat of its own under Scheduled tasks, made on its first run; every run, script
            or prompt, adds its result there (--session-output is still accepted and changes nothing).
            --debug: no notification, no chat for script runs, failures not counted.

            One run sends at most one notification, and each task keeps at most one in the shade.
            For prompt tasks the final reply is the notification body: reply NO_OUTPUT when there is nothing to show.

            Scripts live in /var/minis/home/bin and may be .sh or .py. Their actual
            exit code is returned by run. Failures only warn by default; create
            with --auto-disable-on-failure to opt in to pausing after repeated failures.

            A task may fire at several times of day: repeat --time on create to
            add more. list prints them as "times"; a task with one time keeps
            printing it as "time".

            Target modes: new = run prompt in a fresh chat; follow-up = append prompt
            to an existing chat (--session); rerun = re-run a chat (--session) from a
            chosen user message (--message, prompt ignored).
        """.trimIndent()
    }
}
