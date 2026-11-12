package io.github.nanomuse.todo

import io.github.nanomuse.coach.CoachTurnAuthorization
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** 宿主门禁测试使用真实授权快照，不依赖Android界面或Room替身。 */
class TodoToolHostTest {
    private val authorization = CoachTurnAuthorization("user-1", "main", "token-1")
    private val allowed = TodoToolAccess(
        isAccountCurrent = true, isMain = true, isScheduled = false, isTaskDispatch = false,
        sessionId = "main", loopUserId = "user-1", authorization = authorization,
        currentAuthorization = authorization, user = TodoToolUser("user-1", "列出我的任务", "main"),
    )

    @Test fun should_rejectUntrustedHosts_when_accessIsNotCurrentMainUser() {
        val denied = listOf(
            allowed.copy(isAccountCurrent = false), allowed.copy(isMain = false),
            allowed.copy(isScheduled = true), allowed.copy(isTaskDispatch = true),
            allowed.copy(user = null), allowed.copy(loopUserId = "old-user"),
            allowed.copy(authorization = null),
            allowed.copy(currentAuthorization = authorization.copy(token = "new-token")),
            allowed.copy(sessionId = "other"),
            allowed.copy(user = allowed.user!!.copy(messageId = "queued_msg_1")),
        )
        denied.forEach { assertNotNull(it.denialReason()) }
        assertNull(allowed.denialReason())
    }

    @Test fun should_notOpenStorage_when_authorizationChangesDuringGuard() = runTest {
        var state = allowed
        var opened = false
        val host = TodoToolHost({ state }, { _, _ ->
            state = allowed.copy(currentAuthorization = authorization.copy(token = "new-token"))
            null
        }, { opened = true; error("must not open storage") })
        assertFalse(host.execute(TodoAgentBridge.QUERY, "{}").success)
        assertFalse(opened)
    }

    @Test fun should_rejectNewValidTurn_when_waitingOriginalCallChangesOwner() = runTest {
        var state = allowed
        val newAuthorization = CoachTurnAuthorization("user-2", "main", "token-2")
        val host = TodoToolHost({ state }, { _, _ ->
            state = allowed.copy(loopUserId = "user-2", authorization = newAuthorization,
                currentAuthorization = newAuthorization, user = TodoToolUser("user-2", "新问题", "main"))
            null
        }, { error("must not open storage for a replacement user") })
        assertFalse(host.execute(TodoAgentBridge.QUERY, "{}").success)
    }

    @Test fun should_stopMutation_when_authorizationRevokesDuringRead() = runTest {
        var state = allowed
        var writes = 0
        val storage = object : EmptyStorage() {
            override suspend fun task(id: String): TodoTask {
                state = allowed.copy(currentAuthorization = null)
                return TodoTask(ownerKey = ownerKey, id = id, title = "原任务", revision = 1)
            }
            override suspend fun saveTask(task: TodoTask, operationId: String): TodoTask {
                writes++
                return task
            }
        }
        val result = TodoToolHost({ state }, { _, _ -> null }, { storage }).execute(
            TodoAgentBridge.COMMAND,
            """{"action":"update","operationId":"update-1","targetId":"task-1","expectedRevision":1,"payload":"{\"title\":\"新标题\"}"}""",
        )
        assertFalse(result.success)
        assertEquals(0, writes)
    }

    @Test fun should_propagateCancellation_when_guardIsWaiting() = runTest {
        val entered = CompletableDeferred<Unit>()
        val never = CompletableDeferred<Unit>()
        val host = TodoToolHost({ allowed }, { _, _ -> entered.complete(Unit); never.await(); null }, { error("cancelled") })
        val job = async { host.execute(TodoAgentBridge.QUERY, "{}") }
        entered.await()
        job.cancel()
        try { job.await(); fail("Cancellation must propagate") } catch (_: CancellationException) { }
    }

    @Test fun should_readPersistedInput_when_updateRetriesAfterTaskChanges() {
        val original = TodoTask(ownerKey = "owner", id = "task-1", title = "更新后的标题", revision = 4,
            updatedAt = 100, createdAt = 50)
        val request = JSONObject().put("kind", "save").put("task", TodoJson.task(original)).toString()
        assertEquals(original, TodoToolReplay.updateInput(request, "task-1", 4))
        listOf("task-2" to 4L, "task-1" to 5L).forEach { (id, revision) ->
            assertThrows(IllegalArgumentException::class.java) { TodoToolReplay.updateInput(request, id, revision) }
        }
        assertThrows(IllegalArgumentException::class.java) {
            TodoToolReplay.updateInput("""{"kind":"delete"}""", "task-1", 4)
        }
    }

    @Test fun should_forwardSavedCategories_throughRealHostGuard() = runTest {
        val storage=object:EmptyStorage() {
            override suspend fun categories()=listOf(TodoCategory(ownerKey,"group","已保存分组",1,1))
        }
        val result=TodoToolHost({allowed},{_,_->null},{storage}).execute(TodoAgentBridge.QUERY,"""{"kind":"categories"}""")
        assertTrue(result.output,result.success)
        assertTrue(result.output.contains("已保存分组"))
    }

    private open class EmptyStorage : TodoToolStorage {
        override val ownerKey = "owner"
        override suspend fun tasks(): List<TodoTask> = emptyList()
        override suspend fun task(id: String): TodoTask? = null
        override suspend fun saveTask(task: TodoTask, operationId: String): TodoTask = error("unexpected write")
        override suspend fun changeStatus(id: String, status: String, expectedRevision: Long,
            operationId: String, completedDay: Long?): TodoTask = error("unexpected status")
        override suspend fun deleteTask(id: String, expectedRevision: Long, operationId: String) = Unit
    }
}
