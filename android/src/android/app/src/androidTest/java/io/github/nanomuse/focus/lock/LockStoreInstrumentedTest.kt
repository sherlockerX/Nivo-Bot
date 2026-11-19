package io.github.nanomuse.focus.lock

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.focus.FocusAgentBridge
import io.github.nanomuse.focus.FocusAlarm
import io.github.nanomuse.focus.FocusClockSource
import io.github.nanomuse.focus.FocusSession
import io.github.nanomuse.focus.FocusStore
import io.github.nanomuse.mosaic.MosaicDatabase
import io.github.nanomuse.todo.TodoConflictException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 通过真实Room及可控设备时钟验证锁机事务，不触发守护或真实锁屏。 */
@RunWith(AndroidJUnit4::class)
class LockStoreInstrumentedTest {
    private lateinit var context: Context
    private lateinit var database: MosaicDatabase
    private lateinit var clock: TestClock
    private lateinit var focus: FocusStore
    private lateinit var locks: LockStore

    /** 所有数据写入隔离测试包的内存库，账号边界仍使用实际AccountData。 */
    @Before
    fun prepare() {
        context = ApplicationProvider.getApplicationContext()
        check(context.packageName.endsWith(".uitest")) { "只允许隔离测试包" }
        database = Room.inMemoryDatabaseBuilder(context, MosaicDatabase::class.java).build()
        clock = TestClock()
        val owner = AccountData.key(context)
        val epoch = AccountData.epoch.value
        focus = FocusStore(context, database, owner, epoch, clock)
        locks = LockStore(context, database, owner, epoch, clock)
    }

    /** 清理测试可能创建的普通计时提醒和独立数据库。 */
    @After
    fun close() {
        FocusAlarm.schedule(context, null)
        database.close()
    }

    /** 强制开始会结束普通计时，并保留真实已用时而非预设时长。 */
    @Test
    fun should_settleOrdinaryTimer_when_startingForcedRun() = runBlocking {
        val ordinary = focus.command("start", "ordinary-start", title = "普通阅读", minutes = 25)
        clock.tick(38_072L)
        val run = locks.start(title = "强制阅读", durationMs = 120_000L)

        val ended = session(ordinary.id)
        assertEquals("finished", ended.status)
        assertEquals(38_072L, ended.elapsedMs)
        assertEquals(clock.wall(), ended.endedAt)
        assertEquals(38_072L, spans(ordinary.id))
        assertNotEquals(ordinary.id, run.sessionId)
        assertEquals(run.sessionId, database.focusDao().active(focus.ownerKey)?.id)
        assertEquals(120_000L, session(run.sessionId).targetMs)
        assertEquals(0L, session(run.sessionId).elapsedMs)
        assertEquals(run, locks.active())
    }

    /** 已暂停的普通计时不能把等待时间计入被替换记录。 */
    @Test
    fun should_preservePausedDuration_when_startingForcedRun() = runBlocking {
        val ordinary = focus.command("start", "ordinary-start", title = "普通阅读")
        clock.tick(5_000L)
        val paused = focus.command("pause", "ordinary-pause", ordinary.id, ordinary.revision)
        clock.tick(300_000L)
        locks.start(title = "强制阅读", durationMs = 60_000L)

        assertEquals("finished", session(ordinary.id).status)
        assertEquals(paused.elapsedMs, session(ordinary.id).elapsedMs)
        assertEquals(5_000L, spans(ordinary.id))
    }

    /** 所有普通修改入口都返回固定拒绝，且失败操作不写入幂等账本。 */
    @Test
    fun should_rejectCommandsWithoutMutatingLedger_when_lockIsActive() = runBlocking {
        val run = locks.start(title = "强制阅读", durationMs = 120_000L)
        val before = session(run.sessionId)
        for (action in listOf("pause", "finish", "delete", "resume", "start")) {
            assertLocked {
                focus.command(action, "blocked-$action", before.id, before.revision, title = "不可开始")
            }
            assertNull(database.focusDao().operation(focus.ownerKey, "blocked-$action"))
        }
        assertEquals(before, session(run.sessionId))
        assertEquals(run.id, locks.active()?.id)
        assertEquals(0L, spans(run.sessionId))
    }

