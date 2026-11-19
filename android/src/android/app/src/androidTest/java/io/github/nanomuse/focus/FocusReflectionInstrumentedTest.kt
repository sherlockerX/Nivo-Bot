package io.github.nanomuse.focus

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.mosaic.MosaicDatabase
import io.github.nanomuse.mosaic.MosaicStore
import io.github.nanomuse.todo.TodoSelection
import io.github.nanomuse.todo.TodoStore
import io.github.nanomuse.todo.TodoTask
import io.github.nanomuse.ui.focus.FocusReflectionRequest
import io.github.nanomuse.ui.focus.FocusReflectionNavigation
import io.github.nanomuse.ui.home.HomeBus
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

/** 在隔离内存库验证心得草稿初始化、用户选择优先和账号边界。 */
@RunWith(AndroidJUnit4::class)
class FocusReflectionInstrumentedTest {
    private lateinit var context: Context
    private lateinit var database: MosaicDatabase
    private lateinit var focus: FocusStore
    private lateinit var todo: TodoStore
    private lateinit var mosaic: MosaicStore
    private var hasPrepared = false
    private val clock = ReflectionClock()

    @Before fun prepare() = runBlocking<Unit> {
        context = ApplicationProvider.getApplicationContext()
        check(context.packageName.endsWith(".uitest"))
        // 内存夹具仍使用应用闹钟，已有活动计时时拒绝测试，避免覆盖其提醒。
        val sharedFocus = FocusStore.get(context)
        check(sharedFocus.transaction { sharedFocus.dao.active(sharedFocus.ownerKey) } == null) {
            "测试包已有活动专注，请先结束该计时"
        }
        database = Room.inMemoryDatabaseBuilder(context, MosaicDatabase::class.java).build()
        focus = FocusStore(context, database, AccountData.key(context), AccountData.epoch.value, clock)
        todo = TodoStore(context, database, focus.ownerKey, focus.ownerEpoch)
        mosaic = MosaicStore(context, database)
        hasPrepared = true
        HomeBus.focusReflection.value?.let(HomeBus::handledFocusReflection)
    }

    @After fun close() {
        try {
            // 包名或活动计时检查失败时，JUnit仍会清理；此时不能操作应用全局状态。
            if (hasPrepared && ::context.isInitialized && context.packageName.endsWith(".uitest")) {
                HomeBus.focusReflection.value?.let(HomeBus::handledFocusReflection)
                FocusAlarm.schedule(context, null)
            }
        } finally {
            if (::database.isInitialized) database.close()
        }
    }

    /** 自然结束跨午夜，以结束日建稿，并保留任务原状态与版本。 */
    @Test fun should_seedEndDayAndLinks_withoutCompletingTask() = runBlocking {
        val task = todo.saveTask(TodoTask(ownerKey = focus.ownerKey, title = "阅读"), "task")
        val started = focus.command("start", "start", taskId = task.id, minutes = 1)
        clock.advance(60_000)
        val finished = focus.sessions().single()
        assertEquals("finished", finished.status)
        val draft = FocusReflectionDrafts.open(focus, todo, mosaic, started.id, ZoneId.of("UTC"))
        assertEquals(LocalDate.of(2026, 11, 16).toEpochDay(), draft.day)
        assertEquals(listOf(started.id), focus.draftLinks(draft.id))
        assertEquals(listOf(TodoSelection(task.id, task.revision)), todo.draftLinks(draft.id))
        assertEquals(task, todo.task(task.id))
        assertEquals("", draft.text)
    }

    /** 重复进入不覆盖正文、改期或用户取消的关联，也不复写当天普通草稿。 */
    @Test fun should_restoreUserDraft_withoutMergingIntoFreeDraft() = runBlocking {
        val finished = finishSession()
        val original = FocusReflectionDrafts.open(focus, todo, mosaic, finished.id)
        val free = original.copy(id = MosaicStore.draftId(original.day, null, null), text = "当天原有草稿")
        mosaic.putDraft(free)
        val edited = original.copy(text = "保留我的心得", day = original.day - 1)
        mosaic.putDraftWithTasks(edited, emptyList(), todo, emptyList(), focus)
        val restored = FocusReflectionDrafts.open(focus, todo, mosaic, finished.id)
        assertEquals(edited, restored)
        assertTrue(focus.draftLinks(restored.id).isEmpty())
        assertEquals(free, mosaic.draft(free.id))
    }

