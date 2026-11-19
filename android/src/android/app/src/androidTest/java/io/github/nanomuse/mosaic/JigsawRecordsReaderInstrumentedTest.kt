package io.github.nanomuse.mosaic

import android.content.Context
import androidx.room.Room
import androidx.room.withTransaction
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.account.AccountOperationGate
import io.github.nanomuse.focus.FocusEntryLink
import io.github.nanomuse.todo.TodoEntryLink
import java.time.LocalDate
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** nanoMuse: 用隔离内存库验证日记聚合、关联账号边界与读取凭证失效。 */
@RunWith(AndroidJUnit4::class)
class JigsawRecordsReaderInstrumentedTest {
    private lateinit var context: Context
    private lateinit var database: MosaicDatabase
    private lateinit var owner: String
    private val queries = CopyOnWriteArrayList<String>()
    private var onQuery: (String) -> Unit = {}
    private val day = LocalDate.parse("2026-11-16").toEpochDay()

    /** 仅允许测试包访问内存库，保留真实账户数据。 */
    @Before fun prepare() {
        context = ApplicationProvider.getApplicationContext()
        check(context.packageName.endsWith(".uitest")) { "只允许隔离测试包" }
        owner = AccountData.key(context)
        database = Room.inMemoryDatabaseBuilder(context, MosaicDatabase::class.java)
            .setQueryCallback({ sql, _ ->
                if (sql.startsWith("SELECT", ignoreCase = true)) queries.add(sql)
                onQuery(sql)
            }, Executor { it.run() })
            .build()
    }

    /** 关闭测试数据库。 */
    @After fun close() { if (::database.isInitialized) database.close() }

    @Test fun should_aggregateOnlyLiveEntryDates_withoutLoadingDiaryText() = runBlocking {
        val reader = JigsawRecordsReader(context, database)
        val empty = reader.range()
        assertEquals(0L, empty.getLong("entry_count"))
        assertTrue(empty.isNull("earliest_date"))
        assertTrue(empty.isNull("latest_date"))
        database.dao().upsertEntry(entry("first", day - 5))
        database.dao().upsertEntry(entry("last", day + 1))
        database.dao().upsertEntry(entry("deleted", day - 50).copy(deletedAt = 2L))
        queries.clear()
        val result = reader.range()
        assertEquals(2L, result.getLong("entry_count"))
        assertEquals("2026-11-11", result.getString("earliest_date"))
        assertEquals("2026-11-17", result.getString("latest_date"))
        assertEquals("device_local", result.getString("scope"))
        assertEquals("non_deleted_entries", result.getString("range_basis"))
        val entryQueries = queries.filter { it.contains("FROM entries", ignoreCase = true) }
        assertEquals(1, entryQueries.size)
        assertTrue(entryQueries.single().contains("COUNT(*)"))
        assertTrue(entryQueries.single().contains("MIN(day)"))
        assertTrue(entryQueries.single().contains("MAX(day)"))
        assertFalse(entryQueries.single().contains("text", ignoreCase = true))
    }

    @Test fun should_batchAssociationQueries_andExcludeOtherAccountAndUnrequestedEntries() = runBlocking {
        database.withTransaction {
            repeat(401) { index -> database.dao().upsertEntry(entry("entry-$index")) }
            database.dao().upsertEntry(entry("outside", day - 1))
            val ids = (0..400).map { "entry-$it" } + "outside"
            database.todoDao().putEntryLinks(ids.flatMap { id ->
                listOf(TodoEntryLink(owner, id, "task-$id", "历史任务", "doing", 1L),
                    TodoEntryLink("$owner-other", id, "foreign-$id", "其他账号任务", "done", 2L))
            })
            database.focusDao().putEntryLinks(ids.flatMap { id ->
                listOf(FocusEntryLink(owner, id, "focus-$id", "历史专注", 1L, 5L, 3L),
                    FocusEntryLink("$owner-other", id, "foreign-$id", "其他账号专注", 1L, 5L, 3L))
            })
        }
        queries.clear()
        val result = JigsawRecordsReader(context, database).read(day, day + 1)
        assertEquals(401, result.entries.size)
        assertEquals(401, result.todoLinks.size)
        assertEquals(401, result.focusLinks.size)
        assertTrue(result.todoLinks.all { it.ownerKey == owner && it.entryId != "outside" && it.statusSnapshot == "doing" })
        assertTrue(result.focusLinks.all { it.ownerKey == owner && it.entryId != "outside" && it.durationMs == 3L })
        val todoQueries = queries.filter { it.startsWith("SELECT") && it.contains("FROM todo_entry_links") }
        val focusQueries = queries.filter { it.startsWith("SELECT") && it.contains("FROM focus_entry_links") }
        assertEquals(2, todoQueries.size)
        assertEquals(2, focusQueries.size)
        assertTrue((todoQueries + focusQueries).all { sql -> sql.count { it == '?' } <= 401 })
    }

    @Test fun should_acceptFiveThousandEntries_andRejectOverflowWithoutTruncation() = runBlocking {
        database.withTransaction {
            repeat(5_000) { index -> database.dao().upsertEntry(entry("entry-$index")) }
        }
        val reader = JigsawRecordsReader(context, database)
        assertEquals(5_000, reader.read(day, day + 1).entries.size)
        database.dao().upsertEntry(entry("overflow"))
        queries.clear()
        try {
            reader.read(day, day + 1)
            fail("超过5000条必须显式失败")
        } catch (expected: IllegalArgumentException) {
            assertTrue(expected.message.orEmpty().contains("no text was truncated"))
        }
        assertFalse(queries.any { it.startsWith("SELECT") && it.contains("entry_links") })
        assertEquals(5_001L, reader.range().getLong("entry_count"))
    }

    @Test fun should_rejectStaleOperation_beforeAnyDataQuery() = runBlocking {
        val gate = AccountOperationGate()
        val reader = JigsawRecordsReader(context, database, gate.capture())
        gate.beginTransition()
        queries.clear()
        assertCancelled { reader.read(day, day + 1) }
        assertCancelled { reader.range() }
        assertTrue(queries.isEmpty())
    }

    @Test fun should_discardReadSnapshot_whenOperationExpiresDuringTransaction() = runBlocking {
        database.dao().upsertEntry(entry("entry"))
        val gate = AccountOperationGate()
        val reader = JigsawRecordsReader(context, database, gate.capture())
        onQuery = { sql -> if (sql.startsWith("SELECT * FROM entries")) gate.beginTransition() }
        assertCancelled { reader.read(day, day + 1) }
    }

    @Test fun should_discardRange_whenOperationExpiresDuringAggregateQuery() = runBlocking {
        database.dao().upsertEntry(entry("entry"))
        val gate = AccountOperationGate()
        val reader = JigsawRecordsReader(context, database, gate.capture())
        onQuery = { sql -> if (sql.contains("COUNT(*)") && sql.contains("FROM entries")) gate.beginTransition() }
        assertCancelled { reader.range() }
    }

    private suspend fun assertCancelled(block: suspend () -> Unit) {
        try {
            block()
            fail("失效凭证不得返回数据")
        } catch (_: CancellationException) { }
    }

    private fun entry(id: String, savedDay: Long = day): MosaicEntry = MosaicEntry(
        id = id, day = savedDay, zoneId = "Asia/Shanghai", createdAt = 1L, updatedAt = 1L,
        habitId = null, habitTitle = null, text = "保存的日记", mediaId = null,
        shape = "circle", focusX = .5f, focusY = .5f, zoom = 1f, mutationId = id,
    )
}
