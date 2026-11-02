package io.github.nanomuse.routines

import android.content.Context
import com.openminis.app.sandbox.ExecutionCoordinator
import com.openminis.app.sandbox.PRootKernel
import kotlinx.coroutines.*
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.File
import java.security.MessageDigest
import java.time.ZoneId
import java.util.concurrent.TimeUnit

/** 捕获原始输出计量，与最终写入消息的字节数分别保存。 */
data class ScheduledProcessResult(
    val stdout: String, val stdoutBytes: Long, val stdoutSha256: String,
    val stderrTail: String, val exitCode: Int, val truncated: Boolean,
    val captureError: String? = null,
    val stderrBytes: Long = 0, // Mosaic: 脚本自己写进stderr的总字节数，不含proot退出时的泄漏报告。
)

/** 显式脚本用独立argv进程执行，同时排空stdout和stderr，取消时终止进程。 */
object ScheduledProcess {
    /** 校验参数边界，空格、引号、分号等均为字面值。 */
    fun validateArguments(arguments: List<String>) {
        require(arguments.size <= 16 && arguments.all { '\u0000' !in it && it.toByteArray(Charsets.UTF_8).size <= 256 }) { "SCRIPT_ARG_INVALID" }
    }

    /** 构造解释器参数，不经过sh-c或字符串拼接解析。 */
    fun argv(script: String, arguments: List<String>): List<String> {
        require(Regex("[A-Za-z0-9][A-Za-z0-9_.-]{0,79}").matches(script) && ".." !in script && (script.endsWith(".sh") || script.endsWith(".py"))) { "SCRIPT_PATH_INVALID" }
        validateArguments(arguments)
        return listOf(if (script.endsWith(".py")) "/usr/bin/python3" else "/bin/sh", "/var/minis/home/bin/$script") + arguments
    }

    /** 继承沙盒挂载、代理和加载器，只在本进程设置本次任务环境。 */
    suspend fun execute(context: Context, sessionId: String, script: String, arguments: List<String>,
        scope: ScheduledRunScope, trigger: String, timeoutMs: Long, scriptVersion: ByteArray): ScheduledProcessResult = withContext(Dispatchers.IO) {
        if (!PRootKernel.isBooted) PRootKernel.boot(context)
        val mounts = ExecutionCoordinator.sessionMounts(sessionId).toMutableMap()
        ScheduledTimezone.prepare(context)?.let { mounts["/usr/share/zoneinfo"] = it.absolutePath }
        val snapshot = File.createTempFile("scheduled-script-", if (script.endsWith(".py")) ".py" else ".sh", context.cacheDir)
        try {
        snapshot.writeBytes(scriptVersion)
        snapshot.setReadable(false, false); snapshot.setReadable(true, true); snapshot.setWritable(false, false)
        mounts["/var/minis/home/bin/$script"] = snapshot.absolutePath // nanoMuse: 审批与执行使用同一版本。
        val command = PRootKernel.buildProotArgv(argv(script, arguments), mounts)
        val builder = ProcessBuilder(command).redirectErrorStream(false)
        builder.environment().apply {
            putAll(PRootKernel.customEnvironment)
            putAll(ExecutionCoordinator.envVarRepository?.allAsDict().orEmpty())
            put("PROOT_TMP_DIR", PRootKernel.getProotTmpDir(context).absolutePath)
            if (PRootKernel.nativeLibDir.isNotEmpty()) put("LD_LIBRARY_PATH", PRootKernel.nativeLibDir)
            if (PRootKernel.prootLoaderPath.isNotEmpty()) put("PROOT_LOADER", PRootKernel.prootLoaderPath)
            if (PRootKernel.prootLoader32Path.isNotEmpty()) put("PROOT_LOADER_32", PRootKernel.prootLoader32Path)
            putAll(scope.environment())
            put("MINIS_CHAT_SESSION_ID", sessionId); put("MINIS_TRIGGER", trigger)
            put("TZ", ZoneId.systemDefault().id)
        }
        capture(builder, timeoutMs) { process -> scope.registerProcess(ScheduledProcessIdentity.pid(process)) }
        } finally { snapshot.setWritable(true, true); snapshot.delete() }
    }

