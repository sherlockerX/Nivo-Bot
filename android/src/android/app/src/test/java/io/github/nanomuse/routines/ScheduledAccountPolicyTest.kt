package io.github.nanomuse.routines

import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

/** 权威owner先于limit过滤，账号往返也不能重新授权旧请求。 */
class ScheduledAccountPolicyTest {
    @Test fun should_filterBeforeLimit_andRejectUnownedRows() {
        val ids = listOf("other-latest", "unclaimed", "mine-first", "mine-second")
        assertEquals(listOf("mine-first"), ScheduledAccountPolicy.visible(ids, setOf("mine-first", "mine-second"), 1) { it })
        assertEquals(emptyList<String>(), ScheduledAccountPolicy.visible(ids, emptySet(), 10) { it })
    }

    @Test fun should_rejectOtherOwnerAndRoundTripSwitch_beforeReadingMessages() {
        assertTrue(ScheduledAccountPolicy.isCurrent("owner", 2, "owner", 2))
        assertFalse(ScheduledAccountPolicy.isCurrent("owner", 2, "other", 2))
        assertFalse(ScheduledAccountPolicy.isCurrent("owner", 2, "owner", 4))
        assertTrue(ScheduledAccountPolicy.isCurrent("", 2, "", 2))
    }

    @Test fun should_cancelActualWorkAndWaitForCleanup_when_accountEpochChanges() = runTest {
        val epoch = MutableStateFlow(2L)
        val started = CompletableDeferred<Unit>()
        var cleaned = false
        var completed = false
        val work = launch {
            ScheduledAccountPolicy.untilChanged(epoch, 2) {
                try { started.complete(Unit); awaitCancellation() }
                finally { withContext(NonCancellable) { delay(10); cleaned = true } }
            }
            completed = true
        }
        started.await()
        epoch.value = 3
        work.join()
        assertTrue(work.isCancelled)
        assertTrue(cleaned)
        assertFalse(completed)
    }

    @Test fun should_notStartWork_when_epochAlreadyChanged() = runTest {
        var started = false
        val work = launch {
            ScheduledAccountPolicy.untilChanged(MutableStateFlow(3L), 2) { started = true }
        }
        work.join()
        assertTrue(work.isCancelled)
        assertFalse(started)
    }

    @Test fun should_returnCompletedWork_withoutWaitingForFutureAccountChange() = runTest {
        assertEquals("saved", ScheduledAccountPolicy.untilChanged(MutableStateFlow(2L), 2) { "saved" })
    }
}
