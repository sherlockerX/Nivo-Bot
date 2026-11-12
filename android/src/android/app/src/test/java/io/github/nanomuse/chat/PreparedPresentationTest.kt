package io.github.nanomuse.chat

import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

/** 配色切换必须重新后台准备，旧结果不能冒充新内容。 */
class PreparedPresentationTest {
    @Test fun should_prepareOnWorker_when_structureAlreadyCached() = runBlocking {
        val callerThread = Thread.currentThread()
        val workerThread = AtomicReference<Thread>()
        Executors.newSingleThreadExecutor { task ->
            Thread(task, "presentation-worker").also { workerThread.set(it) }
        }
            .asCoroutineDispatcher().use { worker ->
                val cachedStructure = listOf("paragraph")
                val dark = preparePresentation("body" to "dark", worker) {
                    // 协程调试模式会改线程名，实际工作线程身份不变。
                    assertSame(workerThread.get(), Thread.currentThread())
                    assertNotSame(callerThread, Thread.currentThread())
                    cachedStructure.associateWith { "dark:$it" }
                }
                val light = preparePresentation("body" to "light", worker) {
                    assertSame(workerThread.get(), Thread.currentThread())
                    assertNotSame(callerThread, Thread.currentThread())
                    cachedStructure.associateWith { "light:$it" }
                }
                assertNull(dark.forKey("body" to "light"))
                assertEquals("light:paragraph", light.forKey("body" to "light")!!["paragraph"])
            }
    }

    @Test fun should_hideOldResult_when_contentOrOwnerChanges() {
        val value = PreparedPresentation("A" to "url1", "old-image")
        assertNull(value.forKey("B" to "url1"))
        assertNull(value.forKey("A" to "url2"))
        assertEquals("old-image", value.forKey("A" to "url1"))
    }
}
