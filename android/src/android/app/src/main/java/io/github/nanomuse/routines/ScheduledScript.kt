package io.github.nanomuse.routines

import android.content.Context
import com.openminis.app.sandbox.RootfsManager
import com.openminis.app.scheduled.ScheduledTask
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** 仅执行持久home/bin中的显式脚本，不从自然语言猜测路径。 */
object ScheduledScript {
    /** 检查文件、类型和解释器，不执行脚本或请求模型。 */
    fun probe(context: Context, task: ScheduledTask): JSONObject {
        val script = task.scriptId
        val reasons = mutableListOf<String>()
        if (script == null) {
            val app = context.applicationContext as? com.openminis.app.MinisApp
            if (app == null || !app.subsystemsReady()) reasons.add("APP_NOT_READY")
            else if (app.providerRepository.config.value.instances.none { it.isEnabled && app.providerRepository.hasAnyCredential(it) }) reasons.add("MODEL_CREDENTIALS_REQUIRED")
        }
        if (script != null) {
            val valid = runCatching { ScheduledProcess.argv(script, task.scriptArgs) }.isSuccess
            if (!valid) reasons.add(if (runCatching { ScheduledProcess.validateArguments(task.scriptArgs) }.isFailure) "SCRIPT_ARG_INVALID" else "SCRIPT_PATH_INVALID")
            if (valid) {
                val base = File(File(context.filesDir, "minis-global/home").canonicalFile, "bin").absoluteFile
                val file = File(base, script).canonicalFile
                if (base.canonicalFile != base || file.parentFile != base) reasons.add("SCRIPT_PATH_INVALID")
                else if (!file.isFile || !file.canRead()) reasons.add("SCRIPT_NOT_FOUND")
                if (file.isFile && file.length() > 65_536) reasons.add("SCRIPT_TOO_LARGE")
                val rootfs = RootfsManager.getInstance(context).rootfsDir
                if (!ScheduledTimezone.available(context)) reasons.add("TIMEZONE_DATA_UNAVAILABLE") // nanoMuse: 不让IANA名称在缺少数据的镜像中静默变成UTC。
                val interpreter = if (script.endsWith(".py")) "usr/bin/python3" else "bin/sh"
                if (!io.github.nanomuse.sandbox.GuestExecutable.isPresent(rootfs, interpreter)) reasons.add("INTERPRETER_UNAVAILABLE")
            }
        }
        return JSONObject().put("can_run", reasons.isEmpty()).put("reasons", JSONArray(reasons))
            .put("mode", if (script == null) "agent" else "script").put("script_id", script ?: JSONObject.NULL)
            .put("script_args", JSONArray(task.scriptArgs))
            .put("network_checked", false).put("checked_at_ms", System.currentTimeMillis())
    }

    /** 返回固定解释器命令，文件名已由预检限定为安全字符。 */
    fun command(scriptId: String, arguments: List<String> = emptyList()): String {
        require(Regex("[A-Za-z0-9][A-Za-z0-9_.-]{0,79}").matches(scriptId))
        ScheduledProcess.argv(scriptId, arguments)
        val interpreter = if (scriptId.endsWith(".py")) "python3" else "/bin/sh"
        return "$interpreter '/var/minis/home/bin/$scriptId'" + arguments.joinToString("", transform = { " '" + it.replace("'", "'\\''") + "'" })
    }

    /** 有界读取经过目录验证的版本，审批期间文件变化不改变本次执行内容。 */
    fun readVersion(context: Context, scriptId: String): ByteArray {
        ScheduledProcess.argv(scriptId, emptyList())
        val base = File(File(context.filesDir, "minis-global/home").canonicalFile, "bin").absoluteFile
        require(base.canonicalFile == base) { "SCRIPT_PATH_INVALID" }
        val source = File(base, scriptId).canonicalFile
        require(source.parentFile == base && source.isFile) { "SCRIPT_PATH_INVALID" }
        return java.nio.file.Files.newInputStream(source.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS).use { input ->
            val output = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val size = input.read(buffer)
                if (size < 0) break
                require(output.size() + size <= 65_536) { "SCRIPT_TOO_LARGE" }
                output.write(buffer, 0, size)
            }
            require(base.canonicalFile == base && source.canonicalFile.parentFile == base) { "SCRIPT_PATH_INVALID" }
            output.toByteArray()
        }
    }

    /** 评估脚本正文而非只评估解释器文件名，正文不进入审批预览或日志。 */
    fun assessment(scriptId: String, body: String): io.github.nanomuse.guard.RiskAssessment {
        val quoted = "'" + body.replace("'", "'\\''") + "'"
        val inline = if (scriptId.endsWith(".py")) "python3 -c $quoted" else "sh -c $quoted"
        return io.github.nanomuse.guard.ShellGuard.assess(inline)
    }
}
