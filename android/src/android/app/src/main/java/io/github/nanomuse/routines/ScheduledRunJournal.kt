package io.github.nanomuse.routines

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardOpenOption.*
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

/** 本地有界运行日志与原子状态投影，不默认保存输出正文。 */
class ScheduledRunJournal(home: File) {
    private val root = home.canonicalFile

    /** 启动和心跳也轮转历史任务日志，任务已删除时不依赖下一次业务运行。 */
    fun maintain() = synchronized(LOCK) {
        child("logs/scheduled").listFiles().orEmpty().filter { file ->
            Regex("[A-Za-z0-9_-]{1,80}").matches(file.name) && file.canonicalFile == file.absoluteFile && file.isDirectory
        }.forEach(::rotate)
    }

    /** 业务完成后先保存结算收据，主状态失败时只重试结算，不重执行业务。 */
    fun stageSettlement(receipt: JSONObject) = synchronized(LOCK) {
        val run = receipt.getJSONObject("run")
        safeId(receipt.getString("task_id"))
        directory("state/scheduled/settlements")
        atomicWrite(child("state/scheduled/settlements/${run.getLong("firedAt")}-${safeId(run.getString("runId"))}.json"), receipt.toString())
    }

    /** 启动与心跳读取未完成收据，不将其当作新的业务任务。 */
    fun settlements(): List<JSONObject> = synchronized(LOCK) {
        child("state/scheduled/settlements").listFiles().orEmpty().filter(::validPending).sortedBy { it.name }
            .map { require(it.length() <= MAX_BYTES); JSONObject(readText(it)) }
    }

    /** 主状态已持久化后才移除同一运行的收据。 */
    fun clearSettlement(run: com.openminis.app.scheduled.ScheduledRun) = synchronized(LOCK) {
        val file = child("state/scheduled/settlements/${run.firedAt}-${safeId(requireNotNull(run.runId))}.json")
        check(!file.exists() || file.delete()) { "SETTLEMENT_DELETE_FAILED" }
    }

    /** 日志和状态写失败向调用方报告，不自行改变任务结果。 */
    fun write(taskId: String, run: JSONObject, state: JSONObject?) = synchronized(LOCK) {
        safeId(taskId)
        var failure: Exception? = null
        val queued = runCatching {
            val pending = directory("state/scheduled/pending/$taskId")
            val name = "${run.getLong("started_at_ms")}-${safeId(run.getString("run_id"))}.json"
            atomicWrite(child("state/scheduled/pending/$taskId/$name"), run.toString())
            rotatePending(pending)
            pending.listFiles().orEmpty().filter(::validPending).sortedBy { it.name }
        }.getOrElse { failure = it as? Exception ?: IllegalStateException("PENDING_LOG_WRITE_FAILED"); emptyList() }
        try {
            val records = queued.map { file -> require(file.length() <= MAX_BYTES); JSONObject(readText(file)) } + run
            appendRuns(taskId, records)
            queued.forEach { check(it.delete()) { "PENDING_LOG_DELETE_FAILED" } }
        } catch (error: Exception) { failure = error }
        if (state != null) {
            try {
                directory("state/scheduled")
                atomicWrite(child("state/scheduled/$taskId.json"), JSONObject(state.toString())
                    .put("log_write_error", failure != null).toString())
            } catch (error: Exception) { failure = error }
        }
        failure?.let { throw it }
    }

    private fun appendRuns(taskId: String, records: List<JSONObject>) {
        val directory = directory("logs/scheduled/$taskId")
        records.groupBy { Instant.ofEpochMilli(it.getLong("started_at_ms")).atZone(ZONE).toLocalDate() }.forEach { (date, rows) ->
            val file = child("logs/scheduled/$taskId/$date.jsonl")
            val known = if (file.isFile) withLines(file) { lines -> lines.mapNotNull {
                runCatching { JSONObject(it).optString("run_id") }.getOrNull()
            }.toMutableSet() } else mutableSetOf()
            FileChannel.open(file.toPath(), CREATE, READ, WRITE, NOFOLLOW_LINKS).use { output ->
                privateMode(file, false)
                val size = output.size()
                if (size > 0) {
                    val last = ByteBuffer.allocate(1)
                    output.read(last, size - 1)
                    output.position(size)
                    if (last.array()[0] != 10.toByte()) writeBytes(output, byteArrayOf(10))
                }
                rows.forEach { row -> if (known.add(row.getString("run_id"))) writeBytes(output, (row.toString() + "\n").toByteArray(Charsets.UTF_8)) }
                output.force(true)
            }
        }
        rotate(directory)
    }