    /** 拒绝必须早于历史操作读取，旧暂停、结束、删除回执也不能绕过活动锁。 */
    @Test
    fun should_rejectExactOperationReplay_when_lockStartedLater() = runBlocking {
        val ordinary = focus.command("start", "ordinary-start", title = "普通阅读")
        clock.tick(2_000L)
        val paused = focus.command("pause", "ordinary-pause", ordinary.id, ordinary.revision)
        val ended = focus.command("finish", "ordinary-finish", paused.id, paused.revision)
        val deleted = focus.command("delete", "ordinary-delete", ended.id, ended.revision)
        val run = locks.start(title = "强制阅读", durationMs = 60_000L)

        assertLocked { focus.command("pause", "ordinary-pause", ordinary.id, ordinary.revision) }
        assertLocked { focus.command("finish", "ordinary-finish", paused.id, paused.revision) }
        assertLocked { focus.command("delete", "ordinary-delete", ended.id, ended.revision) }
        assertEquals(deleted, session(ordinary.id))
        assertEquals(run.id, locks.active()?.id)
    }

    /** AI工具获得与界面相同的固定错误码，目标会话保持运行。 */
    @Test
    fun should_returnFixedErrorThroughAgentBridge_when_finishIsBlocked() = runBlocking {
        val run = locks.start(title = "强制阅读", durationMs = 60_000L)
        val active = session(run.sessionId)
        val arguments = JSONObject().put("action", "finish").put("operationId", "agent-finish")
            .put("targetId", active.id).put("expectedRevision", active.revision)
        val result = FocusAgentBridge(focus) {}.execute(FocusAgentBridge.COMMAND, arguments.toString())

        assertFalse(result.success)
        assertEquals("focus_locked", JSONObject(result.output).getString("code"))
        assertEquals("running", session(run.sessionId).status)
        assertNull(database.focusDao().operation(focus.ownerKey, "agent-finish"))
    }

    /** 每15秒提交检查点，同一时钟重复心跳不会重复累计区间。 */
    @Test
    fun should_checkpointOncePerInterval_when_heartbeatsRepeat() = runBlocking {
        val run = locks.start(title = "强制阅读", durationMs = 60_000L)
        clock.tick(14_999L)
        locks.checkpoint()
        assertEquals(0L, session(run.sessionId).elapsedMs)
        clock.tick(1L)
        val checkpoint = checkNotNull(locks.checkpoint())
        assertEquals(45_000L, checkpoint.checkpointRemainingMs)
        assertEquals(15_000L, session(run.sessionId).elapsedMs)
        assertEquals(15_000L, spans(run.sessionId))
        locks.checkpoint()
        locks.checkpoint()
        assertEquals(15_000L, spans(run.sessionId))
        assertEquals(1, database.focusDao().allSpans(focus.ownerKey).size)
    }

    /** 到时后一次性完成锁定和专注，晚来的心跳也不能多记时长。 */
    @Test
    fun should_completeBothRowsAndReleaseCommands_when_deadlinePasses() = runBlocking {
        val run = locks.start(title = "强制阅读", durationMs = 60_000L)
        clock.tick(90_000L)
        assertNull(locks.checkpoint())
        val ended = session(run.sessionId)
        assertEquals("finished", ended.status)
        assertEquals(60_000L, ended.elapsedMs)
        assertEquals(run.deadlineAt, ended.endedAt)
        assertEquals(LockRunStatus.COMPLETED, locks.runs().single().status)
        assertEquals(run.deadlineAt, locks.runs().single().endedAt)
        assertEquals(60_000L, spans(run.sessionId))
        locks.checkpoint()
        assertEquals(60_000L, spans(run.sessionId))

        val deleted = focus.command("delete", "after-lock-delete", ended.id, ended.revision)
        assertNotNull(deleted.deletedAt)
        assertEquals("running", focus.command("start", "after-lock-start", title = "普通阅读").status)
    }

