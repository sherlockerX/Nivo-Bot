package io.github.nanomuse.todo

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.mosaic.MosaicDatabase
import io.github.nanomuse.mosaic.MosaicDraft
import io.github.nanomuse.mosaic.MosaicStore
import java.time.LocalDate
import java.util.UUID
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.async
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 内存Room验证持久幂等与跨领域事务，不触碰真实日记和任务。 */
@RunWith(AndroidJUnit4::class)
class TodoStoreInstrumentedTest {
    private lateinit var context: Context
    private lateinit var database: MosaicDatabase
    private lateinit var store: TodoStore
    private val today = LocalDate.now()

    @Before fun prepare() {
        context = ApplicationProvider.getApplicationContext()
        check(context.packageName.endsWith(".uitest")) { "只允许隔离测试包" }
        database = Room.inMemoryDatabaseBuilder(context, MosaicDatabase::class.java).build()
        store = TodoStore(context, database, AccountData.key(context), AccountData.epoch.value)
    }

    @After fun close() { database.close() }

    @Test fun should_rejectEveryStaleToolMutation_andKeepCommittedTask() = runBlocking {
        val initial = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "首次内容"), "tool-create")
        val edited = store.saveTask(initial.copy(title = "手机修改后的内容"), "phone-edit")
        val bridge = TodoAgentBridge(TodoStoreToolStorage(store))
        val user = TodoToolUser("test-user", "这条任务已经完成了", "test-main")
        listOf("update", "start", "complete", "reopen", "delete").forEach { action ->
            val args = org.json.JSONObject().put("action", action).put("operationId", "stale-$action")
                .put("targetId", initial.id).put("expectedRevision", initial.revision)
            if (action == "update") args.put("payload", """{"title":"不应覆盖"}""")
            if (action == "complete") args.put("userQuote", user.text)
            val result = bridge.command(args.toString(), user)
            assertFalse("$action: ${result.output}", result.success)
            assertEquals("stale_revision", org.json.JSONObject(result.output).optString("code"))
            assertEquals(edited, store.task(initial.id))
            assertNull(database.todoDao().operation(store.ownerKey, "stale-$action"))
        }
    }

    @Test fun should_replayExactToolUpdate_withoutOverwritingLaterEdit() = runBlocking {
        val initial = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "首次内容"), "replay-create")
        val bridge = TodoAgentBridge(TodoStoreToolStorage(store))
        val user = TodoToolUser("test-user", "修改任务标题", "test-main")
        val args = org.json.JSONObject().put("action", "update").put("operationId", "original-tool-update")
            .put("targetId", initial.id).put("expectedRevision", initial.revision)
            .put("payload", """{"title":"工具修改"}""")
        val first = bridge.command(args.toString(), user)
        assertTrue(first.output, first.success)
        val firstSaved = requireNotNull(store.task(initial.id))
        val newer = store.saveTask(firstSaved.copy(title = "手机后续修改"), "phone-later")
        val replayed = bridge.command(args.toString(), user)
        assertTrue(replayed.output, replayed.success)
        assertEquals(first.output, replayed.output)
        assertEquals(newer, store.task(initial.id))
        assertFalse(bridge.command(args.put("payload", """{"title":"相同操作ID偷换内容"}""").toString(), user).success)
        assertEquals(newer, store.task(initial.id))
    }

    @Test fun should_rejectConcurrentEditBetweenToolReadAndSave() = runBlocking {
        val initial = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "首次内容"), "race-create")
        val adapter = TodoStoreToolStorage(store)
        var committed: TodoTask? = null
        val racing = object : TodoToolStorage by adapter {
            override suspend fun taskForUpdate(id: String, expectedRevision: Long, operationId: String): TodoTask? {
                val snapshot = adapter.taskForUpdate(id, expectedRevision, operationId)
                committed = store.saveTask(requireNotNull(snapshot).copy(title = "抢先保存"), "race-winner")
                return snapshot
            }
        }
        val args = org.json.JSONObject().put("action", "update").put("operationId", "race-loser")
            .put("targetId", initial.id).put("expectedRevision", initial.revision).put("payload", """{"title":"过期覆盖"}""")
        val result = TodoAgentBridge(racing).command(args.toString(), TodoToolUser("test-user", "修改标题", "test-main"))
        assertFalse(result.output, result.success)
        assertEquals("stale_revision", org.json.JSONObject(result.output).optString("code"))
        assertEquals(committed, store.task(initial.id))
    }

    @Test fun should_persistIdempotenceAndRejectStaleRevision() = runBlocking {
        val request = TodoTask(ownerKey = store.ownerKey, title = "实验记录")
        val first = store.saveTask(request, "create")
        val recreated = TodoStore(context, database, store.ownerKey, store.ownerEpoch)
        assertEquals(first, recreated.saveTask(request, "create"))
        assertEquals(1, store.tasks().size)
        assertTrue(runCatching { store.saveTask(request.copy(title = "不同请求"), "create") }.isFailure)
        val completed = store.changeStatus(first.id, "done", first.revision, "complete", today.toEpochDay())
        assertEquals(completed, store.changeStatus(first.id, "done", first.revision, "complete", today.toEpochDay()))
        assertTrue(runCatching { store.saveTask(first.copy(title = "旧编辑"), "stale") }.isFailure)
        assertEquals("done", store.task(first.id)?.status)
        val reopened = store.changeStatus(first.id, "in_progress", completed.revision, "reopen")
        assertNull(reopened.completedDay)
        store.deleteTask(first.id, reopened.revision, "delete")
        store.deleteTask(first.id, reopened.revision, "delete")
        assertNull(store.task(first.id))
    }

    @Test fun should_rollbackDiaryAndFirstTask_when_secondSelectionIsStale() = runBlocking {
        val first = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "第一项"), "one")
        val second = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "第二项"), "two")
        val diary = MosaicStore(context, database)
        val draft = draft("atomic")
        val selections = listOf(TodoSelection(first.id, first.revision, "done", today.toEpochDay()),
            TodoSelection(second.id, second.revision + 1, "done", today.toEpochDay()))
        diary.putDraftWithTasks(draft, selections, store)
        assertTrue(runCatching { diary.saveWithTasks(draft, today, selections, store) }.isFailure)
        assertNull(database.dao().entryByMutation(draft.mutationId))
        assertEquals("todo", store.task(first.id)?.status)
        assertNotNull(database.dao().draft(draft.id))
        assertEquals(2, store.draftLinks(draft.id).size)
    }

    @Test fun should_keepCompletionOnce_when_multipleFragmentsReferToTask() = runBlocking {
        val task = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "阅读", tagsJson = "[\"成长\"]"), "one")
        val diary = MosaicStore(context, database)
        val draft = draft("first")
        val selections = listOf(TodoSelection(task.id, task.revision, "done", today.toEpochDay()))
        val entry = requireNotNull(diary.saveWithTasks(draft, today, selections, store))
        assertEquals(entry.id, diary.saveWithTasks(draft, today, selections, store)?.id)
        val done = requireNotNull(store.task(task.id))
        val same = store.changeStatus(task.id, "done", done.revision, "same-status", today.minusDays(1).toEpochDay())
        assertEquals(done, same)
        assertEquals(same, store.changeStatus(task.id, "done", done.revision, "same-status", today.minusDays(1).toEpochDay()))
        diary.saveWithTasks(draft("second"), today, listOf(TodoSelection(task.id, done.revision, "done")), store)
        assertEquals(done.completedAt, store.task(task.id)?.completedAt)
        assertEquals(2, store.taskLinks(task.id).size)
        diary.delete(entry.id)
        assertEquals("done", store.task(task.id)?.status)
        assertEquals(1, store.taskLinks(task.id).size)
        diary.restore(entry.id)
        assertEquals(2, store.taskLinks(task.id).size)
        assertEquals(1, TodoStatistics.calculate(store.tasks(), today.toEpochDay(), today.plusDays(1).toEpochDay()).completedCount)
    }

    @Test fun should_moveAndDiscardDraftLinks_withDiaryDraft() = runBlocking {
        val task = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "阅读"), "one")
        val diary = MosaicStore(context, database)
        val draft = draft("redate")
        diary.putDraftWithTasks(draft, listOf(TodoSelection(task.id, task.revision)), store)
        val moved = diary.redate(draft, today.minusDays(1).toEpochDay())
        assertTrue(store.draftLinks(draft.id).isEmpty())
        assertEquals(task.id, store.draftLinks(moved.id).single().taskId)
        diary.discardDraft(moved)
        assertTrue(store.draftLinks(moved.id).isEmpty())
    }

    @Test fun should_hideForeignOwnerAndRejectStaleEpoch() = runBlocking {
        val task = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "自己的"), "one")
        database.todoDao().putTask(task.copy(ownerKey = "different-owner", title = "别人的"))
        assertEquals(listOf("自己的"), store.tasks().map { it.title })
        val stale = TodoStore(context, database, store.ownerKey, store.ownerEpoch - 1)
        assertTrue(runCatching { stale.tasks() }.isFailure)
        assertTrue(runCatching { stale.saveTask(task.copy(title = "旧页面"), "stale") }.isFailure)
    }

    @Test fun should_importAtomicallyAndNotInventMissingDiaryLinks() = runBlocking {
        store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "备份"), "one")
        val exported = org.json.JSONObject(store.exportJson())
        val source = exported.getJSONArray("tasks").getJSONObject(0)
        source.put("id", "imported").put("ownerKey", "another-owner")
        exported.getJSONArray("links").put(org.json.JSONObject().put("entryId", "missing")
            .put("taskId", "imported").put("title", "备份").put("statusSnapshot", "todo").put("linkedAt", 1))
        val report = store.importJsonDetailed(exported.toString())
        assertEquals(1, report.importedCount)
        assertEquals(1, report.missingEntryCount)
        assertEquals(report, store.importJsonDetailed(exported.toString()))
        assertEquals(store.ownerKey, store.task("imported")?.ownerKey)
        assertTrue(store.taskLinks("imported").isEmpty())
    }

    @Test fun should_allowTextEditButRejectNewIntent_when_linkedTaskWasDeleted() = runBlocking {
        val task = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "历史任务"), "one")
        val diary = MosaicStore(context, database)
        val original = draft("original")
        val entry = requireNotNull(diary.saveWithTasks(original, today, listOf(TodoSelection(task.id, task.revision)), store))
        store.deleteTask(task.id, task.revision, "delete")
        val edit = original.copy(id = "entry:${entry.id}", entryId = entry.id, text = "更新日记")
        val historical = listOf(TodoSelection(task.id, -1))
        diary.putDraftWithTasks(edit, historical, store)
        diary.saveWithTasks(edit, today, historical, store)
        assertEquals("更新日记", database.dao().entry(entry.id)?.text)
        assertEquals("历史任务", store.entryLinks(entry.id).single().title)
        val failure = runCatching { diary.saveWithTasks(edit, today, listOf(TodoSelection(task.id, -1, "done")), store) }.exceptionOrNull()
        assertEquals(io.github.nanomuse.mosaic.MosaicSaveException.Reason.TASK_CONFLICT,
            (failure as io.github.nanomuse.mosaic.MosaicSaveException).reason)
        diary.saveWithTasks(edit, today, emptyList(), store)
        assertTrue(store.entryLinks(entry.id).isEmpty())
    }

    @Test fun should_serializeTransitionAndRejectQueuedOldOwnerMutation() = runBlocking {
        withTimeout(10_000) {
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val write = async { store.transaction { entered.complete(Unit); release.await() } }
            entered.await()
            val transitionStarted = CompletableDeferred<Unit>()
            val transition = async {
                transitionStarted.complete(Unit)
                AccountData.withTransition { }
            }
            transitionStarted.await()
            yield()
            assertFalse(transition.isCompleted)
            release.complete(Unit)
            write.await()
            transition.await()
            assertTrue(runCatching { store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "过期请求"), "late") }.isFailure)
            assertTrue(database.todoDao().tasks(store.ownerKey).isEmpty())
        }
    }

    @Test fun should_keepExistingTasksAndRejectFutureCompletionBeforeWriting() = runBlocking {
        val task = store.saveTask(TodoTask(ownerKey = store.ownerKey, title = "本地优先"), "one")
        val exported = org.json.JSONObject(store.exportJson())
        exported.getJSONArray("tasks").getJSONObject(0).put("title", "旧备份")
        val kept = store.importJsonDetailed(exported.toString())
        assertEquals(0, kept.importedCount)
        assertEquals(1, kept.keptLocalCount)
        assertEquals("本地优先", store.task(task.id)?.title)
        exported.getJSONArray("tasks").getJSONObject(0).put("id", "future")
            .put("status", "done").put("completedDay", today.plusDays(1).toEpochDay())
            .put("completedAt", System.currentTimeMillis())
        assertTrue(runCatching { store.importJsonDetailed(exported.toString()) }.isFailure)
        assertNull(store.task("future"))
    }

    @Test fun should_restoreLedgerAndEvents_when_importingIntoEmptyStore() = runBlocking {
        val request = TodoTask(ownerKey = store.ownerKey, title = "完整恢复", tagsJson = "[\"成长\"]")
        val created = store.saveTask(request, "create-restored")
        val done = store.changeStatus(created.id, "done", created.revision, "done-restored", today.toEpochDay())
        val backup = store.exportJson()
        val freshDatabase = Room.inMemoryDatabaseBuilder(context, MosaicDatabase::class.java).build()
        try {
            val fresh = TodoStore(context, freshDatabase, store.ownerKey, store.ownerEpoch)
            assertEquals(1, fresh.importJson(backup))
            assertEquals(created, fresh.saveTask(request, "create-restored"))
            assertEquals(done, fresh.changeStatus(created.id, "done", created.revision, "done-restored", today.toEpochDay()))
            assertEquals(done, fresh.task(created.id))
            assertEquals(2, freshDatabase.todoDao().events(store.ownerKey).size)
        } finally { freshDatabase.close() }
    }

    private fun draft(id: String): MosaicDraft = MosaicDraft(id = id, day = today.toEpochDay(),
        habitId = null, entryId = null, text = "测试文字", mediaId = null, stagedPath = null,
        shape = "rounded", focusX = .5f, focusY = .5f, zoom = 1f, markDone = false,
        mood = null, mutationId = UUID.randomUUID().toString(), updatedAt = 1)
}