    /** 独立的可测试进程捕获入口，退出后读到EOF才形成最终结果。 */
    internal suspend fun capture(builder: ProcessBuilder, timeoutMs: Long, onStarted: (Process) -> Unit = {}): ScheduledProcessResult {
        var acquired = false
        val drainedReaders = java.util.concurrent.CountDownLatch(2)
        var submitted = 0
        try {
        val available = withTimeoutOrNull(timeoutMs) { permits.acquire(); acquired = true; true } ?: false
        if (!available) return ScheduledProcessResult("", 0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "", 4, false, "OUTPUT_CAPACITY_BUSY")
        return withContext(Dispatchers.IO) {
        var process: Process? = null
        val stdout = Capture(false)
        val stderr = Capture(true)
        var outputReader: java.util.concurrent.Future<*>? = null
        var errorReader: java.util.concurrent.Future<*>? = null
        try {
            val child = builder.start()
            process = child
            child.outputStream.close()
            onStarted(child)
            outputReader = readers.submit { try { collect(child.inputStream, stdout) } finally { drainedReaders.countDown() } }
            submitted++
            errorReader = readers.submit { try { collect(child.errorStream, stderr) } finally { drainedReaders.countDown() } }
            submitted++
            val outputFuture = outputReader
            val errorFuture = errorReader
            val deadline = System.nanoTime() + timeoutMs * 1_000_000
            var exited = false
            while (!exited && System.nanoTime() < deadline) {
                currentCoroutineContext().ensureActive()
                exited = child.waitFor(50, TimeUnit.MILLISECONDS)
            }
            if (!exited) child.destroyForcibly()
            val drained = withTimeoutOrNull(5000) {
                while (!outputFuture.isDone || !errorFuture.isDone) delay(20)
                true
            } ?: false
            val readFailed = drained && runCatching { outputFuture.get(); errorFuture.get() }.isFailure
            val output = stdout.finish()
            val errors = stderr.finish()
            ScheduledProcessResult(output.text, output.count, output.hash, errors.text,
                if (exited && drained && !readFailed) child.exitValue() else 124, output.count > MAX_CAPTURE,
                if (!drained) "OUTPUT_DRAIN_TIMEOUT" else if (readFailed) "OUTPUT_READ_FAILED" else null, errors.count)
        } finally {
            process?.destroyForcibly()
            stdout.finish(); stderr.finish()
            process?.let { child -> runCatching { cleaners.execute { runCatching { child.inputStream.close() }; runCatching { child.errorStream.close() } } } }
        }
        }
        } finally {
            repeat(2 - submitted) { drainedReaders.countDown() }
            if (acquired && drainedReaders.count == 0L) permits.release()
            else if (acquired) Thread({ drainedReaders.await(); permits.release() }, "scheduled-output-release").apply { isDaemon = true; start() }
        }
    }

    private data class Snapshot(val text: String, val count: Long, val hash: String)
    private class Capture(private val tail: Boolean) {
        val digest = MessageDigest.getInstance("SHA-256")
        val bytes = ByteArrayOutputStream()
        var count = 0L
        private var snapshot: Snapshot? = null
        private var leakReport = false
        @Synchronized fun add(buffer: ByteArray, size: Int) {
            if (snapshot != null || leakReport) return
            if (!tail) {
                count += size; digest.update(buffer, 0, size)
                if (bytes.size() < MAX_CAPTURE) bytes.write(buffer, 0, minOf(size, MAX_CAPTURE - bytes.size()))
                return
            }
            // Mosaic: proot退出时talloc把泄漏报告写进同一根stderr，几KB就挤满了尾部窗口；
            // 从它固定的首行起不再是脚本的输出，不计数也不保留。
            val combined = bytes.toByteArray() + buffer.copyOf(size)
            val from = (combined.size - size - LEAK_REPORT.length).coerceAtLeast(0)
            val found = String(combined, from, combined.size - from, Charsets.ISO_8859_1).indexOf(LEAK_REPORT)
            var kept = combined.size
            if (found >= 0) {
                kept = from + found
                if (kept >= 5 && String(combined, kept - 5, 5, Charsets.ISO_8859_1) == "full ") kept -= 5
                leakReport = true
            }
            count += size - (combined.size - kept)
            bytes.reset(); bytes.write(combined, (kept - STDERR_WINDOW).coerceAtLeast(0), minOf(kept, STDERR_WINDOW))
        }
        @Synchronized fun finish(): Snapshot = snapshot ?: run {
            var raw = bytes.toByteArray()
            if (tail && raw.size > STDERR_TAIL) {
                // Mosaic: 尾部从行首开始，不留半行或半个UTF-8字符。
                val start = raw.size - STDERR_TAIL
                val newline = (start - 1 until raw.size - 1).firstOrNull { raw[it] == '\n'.code.toByte() }
                raw = raw.copyOfRange(newline?.plus(1)
                    ?: (start until raw.size).firstOrNull { raw[it].toInt() and 0xC0 != 0x80 } ?: raw.size, raw.size)
            }
            Snapshot(raw.toString(Charsets.UTF_8), count, digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) })
        }.also { snapshot = it }
    }
    private fun collect(input: InputStream, capture: Capture) {
        input.use { stream ->
            val buffer = ByteArray(8192)
            while (true) {
                val size = stream.read(buffer)
                if (size < 0) break
                capture.add(buffer, size)
            }
        }
    }
    private fun executor(size: Int) = java.util.concurrent.ThreadPoolExecutor(size, size, 30, TimeUnit.SECONDS,
        java.util.concurrent.ArrayBlockingQueue<Runnable>(32), java.util.concurrent.ThreadFactory { operation ->
            Thread(operation, "scheduled-output").apply { isDaemon = true }
        }).apply { allowCoreThreadTimeOut(true) }
    private val readers = executor(8)
    private val cleaners = executor(2)
    private val permits = kotlinx.coroutines.sync.Semaphore(4)
    private const val MAX_CAPTURE = 128 * 1024
    private const val STDERR_WINDOW = 64 * 1024
    private const val STDERR_TAIL = 2048
    // talloc_report的首行（deps/talloc/talloc.c），proot以talloc_enable_leak_report在退出时打印。
    private const val LEAK_REPORT = "talloc report on 'null_context' (total "
}
