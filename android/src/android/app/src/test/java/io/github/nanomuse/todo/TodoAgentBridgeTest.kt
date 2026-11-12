package io.github.nanomuse.todo

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** 专用工具只能执行明确、有版本和幂等身份的个人待办操作。 */
@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class TodoAgentBridgeTest {
    private val storage = MemoryStorage()
    private val bridge = TodoAgentBridge(storage)
    private val user = TodoToolUser("saved-user", "请帮我添加待办：写报告。报告已经完成了。", "main")

    @Test
    fun should_rejectStaleUpdateBeforeStorage_andReturnStableConflictCode() = runTest {
        storage.rows += TodoTask(ownerKey = "owner", id = "task", title = "手机已修改", revision = 7)
        val result = bridge.command(command("update", "stale-new-operation", """{"title":"旧窗口覆盖"}""", 6), user)
        assertFalse("旧修订号不得交给保存端口", result.success)
        assertEquals("stale_revision", JSONObject(result.output).optString("code"))
        assertEquals(0, storage.writes)
        assertEquals("手机已修改", storage.rows.single().title)
    }

    @Test
    fun should_findRenamedTaskByIdAndCreationDate_withoutSearchingOldTitle() = runTest {
        val created = java.time.LocalDate.of(2026, 11, 7)
            .atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
        storage.rows += TodoTask(ownerKey = "owner", id = "stable-task-id", title = "修改后的标题", createdAt = created, revision = 2)
        val byId = bridge.query("""{"search":"stable-task-id"}""")
        assertTrue(byId.output, byId.success)
        assertEquals(1, JSONObject(byId.output).getInt("total"))
        val byDate = bridge.query("""{"dateField":"created","startDate":"2026-11-07","endDate":"2026-11-07"}""")
        assertTrue(byDate.output, byDate.success)
        assertEquals(1, JSONObject(byDate.output).getInt("total"))
        assertEquals(0, JSONObject(bridge.query("""{"search":"原来的标题"}""").output).getInt("total"))
    }

    @Test
    fun should_rejectWrongTypesAndForgedIdentity_beforeStorageMutation() = runTest {
        listOf(
            """{"action":"create","operationId":"a","payload":{"title":"写报告"}}""",
            """{"action":"start","targetId":"task","expectedRevision":"1","operationId":"a"}""",
            """{"action":"delete","targetId":"task","expectedRevision":1.5,"operationId":"a"}""",
            """{"action":"create","operationId":"a","ownerKey":"other","payload":"{}"}""",
            """{"action":"create","operationId":"a","payload":"{\"title\":\"写报告\",\"isUrgent\":\"true\"}"}""",
            """{"action":"create","operationId":"a","payload":"{\"title\":\"写报告\",\"tags\":[1]}"}""",
        ).forEach { assertFalse(it, bridge.command(it, user).success) }
        assertEquals(0, storage.writes)
    }

    @Test
    fun should_preserveOperationAndExpectedRevision_when_commandReplayed() = runTest {
        storage.rows += TodoTask(ownerKey = "owner", id = "task", title = "旧标题", revision = 4)
        val args = command("update", "same", """{"title":"新标题","tags":["写作","写作"],"dueDate":null}""", 4)
        assertTrue(bridge.command(args, user).success)
        assertTrue(bridge.command(args, user).success)
        assertEquals(listOf("same", "same"), storage.operations)
        assertEquals(listOf(4L, 4L), storage.saved.map { it.revision })
        assertEquals(listOf("写作"), storage.saved.first().tags())
        assertNull(storage.saved.first().dueDay)
    }

    @Test
    fun should_createOnlyTodoWithoutModelOwnerOrCompletionFields() = runTest {
        assertTrue(bridge.command(command("create", "create", """{"title":"写报告","scheduledDate":"2026-11-09","isImportant":true}"""), user).success)
        val saved = storage.saved.single()
        assertEquals("owner", saved.ownerKey)
        assertEquals("", saved.id)
        assertEquals("todo", saved.status)
        assertEquals(java.time.LocalDate.of(2026, 11, 9).toEpochDay(), saved.scheduledDay)
        assertFalse(bridge.command(command("create", "forged", """{"title":"写报告","status":"done"}"""), user).success)
    }

    @Test
    fun should_requireCurrentUserQuote_when_markingComplete() = runTest {
        storage.rows += TodoTask(ownerKey = "owner", id = "task", title = "报告", revision = 4)
        val missing = """{"action":"complete","operationId":"c","targetId":"task","expectedRevision":4}"""
        assertFalse(bridge.command(missing, user).success)
        assertFalse(bridge.command(JSONObject(missing).put("userQuote", "模型说完成了").toString(), user).success)
        assertTrue(bridge.command(JSONObject(missing).put("userQuote", "报告已经完成了")
            .put("completedDate", "2026-11-07").toString(), user).success)
        assertEquals("done", storage.statuses.single())
        assertEquals(java.time.LocalDate.of(2026, 11, 7).toEpochDay(), storage.completedDays.single())
    }

    @Test
    fun should_rejectPlansAndNegation_when_quoteIsCurrentButNotCompletionReport() = runTest {
        storage.rows += TodoTask(ownerKey = "owner", id = "task", title = "报告", revision = 4)
        val args = """{"action":"complete","operationId":"c","targetId":"task","expectedRevision":4}"""
        listOf(
            "帮我测试新加入的待办功能" to "帮我测试新加入的待办功能",
            "测试一下待办功能，这条测试项算作完成" to "测试一下待办功能，这条测试项算作完成",
            "请帮我添加待办：写报告。" to "写报告",
            "报告还没完成了呢。" to "完成了",
            "等报告完成了再说。" to "报告完成了",
            "我计划明天完成报告。" to "完成报告",
            "I am not done with the report." to "done with the report",
            "I will finish the report tomorrow." to "finish the report",
            "Have I finished the report?" to "Have I finished the report?",
            "报告完成了吗？" to "报告完成了吗？",
        ).forEach { (text, quote) ->
            assertFalse(text, bridge.command(JSONObject(args).put("userQuote", quote).toString(),
                user.copy(text = text)).success)
        }
        assertEquals(0, storage.writes)
        listOf("报告写完了。", "我已经完成报告。", "这个做完了", "I finished the report.").forEach { text ->
            assertTrue(text, bridge.command(JSONObject(args).put("userQuote", text).toString(),
                user.copy(text = text)).success)
        }
    }

    @Test
    fun should_filterPageAndHideOwnerNotes_when_queryingSummaries() = runTest {
        val day = java.time.LocalDate.of(2026, 11, 9).toEpochDay()
        storage.rows += (1..4).map { TodoTask(ownerKey = "owner", id = "t$it", title = "报告$it", notes = "private-body", scheduledDay = day, revision = 1) }
        storage.rows += TodoTask(ownerKey = "other", id = "foreign", title = "报告foreign", scheduledDay = day)
        val result = bridge.query("""{"kind":"tasks","status":"todo","search":"报告","dateField":"scheduled","startDate":"2026-11-09","endDate":"2026-11-09","limit":2,"offset":1}""")
        assertTrue(result.output, result.success)
        val output = JSONObject(result.output)
        assertEquals(4, output.getInt("total"))
        assertEquals(3, output.getInt("nextOffset"))
        assertEquals(2, output.getJSONArray("data").length())
        assertFalse(result.output.contains("ownerKey"))
        assertFalse(result.output.contains("private-body"))
        assertFalse(result.output.contains("foreign"))
        assertTrue(bridge.query("""{"kind":"detail","targetId":"t1"}""").output.contains("private-body"))
        assertFalse(bridge.query("""{"kind":"detail","targetId":"foreign"}""").success)
    }

    @Test
    fun should_rejectInvalidQueryAndDates_withoutReturningUnfilteredData() = runTest {
        listOf("""{"kind":"all"}""", """{"kind":"tasks","limit":"2"}""",
            """{"kind":"tasks","status":"finished"}""", """{"kind":"tasks","startDate":"2026-02-30"}""",
            """{"kind":"tasks","offset":-1}""", """{"kind":"tasks","ownerKey":"other"}""")
            .forEach { assertFalse(it, bridge.query(it).success) }
    }

    @Test
    fun should_waitForPersistenceAndReportFailure_withoutClaimingSuccess() = runTest {
        val gate = CompletableDeferred<Unit>()
        storage.beforeWrite = { gate.await(); error("disk full") }
        val pending = async { bridge.command(command("create", "once", """{"title":"报告"}"""), user) }
        runCurrent()
        assertFalse(pending.isCompleted)
        gate.complete(Unit)
        val result = pending.await()
        assertFalse(result.success)
        assertEquals("disk full", JSONObject(result.output).getString("message"))
    }

    @Test
    fun should_propagateCancellation_andRejectMissingHostUser() = runTest {
        assertFalse(bridge.command(command("create", "once", """{"title":"报告"}"""), null).success)
        storage.beforeWrite = { throw CancellationException("account changed") }
        val result = runCatching { bridge.command(command("create", "once", """{"title":"报告"}"""), user) }
        assertTrue(result.exceptionOrNull() is CancellationException)
    }

    @Test
    fun should_keepStartReopenDeleteSeparateFromAutomation() = runTest {
        storage.rows += TodoTask(ownerKey = "owner", id = "task", title = "报告", revision = 4)
        listOf("start", "reopen", "delete").forEach { action ->
            assertTrue(bridge.command(command(action, action, revision = 4), user).success)
        }
        assertEquals(listOf("in_progress", "todo"), storage.statuses)
        assertEquals(listOf("task"), storage.deleted)
        val tools = TodoAgentBridge.definitions()
        assertEquals(setOf("todo_query", "todo_command"), tools.map { it.name }.toSet())
        assertFalse(tools.any { "ownerKey" in it.parameters })
    }

    private fun command(action: String, operation: String, payload: String? = null, revision: Long? = null): String =
        JSONObject().put("action", action).put("operationId", operation).apply {
            if (action != "create") put("targetId", "task")
            if (revision != null) put("expectedRevision", revision)
            if (payload != null) put("payload", payload)
        }.toString()

    /** 仅替代存储端口，记录桥接请求；不冒充Room幂等实现。 */
    private class MemoryStorage : TodoToolStorage {
        override val ownerKey = "owner"
        val rows = mutableListOf<TodoTask>()
        val saved = mutableListOf<TodoTask>()
        val operations = mutableListOf<String>()
        val statuses = mutableListOf<String>()
        val completedDays = mutableListOf<Long?>()
        val deleted = mutableListOf<String>()
        var writes = 0
        var beforeWrite: suspend () -> Unit = {}
        override suspend fun tasks(): List<TodoTask> = rows.toList()
        override suspend fun task(id: String): TodoTask? = rows.find { it.id == id }
        override suspend fun saveTask(task: TodoTask, operationId: String): TodoTask {
            beforeWrite(); writes++; saved += task; operations += operationId
            return task.copy(id = task.id.ifEmpty { "created" }, revision = task.revision + 1)
        }
        override suspend fun changeStatus(id: String, status: String, expectedRevision: Long, operationId: String, completedDay: Long?): TodoTask {
            beforeWrite(); writes++; statuses += status; completedDays += completedDay
            return requireNotNull(task(id)).copy(status = status, revision = expectedRevision + 1)
        }
        override suspend fun deleteTask(id: String, expectedRevision: Long, operationId: String) {
            beforeWrite(); writes++; deleted += id
        }
    }
}