    /** 无任务或任务在专注结束前删除时，仍可关联本次真实专注。 */
    @Test fun should_skipDeletedTask_andKeepFocus() = runBlocking {
        val task = todo.saveTask(TodoTask(ownerKey = focus.ownerKey, title = "已删除任务"), "task")
        val started = focus.command("start", "start", taskId = task.id)
        val finished = focus.command("finish", "finish", started.id, started.revision)
        todo.deleteTask(task.id, task.revision, "delete")
        val draft = FocusReflectionDrafts.open(focus, todo, mosaic, finished.id)
        assertTrue(todo.draftLinks(draft.id).isEmpty())
        assertEquals(listOf(finished.id), focus.draftLinks(draft.id))
    }

    /** 并发双击只产生一份草稿及同一提交ID。 */
    @Test fun should_reuseOneDraft_whenOpeningConcurrently() = runBlocking {
        val finished = finishSession()
        val results = List(2) { async { FocusReflectionDrafts.open(focus, todo, mosaic, finished.id) } }.awaitAll()
        assertEquals(results.first(), results.last())
        assertEquals(listOf(finished.id), focus.draftLinks(results.first().id))
    }

    /** 非完成、休息和删除记录不能新建心得，不以传入ID伪造专注事实。 */
    @Test fun should_rejectIneligibleSessions_withoutCreatingDraft() = runBlocking {
        val started = focus.command("start", "start", title = "进行中")
        assertTrue(runCatching { FocusReflectionDrafts.open(focus, todo, mosaic, started.id) }.isFailure)
        val finished = focus.command("finish", "finish", started.id, started.revision)
        focus.command("delete", "delete", finished.id, finished.revision)
        assertTrue(runCatching { FocusReflectionDrafts.open(focus, todo, mosaic, finished.id) }.isFailure)
        val rest = focus.command("start", "rest", title = "休息", mode = "break")
        focus.command("finish", "rest-finish", rest.id, rest.revision)
        assertTrue(runCatching { FocusReflectionDrafts.open(focus, todo, mosaic, rest.id) }.isFailure)
        assertNull(mosaic.draft(FocusReflectionDrafts.draftId(focus.ownerKey, started.id)))
        assertNull(mosaic.draft(FocusReflectionDrafts.draftId(focus.ownerKey, rest.id)))
    }

    /** 旧代次写入失败，同名专注在不同账号产生不同草稿键。 */
    @Test fun should_rejectOldEpoch_andSeparateDraftOwners() = runBlocking {
        val finished = finishSession()
        val stale = FocusStore(context, database, focus.ownerKey, focus.ownerEpoch - 1, clock)
        assertTrue(runCatching { FocusReflectionDrafts.open(stale, todo, mosaic, finished.id) }.isFailure)
        val id = FocusReflectionDrafts.draftId(focus.ownerKey, finished.id)
        assertTrue(FocusReflectionDrafts.belongsToOwner(id, focus.ownerKey))
        assertFalse(FocusReflectionDrafts.belongsToOwner(id, "other-owner"))
        assertNotEquals(id, FocusReflectionDrafts.draftId("other-owner", finished.id))
        assertNull(mosaic.draft(id))
    }

    /** 保存关联不会推进任务；同一草稿重复提交只返回原有碎片。 */
    @Test fun should_saveOneEntry_withoutTaskCompletionOrDraftResurrection() = runBlocking {
        val task = todo.saveTask(TodoTask(ownerKey = focus.ownerKey, title = "实验"), "task")
        val started = focus.command("start", "start", taskId = task.id)
        val finished = focus.command("finish", "finish", started.id, started.revision)
        val draft = FocusReflectionDrafts.open(focus, todo, mosaic, finished.id)
        val tasks = todo.draftLinks(draft.id)
        val focusIds = focus.draftLinks(draft.id)
        val today = LocalDate.ofEpochDay(draft.day)
        val first = mosaic.saveWithTasks(draft, today, tasks, todo, focusIds, focus)
        val second = mosaic.saveWithTasks(draft, today, tasks, todo, focusIds, focus)
        assertNotNull(first)
        assertEquals(first?.id, second?.id)
        assertEquals(task, todo.task(task.id))
        assertNull(mosaic.draft(draft.id))
        assertTrue(focus.draftLinks(draft.id).isEmpty())
    }