    private fun validPending(file: File) = file.isFile && file.canonicalFile == file.absoluteFile &&
        Regex("\\d+-[A-Za-z0-9_-]+\\.json").matches(file.name)

    private fun rotatePending(directory: File) {
        val cutoff = System.currentTimeMillis() - 30L * 24 * 60 * 60 * 1000
        directory.listFiles().orEmpty().filter(::validPending).filter { it.name.substringBefore('-').toLongOrNull()?.let { time -> time < cutoff } == true }
            .forEach { check(it.delete()) { "PENDING_ROTATE_FAILED" } }
        val files = directory.listFiles().orEmpty().filter(::validPending).sortedBy { it.name }.toMutableList()
        while (files.size > 1 && files.sumOf { it.length() } > MAX_BYTES) check(files.removeAt(0).delete()) { "PENDING_ROTATE_FAILED" }
    }

    /** 删除任务仅移除状态文件，保留运行日志等待轮转。 */
    fun deleteState(taskId: String) = synchronized(LOCK) {
        val file = child("state/scheduled/${safeId(taskId)}.json")
        check(!file.exists() || file.delete()) { "STATE_DELETE_FAILED" }
    }

    /** 返回明确的空查询窗口，不把没有记录表现为接口失败。 */
    fun query(taskId: String, last: Int = 20, since: String? = null): JSONObject = synchronized(LOCK) {
        safeId(taskId)
        require(last in 1..1000) { "INVALID_LIMIT" }
        val start = since?.let { value -> runCatching { LocalDate.parse(value) }.getOrElse { throw IllegalArgumentException("INVALID_DATE") } }
        val files = child("logs/scheduled/$taskId").listFiles().orEmpty()
            .filter { validLog(it) && (start == null || it.name.substring(0, 10) >= start.toString()) }.sortedBy { it.name }
        val records = ArrayDeque<JSONObject>()
        files.forEach { file -> withLines(file) { lines -> lines.forEach { line ->
            runCatching { JSONObject(line) }.getOrNull()?.let { record ->
                records.addLast(record)
                if (records.size > last) records.removeFirst()
            }
        } } }
        JSONObject().put("status", if (records.isEmpty()) "empty" else "ok")
            .put("queried", JSONObject().put("task_id", taskId).put("last", last).put("since", since ?: JSONObject.NULL))
            .apply { if (records.isNotEmpty()) put("runs", JSONArray(records.toList())) }
    }

    /** 升级前保存一次原始任务数据，既有备份不覆盖。 */
    fun backupTasks(raw: String) = synchronized(LOCK) {
        directory("state/backup/${LocalDate.now(ZONE)}")
        val file = child("state/backup/${LocalDate.now(ZONE)}/scheduled-before-v2.json")
        if (!file.exists()) atomicWrite(file, raw)
    }

    /** 分组迁移前完整备份会话与分组元数据，不复制消息正文。 */
    fun backupGroups(raw: String) = synchronized(LOCK) {
        directory("state/backup/${LocalDate.now(ZONE)}")
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(raw.toByteArray(Charsets.UTF_8))
            .take(8).joinToString("") { "%02x".format(it.toInt() and 255) }
        val file = child("state/backup/${LocalDate.now(ZONE)}/groups-before-v13-$digest.json")
        if (!file.exists()) atomicWrite(file, raw)
    }

    /** 本地保留重名改名映射，以便用户核对和恢复。 */
    fun groupMigrationReport(report: JSONObject) = synchronized(LOCK) {
        directory("state")
        atomicWrite(child("state/group-name-migration-v13.json"), report.toString())
    }

