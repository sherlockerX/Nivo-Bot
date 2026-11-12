package io.github.nanomuse.todo

import android.content.Context
import io.github.nanomuse.mosaic.MosaicDatabase
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.mockito.Mockito

/** 验证备份读写使用相同容量边界，超限时不生成截断账本。 */
class TodoBackupTest {
    @Test fun should_rejectExport_when_fullLedgerExceedsByteLimit() = runBlocking {
        val fixture = fixture()
        val content = "a".repeat(100_000)
        Mockito.`when`(fixture.dao.operations(OWNER)).thenReturn(List(50) { index ->
            TodoOperation(OWNER, "operation-$index", content, content, 1)
        })
        assertRejected { TodoBackup.export(fixture.store) }
    }

    @Test fun should_rejectExport_when_taskCountExceedsImportLimit() = runBlocking {
        val fixture = fixture()
        Mockito.`when`(fixture.dao.allTasks(OWNER)).thenReturn(List(10_001) { index ->
            TodoTask(ownerKey = OWNER, id = "task-$index", title = "Task")
        })
        assertRejected { TodoBackup.export(fixture.store) }
    }

    @Test fun should_rejectExport_when_linkCountExceedsImportLimit() = runBlocking {
        val fixture = fixture()
        Mockito.`when`(fixture.dao.allEntryLinks(OWNER)).thenReturn(List(50_001) { index ->
            TodoEntryLink(OWNER, "entry-$index", "task", "Task", "todo", 1)
        })
        assertRejected { TodoBackup.export(fixture.store) }
    }

    @Test fun should_rejectExport_when_eventCountExceedsImportLimit() = runBlocking {
        val fixture = fixture()
        Mockito.`when`(fixture.dao.events(OWNER)).thenReturn(List(50_001) { index ->
            TodoEvent(OWNER, "$index", "task", null, "todo", null, "[]", 1)
        })
        assertRejected { TodoBackup.export(fixture.store) }
    }

    @Test fun should_rejectExport_when_operationCountExceedsImportLimit() = runBlocking {
        val fixture = fixture()
        Mockito.`when`(fixture.dao.operations(OWNER)).thenReturn(List(50_001) { index ->
            TodoOperation(OWNER, "$index", "{}", "{}", 1)
        })
        assertRejected { TodoBackup.export(fixture.store) }
    }

    @Test fun should_measureUtf8Bytes_when_importContainsChinese() = runBlocking {
        val fixture = fixture()
        val text = emptyBackup().put("padding", "中".repeat(2_666_667)).toString()
        assertTrue(text.length < 8_000_000)
        assertTrue(text.toByteArray(Charsets.UTF_8).size > 8_000_000)
        assertRejected { TodoBackup.import(fixture.store, text) }
        Mockito.verifyNoInteractions(fixture.dao)
    }

    @Test fun should_acceptExactByteLimitAndRejectOneMore_when_importing() = runBlocking {
        val fixture = fixture()
        val json = emptyBackup().put("padding", "")
        val remaining = 8_000_000 - json.toString().toByteArray(Charsets.UTF_8).size
        val exact = json.put("padding", "a".repeat(remaining)).toString()
        assertEquals(8_000_000, exact.toByteArray(Charsets.UTF_8).size)
        assertEquals(0, TodoBackup.import(fixture.store, exact).importedCount)
        assertRejected { TodoBackup.import(fixture.store, exact + " ") }
    }

    @Test fun should_keepAllLedgerRows_when_exportIsWithinLimits() = runBlocking {
        val fixture = fixture()
        val operations = List(3) { index -> TodoOperation(OWNER, "$index", "request-$index", "result-$index", 1) }
        Mockito.`when`(fixture.dao.operations(OWNER)).thenReturn(operations)
        val exported = JSONObject(TodoBackup.export(fixture.store)).getJSONArray("operations")
        assertEquals(operations.size, exported.length())
        operations.forEachIndexed { index, operation ->
            assertEquals(operation.requestJson, exported.getJSONObject(index).getString("request"))
            assertEquals(operation.resultJson, exported.getJSONObject(index).getString("result"))
        }
    }

    private suspend fun fixture(): Fixture {
        val dao = Mockito.mock(TodoDao::class.java)
        Mockito.`when`(dao.categories(OWNER)).thenReturn(emptyList())
        Mockito.`when`(dao.allTasks(OWNER)).thenReturn(emptyList())
        Mockito.`when`(dao.allEntryLinks(OWNER)).thenReturn(emptyList())
        Mockito.`when`(dao.events(OWNER)).thenReturn(emptyList())
        Mockito.`when`(dao.operations(OWNER)).thenReturn(emptyList())
        val database = Mockito.mock(MosaicDatabase::class.java)
        Mockito.`when`(database.todoDao()).thenReturn(dao)
        return Fixture(TodoStore(Mockito.mock(Context::class.java), database, OWNER, 0), dao)
    }

    private fun emptyBackup(): JSONObject = JSONObject().put("format", "nanomuse-todo").put("version", 1)
        .put("tasks", JSONArray()).put("links", JSONArray()).put("events", JSONArray()).put("operations", JSONArray())

    private suspend fun assertRejected(block: suspend () -> Any?) {
        val failure = runCatching { block() }.exceptionOrNull()
        assertTrue("Expected IllegalArgumentException, got $failure", failure is IllegalArgumentException)
    }

    private data class Fixture(val store: TodoStore, val dao: TodoDao)

    companion object { private const val OWNER = "backup-test" }
}