    /** 待处理请求不被双击覆盖，旧消费回调不能清除下一个请求。 */
    @Test fun should_consumeOnlyMatchingReflectionRequest() {
        val first = FocusReflectionRequest(focus.ownerKey, focus.ownerEpoch, "first")
        val second = FocusReflectionRequest(focus.ownerKey, focus.ownerEpoch, "second")
        HomeBus.showFocusReflection(first)
        HomeBus.showFocusReflection(second)
        assertEquals(first, HomeBus.focusReflection.value)
        HomeBus.handledFocusReflection(first)
        assertNull(HomeBus.focusReflection.value)
        HomeBus.showFocusReflection(second)
        HomeBus.handledFocusReflection(first)
        assertEquals(second, HomeBus.focusReflection.value)
    }

    /** Intent一次性参数移除，已处理凭证在重建后以及外国账号下都不能重开。 */
    @Test fun should_notReplayConsumedIntent_orAcceptForeignOwner() {
        val requestId = UUID.randomUUID().toString()
        val launch = reflectionIntent(focus.ownerKey, requestId)
        assertTrue(FocusReflectionNavigation.consume(context, launch))
        assertEquals(requestId, HomeBus.focusReflection.value?.requestId)
        val pending = checkNotNull(HomeBus.focusReflection.value)
        HomeBus.handledFocusReflection(pending)
        FocusReflectionNavigation.rememberHandled(requestId)
        assertFalse(FocusReflectionNavigation.consume(context, launch))
        val state = Bundle()
        FocusReflectionNavigation.saveState(state)
        assertTrue(FocusReflectionNavigation.consume(context, reflectionIntent(focus.ownerKey, requestId), state))
        assertNull(HomeBus.focusReflection.value)
        assertTrue(FocusReflectionNavigation.consume(context, reflectionIntent("foreign-owner", UUID.randomUUID().toString())))
        assertNull(HomeBus.focusReflection.value)
    }

    /** 页面尚未就绪时被重建，已移除Intent参数的待处理请求仍可从状态恢复一次。 */
    @Test fun should_restorePendingRequest_whenActivityRecreatesBeforeNavigation() {
        val request = FocusReflectionRequest(focus.ownerKey, focus.ownerEpoch, "pending")
        HomeBus.showFocusReflection(request)
        val state = Bundle()
        FocusReflectionNavigation.saveState(state)
        HomeBus.handledFocusReflection(request)
        assertTrue(FocusReflectionNavigation.consume(context, Intent(), state))
        assertEquals(request, HomeBus.focusReflection.value)
        HomeBus.handledFocusReflection(request)
        FocusReflectionNavigation.rememberHandled(request.requestId)
        val completedState = Bundle()
        FocusReflectionNavigation.saveState(completedState)
        assertFalse(FocusReflectionNavigation.consume(context, Intent(), completedState))
    }

    private fun reflectionIntent(owner: String, requestId: String): Intent = Intent()
        .putExtra("nm_reflection_owner", owner)
        .putExtra("nm_reflection_epoch", focus.ownerEpoch)
        .putExtra("nm_reflection_session", "session")
        .putExtra("nm_reflection_request", requestId)

    private suspend fun finishSession(): FocusSession {
        val started = focus.command("start", "start", title = "独立专注")
        clock.advance(1_000)
        return focus.command("finish", "finish", started.id, started.revision)
    }

    /** 固定墙钟跨午夜，单调时钟照常推进，避免测试依赖真实日期与等待。 */
    private class ReflectionClock : FocusClockSource {
        private var wallTime = Instant.parse("2026-11-15T23:59:30Z").toEpochMilli()
        private var elapsedTime = 1_000L
        override fun wall(): Long = wallTime
        override fun elapsed(): Long = elapsedTime
        override fun boot(): Int = 1
        fun advance(milliseconds: Long) { wallTime += milliseconds; elapsedTime += milliseconds }
    }
}
