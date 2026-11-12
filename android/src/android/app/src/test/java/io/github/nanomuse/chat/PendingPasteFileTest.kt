package io.github.nanomuse.chat

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

/** 用可控写入验证输入不会同步阻塞、发送不会读到半个附件、取消不丢失原文。 */
class PendingPasteFileTest {
    @Test fun should_waitForCompleteFileOffCaller_when_sendingImmediately() = runBlocking {
        val caller = Thread.currentThread()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        try {
            val paste = PendingPasteFile(scope, File("unused"), "合成内容") { _, text ->
                assertNotSame(caller, Thread.currentThread())
                assertEquals("合成内容", text)
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
            }
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val first = async(start = CoroutineStart.UNDISPATCHED) { paste.awaitReady() }
            assertFalse(first.isCompleted)
            first.cancelAndJoin()
            release.countDown()
            assertEquals(File("unused"), paste.awaitReady())
        } finally { release.countDown(); scope.cancel() }
    }

    @Test fun should_keepOriginalForRetry_when_writeFails() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        var attempts = 0
        try {
            val paste = PendingPasteFile(scope, File("unused"), "完整原文") { _, text ->
                assertEquals("完整原文", text)
                if (++attempts == 1) throw java.io.IOException("synthetic full disk")
            }
            assertTrue(runCatching { paste.awaitReady() }.isFailure)
            assertEquals(File("unused"), paste.awaitReady())
            assertEquals(2, attempts)
        } finally { scope.cancel() }
    }
}
