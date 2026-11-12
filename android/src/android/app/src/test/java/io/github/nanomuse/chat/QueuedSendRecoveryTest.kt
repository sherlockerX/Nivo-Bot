package io.github.nanomuse.chat

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** 队列等待、撤回、提交与草稿恢复的行为回归。 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class QueuedSendRecoveryTest {
    private data class Prompt(val id: String, val attachment: Any = Any())

    @Test
    fun should_keepOriginalAndNewEntries_when_preparationFails() = runTest {
        val original = Prompt("a")
        val added = Prompt("b")
        var queue = listOf(original)
        val gate = CompletableDeferred<Unit>()
        val task = async {
            runCatching {
                commitPreparedQueue(
                    readQueue = { queue }, id = { it.id },
                    prepare = { gate.await(); error("disk full") },
                    onCommitting = {}, commit = { _, _: Unit -> error("must not commit") },
                    onRollback = {}, dispatcher = StandardTestDispatcher(testScheduler),
                )
            }
        }
        runCurrent()
        queue = queue + added
        gate.complete(Unit)
        assertEquals("disk full", task.await().exceptionOrNull()?.message)
        assertEquals(listOf(original, added), queue)
        assertSame(original.attachment, queue.first().attachment)
    }

    @Test
    fun should_reprepareOnlySurvivors_when_entryWithdrawnDuringWait() = runTest {
        val first = Prompt("a")
        val withdrawn = Prompt("b")
        val added = Prompt("c")
        var queue = listOf(first, withdrawn)
        val gate = CompletableDeferred<Unit>()
        val prepared = mutableListOf<List<String>>()
        val task = async {
            commitPreparedQueue(
                readQueue = { queue }, id = { it.id },
                prepare = { batch -> prepared += batch.map { it.id }; gate.await(); batch },
                onCommitting = {}, commit = { batch, attachments ->
                    assertEquals(listOf(first), attachments)
                    queue = queue.filterNot { item -> batch.any { it.id == item.id } }
                    batch
                }, onRollback = {}, dispatcher = StandardTestDispatcher(testScheduler),
            )
        }
        runCurrent()
        queue = listOf(first, added)
        gate.complete(Unit)
        assertEquals(listOf(first), task.await())
        assertEquals(listOf(listOf("a", "b"), listOf("a")), prepared)
        assertEquals(listOf(added), queue)
    }

    @Test
    fun should_skipCommit_when_allEntriesWithdrawnDuringWait() = runTest {
        var queue = listOf(Prompt("a"))
        val gate = CompletableDeferred<Unit>()
        var commits = 0
        val task = async {
            commitPreparedQueue(
                readQueue = { queue }, id = { it.id }, prepare = { gate.await() },
                onCommitting = {}, commit = { _, _ -> commits++ }, onRollback = {},
                dispatcher = StandardTestDispatcher(testScheduler),
            )
        }
        runCurrent()
        queue = emptyList()
        gate.complete(Unit)
        assertNull(task.await())
        assertEquals(0, commits)
    }

    @Test
    fun should_propagateCancellationAndKeepQueue_when_waitIsCancelled() = runTest {
        val queue = listOf(Prompt("a"))
        val gate = CompletableDeferred<Unit>()
        var commits = 0
        val task = async {
            commitPreparedQueue(
                readQueue = { queue }, id = { it.id }, prepare = { gate.await() },
                onCommitting = {}, commit = { _, _ -> commits++ }, onRollback = {},
                dispatcher = StandardTestDispatcher(testScheduler),
            )
        }
        runCurrent()
        task.cancel()
        assertTrue(runCatching { task.await() }.exceptionOrNull() is CancellationException)
        assertEquals(listOf("a"), queue.map { it.id })
        assertEquals(0, commits)
    }

    @Test
    fun should_restoreQueuedPresentation_when_persistenceFails() = runTest {
        val queue = listOf(Prompt("a"))
        var isQueued = true
        val result = runCatching {
            commitPreparedQueue(
                readQueue = { queue }, id = { it.id }, prepare = { Unit },
                onCommitting = { isQueued = false }, commit = { _, _ -> error("db failed") },
                onRollback = { isQueued = true }, dispatcher = StandardTestDispatcher(testScheduler),
            )
        }
        assertEquals("db failed", result.exceptionOrNull()?.message)
        assertTrue(isQueued)
        assertEquals(1, queue.size)
    }

    @Test
    fun should_finishAcceptedCommitAndPropagateCancellation_when_cancelledDuringPersistence() = runTest {
        var queue = listOf(Prompt("a"))
        val gate = CompletableDeferred<Unit>()
        var isShown = false
        val task = async {
            commitPreparedQueue(
                readQueue = { queue }, id = { it.id }, prepare = { Unit },
                onCommitting = {}, commit = { batch, _ ->
                    gate.await()
                    queue = queue.filterNot { it in batch }
                    isShown = true
                }, onRollback = {}, dispatcher = StandardTestDispatcher(testScheduler),
            )
        }
        runCurrent()
        task.cancel()
        gate.complete(Unit)
        assertTrue(runCatching { task.await() }.exceptionOrNull() is CancellationException)
        assertTrue(isShown)
        assertTrue(queue.isEmpty())
    }

    @Test
    fun should_keepBothDraftsAndAttachmentIdentity_when_failedDraftMeetsNewDraft() {
        val failed = Prompt("failed")
        val newer = Prompt("new")
        assertEquals("原稿\n\n新稿", restoreFailedText("原稿", "新稿"))
        val merged = restoreFailedAttachments(listOf(failed), listOf(newer, failed)) { it.id }
        assertEquals(listOf(failed, newer), merged)
        assertSame(failed.attachment, merged.first().attachment)
    }

    @Test
    fun should_avoidDuplicateDraft_when_sameRecoveryRunsAgain() {
        assertEquals("原稿", restoreFailedText("原稿", "原稿"))
        assertEquals("原稿\n\n新稿", restoreFailedText("原稿", "原稿\n\n新稿"))
        assertEquals("原稿", restoreFailedText("原稿", ""))
    }
}
