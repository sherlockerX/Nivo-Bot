package io.github.nanomuse.account

import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

/** 用本地夹具和受控交错验证旧聊天不能触碰下一账号的固定目录。 */
class AccountOperationGateTest {
    @Test fun should_rejectOldMemoryReadAndWrite_when_fixedDirectoryChangesOwner() {
        val gate = AccountOperationGate()
        val operation = gate.capture()
        val directory = Files.createTempDirectory("account-memory-fixture").toFile()
        val memory = directory.resolve("GLOBAL.md")
        try {
            operation.files { memory.writeText("account-a") }
            gate.beginTransition()
            memory.writeText("account-b")
            gate.finishTransition()
            assertTrue(runCatching { operation.files { memory.readText() } }.isFailure)
            assertTrue(runCatching { operation.files { memory.writeText("stale") } }.isFailure)
            assertEquals("account-b", gate.capture().files { memory.readText() })
        } finally {
            memory.delete()
            directory.delete()
        }
    }

    @Test fun should_closeAndCancelBeforeDraining_when_oldFileOperationIsRunning() {
        val gate = AccountOperationGate()
        val operation = gate.capture()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val invalidated = CountDownLatch(1)
        val didMoveFiles = AtomicBoolean(false)
        val didFinishWrite = AtomicBoolean(false)
        operation.onInvalidated { invalidated.countDown() }
        val writer = thread {
            operation.files {
                entered.countDown()
                check(release.await(15, TimeUnit.SECONDS))
                didFinishWrite.set(true)
            }
        }
        var migration: Thread? = null
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            migration = thread {
                gate.beginTransition()
                didMoveFiles.set(true)
                gate.finishTransition()
            }
            assertTrue(invalidated.await(5, TimeUnit.SECONDS))
            assertFalse(operation.isCurrent())
            assertFalse(didMoveFiles.get())
        } finally {
            release.countDown()
            writer.join(5_000)
            migration?.join(5_000)
        }
        assertTrue(didFinishWrite.get())
        assertTrue(didMoveFiles.get())
    }

    @Test fun should_cancelWithoutJoining_when_cleanupNeedsOuterSyncLock() = runBlocking {
        val gate = AccountOperationGate()
        val operation = gate.capture()
        val cleanupRelease = CompletableDeferred<Unit>()
        val cleanupEntered = CompletableDeferred<Unit>()
        val work = launch(start = CoroutineStart.UNDISPATCHED) {
            try { awaitCancellation() }
            finally {
                withContext(NonCancellable) {
                    cleanupEntered.complete(Unit)
                    cleanupRelease.await()
                }
            }
        }
        operation.onInvalidated { work.cancel() }
        try {
            gate.beginTransition()
            assertTrue(work.isCancelled)
            assertFalse(work.isCompleted)
            gate.finishTransition()
        } finally {
            cleanupRelease.complete(Unit)
            work.cancel()
        }
        withTimeout(5_000) { work.join(); cleanupEntered.await() }
    }

    @Test fun should_invalidateLateRegistrationsAndKeepFailedSpaceClosed() {
        val gate = AccountOperationGate()
        val old = gate.capture()
        var cancelled = 0
        val registration = old.onInvalidated { cancelled += 1 }
        registration.close()
        gate.beginTransition()
        old.onInvalidated { cancelled += 1 }
        val during = gate.capture()
        during.onInvalidated { cancelled += 1 }
        assertEquals(2, cancelled)
        assertTrue(runCatching { during.files { error("不能执行") } }.isFailure)
        gate.beginTransition()
        gate.finishTransition()
        assertFalse(old.isCurrent())
        assertFalse(during.isCurrent())
        assertTrue(gate.capture().isCurrent())
    }

    @Test fun should_propagateOriginalGeneration_when_lateTurnUsesCoroutineContext() = runBlocking {
        val gate = AccountOperationGate()
        val operation = gate.capture()
        var didPersist = false
        gate.beginTransition()
        gate.finishTransition()
        val result = runCatching {
            withContext(operation) {
                coroutineContext[AccountOperation]?.requireCurrent()
                didPersist = true
            }
        }
        assertTrue(result.isFailure)
        assertFalse(didPersist)
        assertNotNull(coroutineContext[Job])
    }
}
