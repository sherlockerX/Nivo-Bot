package io.github.nanomuse.focus.lock

import android.content.Context
import android.os.SystemClock
import android.util.AtomicFile
import io.github.nanomuse.account.AccountData
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/** 有界本地诊断仅记录固定动作、时刻、包名和窗口类型，不上传。 */
object LockDiagnostics {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private val buffers = mutableMapOf<String, LockDiagnosticBuffer>()

    /** 回调只投递固定元数据，磁盘读写留在IO线程。 */
    fun record(context: Context, action: LockDiagnosticAction, packageName: String? = null, windowType: Int? = null) {
        val owner = AccountData.key(context)
        val epoch = AccountData.epoch.value
        val entry = LockDiagnosticEntry(System.currentTimeMillis(), SystemClock.elapsedRealtime(), action, packageName, windowType)
        scope.launch {
            runCatching { AccountData.withTodoOwnerMutation(owner, epoch) { mutex.withLock {
                val buffer = buffer(context, owner)
                buffer.append(entry)
                write(context, owner, encode(buffer))
            } } }
        }
    }

    /** 仅空闲时允许复制诊断，避免操作设置成为锁定通道。 */
    suspend fun exportText(context: Context): String {
        val store = LockStore.get(context)
        return withContext(Dispatchers.IO) { store.transaction {
            check(store.checkpointInTransaction() == null) { "focus_locked" }
            mutex.withLock { encode(buffer(context, store.ownerKey)) }
        } }
    }

    /** 清理当前账号诊断，不影响运行账本与其他账号。 */
    suspend fun clear(context: Context) {
        val store = LockStore.get(context)
        withContext(Dispatchers.IO) { store.transaction {
            check(store.checkpointInTransaction() == null) { "focus_locked" }
            deleteOwner(context, store.ownerKey)
        } }
    }

    /** 已持账号边界时删除指定账号的诊断，旧异步任务不能在迁移后重新写回。 */
    internal suspend fun deleteOwner(context: Context, owner: String) = mutex.withLock {
        buffers.remove(owner); storage(context, owner).delete()
    }

    private fun storage(context: Context, owner: String): AtomicFile {
        val hash = MessageDigest.getInstance("SHA-256").digest(owner.toByteArray()).joinToString("") { "%02x".format(it) }
        return AtomicFile(File(context.noBackupFilesDir, "focus-lock-$hash.jsonl"))
    }

    private fun buffer(context: Context, owner: String): LockDiagnosticBuffer = buffers.getOrPut(owner) {
        val result = LockDiagnosticBuffer()
        runCatching { storage(context, owner).openRead().use { input ->
            val bytes = ByteArray(65_537)
            var length = 0
            while (length < bytes.size) {
                val count = input.read(bytes, length, bytes.size - length)
                if (count < 0) break
                length += count
            }
            if (length <= 65_536) String(bytes, 0, length, Charsets.UTF_8).lineSequence().forEach { line ->
                runCatching {
                    val json = JSONObject(line)
                    result.append(LockDiagnosticEntry(json.getLong("wall"), json.getLong("elapsed"),
                        LockDiagnosticAction.valueOf(json.getString("action")),
                        json.optString("package").takeIf { it.isNotEmpty() },
                        json.optInt("window", -1).takeIf { it >= 0 }, json.optInt("count", 1).coerceAtLeast(1)))
                }
            }
        } }
        result
    }

    private fun encode(buffer: LockDiagnosticBuffer): String {
        val lines = buffer.entries().map { row -> JSONObject().put("wall", row.wall).put("elapsed", row.elapsed)
            .put("action", row.action.name).put("package", row.packageName ?: "")
            .put("window", row.windowType ?: -1).put("count", row.count).toString() }.toMutableList()
        while (lines.joinToString("\n").toByteArray().size > 65_536) lines.removeAt(0)
        return lines.joinToString("\n")
    }

    private fun write(context: Context, owner: String, text: String) {
        val file = storage(context, owner)
        val output = file.startWrite()
        try { output.write(text.toByteArray()); file.finishWrite(output) }
        catch (failure: Exception) { file.failWrite(output); throw failure }
    }
}
