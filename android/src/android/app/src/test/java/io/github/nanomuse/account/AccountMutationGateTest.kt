package io.github.nanomuse.account

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test

/** 用受控挂起验证归属落盘与迁移的交错，不依赖延时或真实账号。 */
class AccountMutationGateTest {
    @Test fun should_rejectStaleTurnContext_when_priorTransitionFinished() = runBlocking {
        val gate = AccountMutationGate()
        val operation = gate.operations.capture()
        var didPersist = false
        gate.transition { }
        val result = runCatching {
            withContext(operation) { gate.create({ "account-a" }) { didPersist = true } }
        }
        assertTrue(result.isFailure)
        assertFalse(didPersist)
    }

    @Test fun should_advanceEpochOnlyForTransitions_when_regularMutationsRun() = runBlocking {
        val gate = AccountMutationGate()
        gate.create({ "account-a" }) { }
        gate.exclusive { }
        assertEquals(0L, gate.epoch.value)
        gate.transition { assertEquals(1L, gate.epoch.value) }
        assertEquals(2L, gate.epoch.value)
        assertTrue(runCatching { gate.transition { error("迁移未完成") } }.isFailure)
        assertEquals(3L, gate.epoch.value)
    }

    @Test fun should_finishOwnershipBeforeSwitch_when_creationAlreadyStarted() = runBlocking {
        val gate = AccountMutationGate()
        var owner = "account-a"
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val create = async(start = CoroutineStart.UNDISPATCHED) {
            gate.create({ owner }) { captured -> entered.complete(Unit); release.await(); captured }
        }
        entered.await()
        val switch = async(start = CoroutineStart.UNDISPATCHED) { gate.exclusive { owner = "account-b" } }
        assertFalse(switch.isCompleted)
        release.complete(Unit)
        assertEquals("account-a", create.await())
        switch.await()
        assertEquals("account-b", owner)
    }

    @Test fun should_rejectOldRequest_when_ownerChangesWhileWaiting() = runBlocking {
        val gate = AccountMutationGate()
        var owner = "account-a"
        var didInsert = false
        val release = CompletableDeferred<Unit>()
        val switch = async(start = CoroutineStart.UNDISPATCHED) {
            gate.exclusive { release.await(); owner = "account-b" }
        }
        val create = async(start = CoroutineStart.UNDISPATCHED) {
            runCatching { gate.create({ owner }) { didInsert = true } }
        }
        release.complete(Unit)
        switch.await()
        assertTrue(create.await().isFailure)
        assertFalse(didInsert)
    }

    @Test fun should_keepCreationClosed_when_transitionFails() = runBlocking {
        val gate = AccountMutationGate()
        var didInsert = false
        assertTrue(runCatching { gate.transition { error("文件未恢复") } }.isFailure)
        assertTrue(runCatching { gate.requireAvailable() }.isFailure)
        assertTrue(runCatching { gate.exclusive { didInsert = true } }.isFailure)
        assertTrue(runCatching { gate.create({ "account-a" }) { didInsert = true } }.isFailure)
        assertFalse(didInsert)
        gate.transition { }
        assertEquals("account-a", gate.create({ "account-a" }) { it })
    }

    @Test fun should_waitForSessionRow_when_reconcileRunsAfterClaim() = runBlocking {
        val gate = AccountMutationGate()
        val claimed = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val rows = mutableSetOf<String>()
        val owners = mutableMapOf<String, String>()
        val create = async(start = CoroutineStart.UNDISPATCHED) {
            gate.create({ "account-a" }) { owner ->
                owners["chat"] = owner
                claimed.complete(Unit)
                release.await()
                rows += "chat"
            }
        }
        claimed.await()
        val reconcile = async(start = CoroutineStart.UNDISPATCHED) {
            gate.exclusive { rows.associateWith { owners.getValue(it) } }
        }
        assertFalse(reconcile.isCompleted)
        release.complete(Unit)
        create.await()
        assertEquals(mapOf("chat" to "account-a"), reconcile.await())
    }

    @Test fun should_rejectQueuedRequest_when_transitionReturnsToSameOwner() = runBlocking {
        val gate = AccountMutationGate()
        var owner = "account-a"
        var didInsert = false
        val release = CompletableDeferred<Unit>()
        val transition = async(start = CoroutineStart.UNDISPATCHED) {
            gate.transition { release.await(); owner = "account-b"; owner = "account-a" }
        }
        val create = async(start = CoroutineStart.UNDISPATCHED) {
            runCatching { gate.create({ owner }) { didInsert = true } }
        }
        release.complete(Unit)
        transition.await()
        assertTrue(create.await().isFailure)
        assertFalse(didInsert)
    }
}