    /** 强制正计时由用户结束：保存真实计时，会话完成且解除锁定；倒计时不能走这条路提前结束。 */
    @Test
    fun should_saveMeasuredTimeAndRelease_when_userEndsForcedStopwatch() = runBlocking {
        val run = locks.start(title = "强制正计时", durationMs = FocusStore.MAX_SESSION_MS, mode = "stopwatch")
        assertEquals("stopwatch", session(run.sessionId).mode)
        clock.tick(95_000L)
        val ended = locks.finishStopwatch(run.id)
        assertEquals(LockRunStatus.COMPLETED, ended?.status)
        assertNull(locks.active())
        val saved = session(run.sessionId)
        assertEquals("finished", saved.status)
        assertEquals(95_000L, saved.elapsedMs)
        assertEquals(clock.wall(), saved.endedAt)
        assertEquals(95_000L, spans(run.sessionId))
        assertEquals("running", focus.command("start", "after-stopwatch", title = "普通阅读").status)

        // 强制开始会结束这条普通计时；倒计时锁不能用结束正计时的入口提前解除。
        val fixed = locks.start(title = "强制阅读", durationMs = 60_000L)
        val refused = runCatching { locks.finishStopwatch(fixed.id) }
        assertTrue(refused.exceptionOrNull()?.message == "lock_not_stopwatch")
        assertEquals(fixed.id, locks.active()?.id)
    }

    /** 普通命令入口自行结算到时状态，不依赖先运行一次服务心跳。 */
    @Test
    fun should_releaseFromCommandEntry_when_noHeartbeatRanAtDeadline() = runBlocking {
        val run = locks.start(title = "强制阅读", durationMs = 60_000L)
        clock.tick(60_000L)
        val ordinary = focus.command("start", "after-deadline-start", title = "下一段阅读")
        assertNotEquals(run.sessionId, ordinary.id)
        assertEquals("finished", session(run.sessionId).status)
        assertEquals(60_000L, spans(run.sessionId))
        assertNull(locks.active())
    }

    /** 同次开机只信单调推进，调整墙钟不能提前完成或延长锁定。 */
    @Test
    fun should_useMonotonicClock_when_wallClockChanges() = runBlocking {
        val run = locks.start(title = "强制阅读", durationMs = 60_000L)
        clock.wallTime += 3_600_000L
        clock.tick(20_000L)
        assertEquals(40_000L, locks.checkpoint()?.checkpointRemainingMs)
        assertEquals("running", session(run.sessionId).status)
        clock.wallTime -= 7_200_000L
        clock.tick(40_000L)
        assertNull(locks.checkpoint())
        assertEquals(60_000L, session(run.sessionId).elapsedMs)
        assertEquals(60_000L, spans(run.sessionId))
    }

    /** 拒绝操作回滚后，未知启动号仍需信任同一进程已有的单调基准。 */
    @Test
    fun should_keepProcessClockAfterRollback_when_rejectedCommandCheckpointed() = runBlocking {
        clock.bootCount = -1
        val run = locks.start(title = "强制阅读", durationMs = 60_000L)
        val initial = session(run.sessionId)
        clock.tick(20_000L)
        assertLocked { focus.command("pause", "blocked-after-checkpoint", initial.id, initial.revision) }
        clock.wallTime += 3_600_000L

        val stillActive = locks.active()
        assertNotNull("被拒命令不能破坏进程时钟并让调快墙钟提前解除", stillActive)
        assertEquals(run.id, stillActive?.id)
        assertEquals(40_000L, stillActive?.remaining(clock.wall(), clock.elapsed(), LockRun.PROCESS_BOOT_COUNT)?.milliseconds)
        assertEquals("running", session(run.sessionId).status)
    }