    private fun rotate(directory: File) {
        val cutoff = LocalDate.now(ZONE).minusDays(29).toString()
        directory.listFiles().orEmpty().filter(::validLog).filter { it.name.substring(0, 10) < cutoff }
            .forEach { check(it.delete()) { "LOG_ROTATE_FAILED" } }
        val files = directory.listFiles().orEmpty().filter(::validLog).sortedBy { it.name }.toMutableList()
        while (files.size > 1 && files.sumOf { it.length() } > MAX_BYTES) {
            check(files.removeAt(0).delete()) { "LOG_ROTATE_FAILED" }
        }
        files.singleOrNull()?.takeIf { it.length() > MAX_BYTES }?.let { file ->
            val tail = ArrayDeque<String>()
            var bytes = 0
            withLines(file) { lines -> lines.forEach { line ->
                tail.addLast(line)
                bytes += line.toByteArray(Charsets.UTF_8).size + 1
                while (bytes > MAX_BYTES && tail.isNotEmpty()) bytes -= tail.removeFirst().toByteArray(Charsets.UTF_8).size + 1
            } }
            atomicWrite(file, tail.joinToString("\n", postfix = if (tail.isEmpty()) "" else "\n"))
        }
    }

    private fun validLog(file: File) = file.isFile && file.canonicalFile == file.absoluteFile && Regex("\\d{4}-\\d{2}-\\d{2}\\.jsonl").matches(file.name)
    private fun safeId(id: String): String = id.also { require(Regex("[A-Za-z0-9_-]{1,80}").matches(it)) { "INVALID_TASK_ID" } }
    private fun child(path: String): File = File(root, path).absoluteFile.also {
        require(it.canonicalFile == it && it.toPath().startsWith(root.toPath()) && it != root) { "INVALID_LOG_PATH" }
    }
    private fun directory(path: String): File = child(path).also {
        check(it.isDirectory || it.mkdirs()) { "DIRECTORY_CREATE_FAILED" }
        var current: File? = it
        while (current != null && current.toPath().startsWith(root.toPath())) {
            privateMode(current, true)
            if (current == root) break
            current = current.parentFile
        }
    }
    private fun atomicWrite(file: File, value: String) {
        val temporary = File(file.parentFile, ".${file.name}.${UUID.randomUUID()}.tmp")
        try {
            FileChannel.open(temporary.toPath(), CREATE_NEW, WRITE, NOFOLLOW_LINKS).use {
                privateMode(temporary, false)
                writeBytes(it, value.toByteArray(Charsets.UTF_8)); it.force(true)
            }
            java.nio.file.Files.move(temporary.toPath(), file.toPath(), java.nio.file.StandardCopyOption.ATOMIC_MOVE,
                java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        } finally { temporary.delete() }
    }
    private fun privateMode(file: File, directory: Boolean) {
        require(!Files.isSymbolicLink(file.toPath())) { "INVALID_LOG_PATH" }
        val attributes = Files.getFileAttributeView(file.toPath(), java.nio.file.attribute.PosixFileAttributeView::class.java, NOFOLLOW_LINKS)
        if (attributes != null) {
            attributes.setPermissions(java.nio.file.attribute.PosixFilePermissions.fromString(if (directory) "rwx------" else "rw-------"))
            return
        }
        file.setReadable(false, false); file.setWritable(false, false); file.setExecutable(false, false)
        file.setReadable(true, true); file.setWritable(true, true)
        if (directory) file.setExecutable(true, true)
    }
    private fun writeBytes(channel: FileChannel, bytes: ByteArray) {
        val buffer = ByteBuffer.wrap(bytes)
        while (buffer.hasRemaining()) channel.write(buffer)
    }
    private fun readText(file: File) = Files.newInputStream(file.toPath(), NOFOLLOW_LINKS).bufferedReader(Charsets.UTF_8).use { it.readText() }
    private fun <Result> withLines(file: File, block: (Sequence<String>) -> Result): Result =
        Files.newInputStream(file.toPath(), NOFOLLOW_LINKS).bufferedReader(Charsets.UTF_8).useLines(block)
    companion object {
        private val LOCK = Any()
        private val ZONE = ZoneId.of("Asia/Shanghai")
        private const val MAX_BYTES = 5L * 1024 * 1024
    }
}
