package io.github.nanomuse.chat

import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** 大段粘贴先出现附件卡片，实际文件在后台准备；发送前等待同一份完整结果。 */
class PendingPasteFile(
    private val scope: CoroutineScope = FILE_WRITER_SCOPE,
    val file: File,
    text: String,
    private val write: (File, String) -> Unit = { target, content ->
        check(target.parentFile?.let { it.isDirectory || it.mkdirs() } == true)
        target.writeText(content)
    },
) {
    companion object {
        // 附件可移到另一个聊天，短暂文件写入不随原ViewModel清理而取消。
        private val FILE_WRITER_SCOPE = CoroutineScope(kotlinx.coroutines.SupervisorJob() + Dispatchers.IO)
    }
    private var content: String? = text
    private val mutex = Mutex()
    private var attempt: Deferred<Result<File>> = start()

    /** 准备失败保留原文，下一次发送可以重试，取消发送不取消附件准备。 */
    suspend fun awaitReady(): File = mutex.withLock {
        val current = attempt.await()
        if (current.isSuccess) return@withLock current.getOrThrow()
        attempt = start()
        throw current.exceptionOrNull()!!
    }

    private fun start(): Deferred<Result<File>> = scope.async(Dispatchers.IO) {
        try {
            content?.let { write(file, it) }
            content = null
            Result.success(file)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            Result.failure(failure)
        }
    }
}