    /** 其他账号的同名计划、白名单和运行不会被当前账号读取或修改。 */
    @Test
    fun should_keepOtherOwnerRowsIsolated_when_readingAndUpdating() = runBlocking {
        val currentPlan = locks.savePlan(plan("shared"))
        locks.setWhitelist(setOf("test.reader"))
        val currentRun = locks.start(title = "强制阅读", durationMs = 60_000L)
        val otherOwner = "different-owner:${focus.ownerKey}"
        database.lockDao().putPlan(LockPlanEntity.fromModel(currentPlan.copy(ownerKey = otherOwner), clock.wall()))
        database.lockDao().putWhitelist(listOf(LockWhitelistEntity(otherOwner, "test.foreign", clock.wall())))
        database.focusDao().putSession(session(currentRun.sessionId).copy(ownerKey = otherOwner))
        database.lockDao().putRun(LockRunEntity.fromModel(currentRun.copy(ownerKey = otherOwner)))

        assertEquals(setOf(focus.ownerKey), locks.plans().map { it.ownerKey }.toSet())
        assertEquals(setOf("test.reader"), locks.whitelist())
        assertEquals(setOf(focus.ownerKey), locks.runs().map { it.ownerKey }.toSet())
        locks.setWhitelist(emptySet())
        assertEquals(listOf("test.foreign"), database.lockDao().whitelist(otherOwner).map { it.packageName })
        val wrongOwner = LockStore(context, database, otherOwner, locks.ownerEpoch, clock)
        assertTrue(runCatching { wrongOwner.plans() }.exceptionOrNull() is CancellationException)
        val stale = LockStore(context, database, locks.ownerKey, locks.ownerEpoch - 1L, clock)
        assertTrue(runCatching { stale.setWhitelist(emptySet()) }.exceptionOrNull() is CancellationException)
        assertEquals(currentRun.id, database.lockDao().active(otherOwner)?.id)
    }

    /** 活动计划禁止修改或删除，未来计划仍可编辑；白名单只允许收紧。 */
    @Test
    fun should_allowOnlySafeConfigurationChanges_when_locked() = runBlocking {
        val activePlan = locks.savePlan(plan("active-plan"))
        val futurePlan = locks.savePlan(plan("future-plan"))
        locks.setWhitelist(setOf("test.reader", "test.dictionary"))
        locks.start(title = "强制阅读", durationMs = 60_000L, planIds = setOf(activePlan.id))

        assertLocked { locks.savePlan(activePlan.copy(isEnabled = false), activePlan.revision) }
        assertLocked { locks.deletePlan(activePlan.id, activePlan.revision) }
        val saved = locks.savePlan(futurePlan.copy(name = "未来计划改名"), futurePlan.revision)
        assertEquals(futurePlan.revision + 1, saved.revision)
        assertLocked { locks.setWhitelist(setOf("test.reader", "test.dictionary", "test.video")) }
        assertEquals(setOf("test.reader", "test.dictionary"), locks.whitelist())
        locks.setWhitelist(setOf("test.reader"))
        assertEquals(setOf("test.reader"), locks.whitelist())
    }

    /** 过期页面提交旧修订不能覆盖计划或软删除事实。 */
    @Test
    fun should_rejectStalePlanRevision_when_planChanged() = runBlocking {
        val created = locks.savePlan(plan("revision-plan"))
        val updated = locks.savePlan(created.copy(name = "新名称"), created.revision)
        assertTrue(runCatching {
            locks.savePlan(created.copy(name = "旧页面"), created.revision)
        }.exceptionOrNull() is TodoConflictException)
        locks.deletePlan(updated.id, updated.revision)
        assertTrue(locks.plans().isEmpty())
        assertTrue(runCatching {
            locks.savePlan(created, updated.revision)
        }.exceptionOrNull() is TodoConflictException)
        assertNotNull(database.lockDao().plan(locks.ownerKey, updated.id)?.deletedAt)
    }

