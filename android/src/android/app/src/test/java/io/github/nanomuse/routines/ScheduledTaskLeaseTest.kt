package io.github.nanomuse.routines

import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** 任务领取早于建会话，覆盖取消和后台交接，不需要持有协程互斥锁。 */
class ScheduledTaskLeaseTest {
    @Test fun should_rejectReentryBeforeSessionExists_andAllowOtherTasks() {
        val first = requireNotNull(ScheduledTaskLease.acquire("first"))
        val other = requireNotNull(ScheduledTaskLease.acquire("other"))
        try {
            assertNull(ScheduledTaskLease.acquire("first"))
            assertTrue(ScheduledTaskLease.isActive("first"))
        } finally { first.close(); other.close() }
        assertFalse(ScheduledTaskLease.isActive("first"))
    }

    @Test fun should_releaseOnCancellation_withoutOldReleaseRemovingSuccessor() = runTest {
        val started = CompletableDeferred<Unit>()
        val running = launch {
            val lease = requireNotNull(ScheduledTaskLease.acquire("cancelled"))
            try { started.complete(Unit); awaitCancellation() }
            finally { lease.close() }
        }
        started.await()
        assertNull(ScheduledTaskLease.acquire("cancelled"))
        running.cancelAndJoin()
        val next = requireNotNull(ScheduledTaskLease.acquire("cancelled"))
        next.close()
        val successor = requireNotNull(ScheduledTaskLease.acquire("cancelled"))
        try { next.close(); assertTrue(ScheduledTaskLease.isActive("cancelled")) }
        finally { successor.close() }
    }

    @Test fun should_releaseEvenWhenBackgroundJobNeverStarts() = runTest {
        val lease = requireNotNull(ScheduledTaskLease.acquire("handoff"))
        val cancelledScope = CoroutineScope(SupervisorJob().also { it.cancel() } + coroutineContext.minusKey(Job))
        val job = cancelledScope.launch { fail("已取消的后台作用域不能开始业务") }
        job.invokeOnCompletion { lease.close() }
        job.join()
        assertFalse(ScheduledTaskLease.isActive("handoff"))
    }

    @Test fun should_createOnlyOneConversation_when_firstDispatchesRace() {
        val ready = java.util.concurrent.CountDownLatch(8)
        val begin = java.util.concurrent.CountDownLatch(1)
        val finished = java.util.concurrent.CountDownLatch(8)
        val created = java.util.concurrent.atomic.AtomicInteger()
        val leases = java.util.concurrent.ConcurrentLinkedQueue<ScheduledTaskLease.Lease>()
        val threads = List(8) {
            Thread {
                ready.countDown()
                begin.await()
                ScheduledTaskLease.acquire("new-task")?.let { lease ->
                    leases.add(lease)
                    created.incrementAndGet()
                }
                finished.countDown()
            }.also { it.start() }
        }
        try {
            assertTrue(ready.await(5, java.util.concurrent.TimeUnit.SECONDS))
            begin.countDown()
            assertTrue(finished.await(5, java.util.concurrent.TimeUnit.SECONDS))
            assertEquals(1, created.get())
        } finally {
            begin.countDown()
            threads.forEach { it.join(5_000) }
            leases.forEach { it.close() }
        }
    }
}
