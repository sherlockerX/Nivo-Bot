package io.github.nanomuse.chat

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.openminis.app.ui.chat.InputAttachment
import com.openminis.app.ui.sandbox.FileItem
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 在隔离设备验证真实粘贴文件与发送策略；不调用模型，也不替代ChatScreen点击测试。 */
@RunWith(AndroidJUnit4::class)
class PasteRecoveryInstrumentedTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var directory: File
    private lateinit var writerScope: CoroutineScope

    /** 每次测试使用专属缓存目录和写入任务。 */
    @Before
    fun prepare() {
        check(context.packageName.endsWith(".uitest"))
        directory = File(context.cacheDir, "paste-recovery-${UUID.randomUUID()}")
        check(directory.mkdirs())
        writerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }

    /** 只清理本测试目录，禁止接触正式应用或其他测试的数据。 */
    @After
    fun cleanup() {
        if (::writerScope.isInitialized) writerScope.cancel()
        if (::directory.isInitialized) {
            check(directory.canonicalPath.startsWith(context.cacheDir.canonicalPath + File.separator))
            directory.deleteRecursively()
        }
    }

    /** 点击预览所依赖的awaitReady必须等待完整大文件，并让主线程继续执行。 */
    @Test
    fun should_previewCompleteLargePaste_when_openedBeforeWriteFinishes() = runBlocking {
        val text = "合成大段粘贴：保留完整头尾。\n".repeat(80_000)
        val firstHalfWritten = CountDownLatch(1)
        val finishWrite = CountDownLatch(1)
        try {
            val paste = PendingPasteFile(writerScope, File(directory, "large.txt"), text) { file, content ->
                file.outputStream().use { output ->
                    val bytes = content.toByteArray(Charsets.UTF_8)
                    val half = bytes.size / 2
                    output.write(bytes, 0, half)
                    output.flush()
                    firstHalfWritten.countDown()
                    check(finishWrite.await(10, TimeUnit.SECONDS))
                    output.write(bytes, half, bytes.size - half)
                }
            }
            assertTrue(firstHalfWritten.await(10, TimeUnit.SECONDS))
            val preview = async(Dispatchers.Main, start = CoroutineStart.UNDISPATCHED) {
                withContext(Dispatchers.IO) {
                    val ready = paste.awaitReady()
                    FileItem(ready, ready.name, false, false, ready.length(), ready.lastModified())
                }
            }
            withTimeout(5_000) { withContext(Dispatchers.Main) { assertFalse(preview.isCompleted) } }
            finishWrite.countDown()
            val item = withTimeout(10_000) { preview.await() }
            assertEquals(text.toByteArray(Charsets.UTF_8).size.toLong(), item.size)
            assertEquals(text, withContext(Dispatchers.IO) { item.file.readText() })
        } finally {
            finishWrite.countDown()
        }
    }

    /** 真实写入失败后保留原附件与新草稿，重试读取同一个完整文件。 */
    @Test
    fun should_keepBothDraftsAndRetryOriginalFile_when_pasteWriteFails() = runBlocking {
        val attempts = AtomicInteger()
        val text = "失败原稿的合成粘贴。\n".repeat(20_000)
        val paste = PendingPasteFile(writerScope, File(directory, "retry.txt"), text) { file, content ->
            if (attempts.incrementAndGet() == 1) throw IOException("synthetic write failure")
            file.writeText(content)
        }
        val failed = attachment("failed", paste)
        val newer = failed.copy(id = "newer", fileName = "newer.txt", pendingPaste = null)
        assertTrue(runCatching { paste.awaitReady() }.exceptionOrNull() is IOException)
        val restored = withContext(Dispatchers.Main) {
            assertEquals("失败原稿\n\n新草稿", restoreFailedText("失败原稿", "新草稿"))
            restoreFailedAttachments(listOf(failed), listOf(newer)) { it.id }
        }
        assertEquals(listOf("failed", "newer"), restored.map { it.id })
        assertSame(paste, restored.first().pendingPaste)
        val ready = withTimeout(10_000) { restored.first().pendingPaste!!.awaitReady() }
        assertEquals(text, withContext(Dispatchers.IO) { ready.readText() })
        assertEquals(2, attempts.get())
    }

    /** 写入失败时不丢新入队内容；撤回项保持撤回，重试只提交现有ID。 */
    @Test
    fun should_keepQueueAndHonorWithdrawal_when_realPasteWaitFailsThenRetries() = runBlocking {
        val enteredWrite = CountDownLatch(1)
        val failWrite = CountDownLatch(1)
        val attempts = AtomicInteger()
        val text = "排队附件合成正文。\n".repeat(20_000)
        try {
            val paste = PendingPasteFile(writerScope, File(directory, "queued.txt"), text) { file, content ->
                if (attempts.incrementAndGet() == 1) {
                    enteredWrite.countDown()
                    check(failWrite.await(10, TimeUnit.SECONDS))
                    throw IOException("synthetic write failure")
                }
                file.writeText(content)
            }
            val first = attachment("first", paste)
            val withdrawn = first.copy(id = "withdrawn", pendingPaste = null)
            val newer = first.copy(id = "newer", pendingPaste = null)
            var queue = listOf(first, withdrawn)
            val committed = mutableListOf<String>()
            val preparing = CompletableDeferred<Unit>()
            suspend fun commitCurrent(): List<InputAttachment>? = commitPreparedQueue(
                readQueue = { queue }, id = { it.id },
                prepare = { batch ->
                    preparing.complete(Unit)
                    batch.forEach { it.pendingPaste?.awaitReady() }
                    batch
                },
                onCommitting = {},
                commit = { batch, prepared ->
                    assertEquals(batch, prepared)
                    committed += batch.map { it.id }
                    val ids = batch.map { it.id }.toSet()
                    queue = queue.filterNot { it.id in ids }
                    batch
                },
                onRollback = {},
            )
            assertTrue(enteredWrite.await(10, TimeUnit.SECONDS))
            val firstSend = async(Dispatchers.Main) { runCatching { commitCurrent() } }
            withTimeout(5_000) { preparing.await() }
            withContext(Dispatchers.Main) { queue = listOf(first, newer) }
            failWrite.countDown()
            assertTrue(withTimeout(10_000) { firstSend.await() }.exceptionOrNull() is IOException)
            withContext(Dispatchers.Main) {
                assertEquals(listOf("first", "newer"), queue.map { it.id })
                assertSame(paste, queue.first().pendingPaste)
                assertTrue(committed.isEmpty())
            }
            withTimeout(10_000) { commitCurrent() }
            assertEquals(listOf("first", "newer"), committed)
            assertTrue(queue.isEmpty())
            assertEquals(text, withContext(Dispatchers.IO) { paste.file.readText() })
        } finally {
            failWrite.countDown()
        }
    }

    private fun attachment(id: String, paste: PendingPasteFile): InputAttachment = InputAttachment(
        id = id, fileName = paste.file.name, uri = Uri.fromFile(paste.file),
        mimeType = "text/plain", kind = InputAttachment.Kind.DOCUMENT, pendingPaste = paste,
    )
}