    /** 导出保留配置，恢复后计划停用且不生成锁定运行或普通活动计时。 */
    @Test
    fun should_restoreOnlyConfiguration_when_importingFocusBackup() = runBlocking {
        val original = locks.savePlan(plan("backup-plan"))
        locks.setWhitelist(setOf("test.reader", "test.dictionary"))
        val sourceRun = locks.start(
            title = "强制阅读", durationMs = 60_000L,
            planIds = setOf(original.id), occurrenceIds = setOf("saved-occurrence")
        )
        val backup = focus.exportJson()
        val configuration = JSONObject(backup).getJSONObject("lock")
        assertEquals(setOf("format", "version", "plans", "whitelist"), configuration.keys().asSequence().toSet())
        assertFalse(configuration.toString().contains(sourceRun.id))
        assertFalse(configuration.toString().contains("saved-occurrence"))

        val restoredDatabase = Room.inMemoryDatabaseBuilder(context, MosaicDatabase::class.java).build()
        try {
            val restoredFocus = FocusStore(context, restoredDatabase, focus.ownerKey, focus.ownerEpoch, clock)
            val restoredLocks = LockStore(context, restoredDatabase, locks.ownerKey, locks.ownerEpoch, clock)
            assertEquals(1, restoredFocus.importLockConfiguration(backup))
            val restoredPlan = restoredLocks.plans().single()
            assertEquals(original.copy(isEnabled = false), restoredPlan)
            assertEquals(setOf("test.reader", "test.dictionary"), restoredLocks.whitelist())
            assertTrue(restoredLocks.runs().isEmpty())
            assertNull(restoredLocks.active())
            assertTrue(restoredFocus.sessions().isEmpty())
        } finally {
            restoredDatabase.close()
        }
        assertEquals(sourceRun.id, locks.active()?.id)
    }

    /** 活动锁期间即使备份本身合法，也不能通过导入修改配置或解除锁定。 */
    @Test
    fun should_rejectConfigurationImport_when_lockIsActive() = runBlocking {
        val original = locks.savePlan(plan("backup-plan"))
        locks.setWhitelist(setOf("test.reader"))
        val backup = focus.exportJson()
        val run = locks.start(title = "强制阅读", durationMs = 60_000L)
        val error = runCatching { focus.importLockConfiguration(backup) }.exceptionOrNull()
        assertNotNull(error)
        assertEquals("focus_locked", error?.message)
        assertEquals(listOf(original), locks.plans())
        assertEquals(setOf("test.reader"), locks.whitelist())
        assertEquals(run.id, locks.active()?.id)
    }

    /** 开始过程中后续校验失败时，原普通专注及其区间账本必须整体回滚。 */
    @Test
    fun should_rollbackOrdinarySettlement_when_forcedDeadlineOverflows() = runBlocking {
        val ordinary = focus.command("start", "ordinary-start", title = "普通阅读")
        clock.tick(5_000L)
        clock.wallTime = Long.MAX_VALUE - 1L
        assertTrue(runCatching { locks.start(title = "无法开始", durationMs = 60_000L) }.isFailure)
        assertEquals(ordinary, session(ordinary.id))
        assertEquals(0L, spans(ordinary.id))
        assertTrue(database.lockDao().runs(focus.ownerKey).isEmpty())
    }

    private fun plan(id: String) = LockPlan(
        id = id, name = "阅读计划", ownerKey = locks.ownerKey,
        days = setOf(1, 3, 5), ranges = listOf(TimeRange(1380, 60)),
        title = "夜间阅读", usesWhitelist = true
    )

    private suspend fun session(id: String): FocusSession =
        checkNotNull(database.focusDao().session(focus.ownerKey, id))

    private suspend fun spans(id: String): Long =
        database.focusDao().allSpans(focus.ownerKey).filter { it.sessionId == id }.sumOf { it.durationMs }

    private suspend fun assertLocked(block: suspend () -> Any?) {
        val error = runCatching { block() }.exceptionOrNull()
        assertTrue("应抛出固定锁定异常，实际为$error", error is FocusLockedException)
        assertEquals("focus_locked", error?.message)
    }

    /** 固定启动周期并同时推进两种时钟，避免依赖真实等待。 */
    private class TestClock : FocusClockSource {
        var wallTime: Long = System.currentTimeMillis()
        var bootCount: Int = 3
        private var elapsedTime: Long = android.os.SystemClock.elapsedRealtime()

        /** 返回测试墙钟，允许模拟手动调时。 */
        override fun wall(): Long = wallTime

        /** 返回只由测试推进的单调时钟。 */
        override fun elapsed(): Long = elapsedTime

        /** 返回测试启动周期，也可模拟系统拒绝提供启动序号。 */
        override fun boot(): Int = bootCount

        /** 同步推进两种时钟而不等待真实时间。 */
        fun tick(milliseconds: Long) {
            wallTime += milliseconds
            elapsedTime += milliseconds
        }
    }
}
