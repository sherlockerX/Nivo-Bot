package io.github.nanomuse.focus.lock

import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.nanomuse.mosaic.MosaicDatabase
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** 通过真实Room生成的DAO验证账号隔离、软删除和运行状态。 */
@RunWith(AndroidJUnit4::class)
class LockDaoInstrumentedTest {
    private lateinit var database: MosaicDatabase
    private lateinit var dao: LockDao

    /** 每项测试使用独立的内存数据库。 */
    @Before
    fun createDatabase() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        check(context.packageName.endsWith(".uitest"))
        database = Room.inMemoryDatabaseBuilder(context, MosaicDatabase::class.java).build()
        dao = database.lockDao()
    }

    /** 释放Room连接，避免测试间共享状态。 */
    @After
    fun closeDatabase() {
        database.close()
    }

    /** 同名计划按账号分开保存，软删除计划不进入列表或观察流。 */
    @Test
    fun should_isolatePlansAndHideTombstones_when_reading() = runBlocking {
        dao.putPlan(plan("owner-a"))
        dao.putPlan(plan("owner-b"))
        dao.putPlan(plan("owner-a").copy(id = "deleted", deletedAt = 2L))
        assertEquals(listOf("shared"), dao.plans("owner-a").map { it.id })
        assertEquals(listOf("owner-b"), dao.observePlans("owner-b").first().map { it.ownerKey })
        assertEquals(2L, dao.plan("owner-a", "deleted")?.deletedAt)
        assertNull(dao.plan("other-owner", "shared"))
    }

    /** 活动状态只返回当前账号的运行，完成后的记录仍用于时段去重。 */
    @Test
    fun should_returnOnlyActiveOwnerRun_when_otherRunsExist() = runBlocking {
        dao.putRun(run("owner-a", "completed", LockRunStatus.COMPLETED))
        dao.putRun(run("owner-a", "active", LockRunStatus.ACTIVE))
        dao.putRun(run("owner-b", "active", LockRunStatus.ACTIVE))
        assertEquals("active", dao.active("owner-a")?.id)
        assertEquals("owner-b", dao.active("owner-b")?.ownerKey)
        assertNull(dao.active("missing-owner"))
        assertEquals(2, dao.observeRuns("owner-a").first().size)
        dao.putRun(run("owner-a", "active", LockRunStatus.EMERGENCY))
        assertNull(dao.active("owner-a"))
        assertEquals("emergency", dao.run("owner-a", "active")?.status)
        assertEquals(2, dao.runs("owner-a").size)
    }

    /** 单包移除和账号清理不能影响其他账号的白名单及运行历史。 */
    @Test
    fun should_keepOtherOwnerData_when_removingWhitelistAndOwner() = runBlocking {
        listOf("owner-a", "owner-b").forEach { owner ->
            dao.putPlan(plan(owner))
            dao.putRun(run(owner, "active", LockRunStatus.ACTIVE))
            dao.putWhitelist(listOf(LockWhitelistEntity(owner, "app.allowed", 1L)))
        }
        dao.removeWhitelist("owner-a", "app.allowed")
        assertEquals(emptyList<LockWhitelistEntity>(), dao.whitelist("owner-a"))
        assertEquals(1, dao.observeWhitelist("owner-b").first().size)
        dao.deleteOwner("owner-a")
        assertEquals(emptyList<LockPlanEntity>(), dao.plans("owner-a"))
        assertEquals(emptyList<LockRunEntity>(), dao.runs("owner-a"))
        assertEquals(1, dao.plans("owner-b").size)
        assertEquals(1, dao.runs("owner-b").size)
        assertEquals(1, dao.whitelist("owner-b").size)
    }

    private fun plan(owner: String) = LockPlanEntity.fromModel(
        LockPlan("shared", "计划", ownerKey = owner), updatedAt = 1L
    )

    private fun run(owner: String, id: String, status: LockRunStatus) = LockRunEntity.fromModel(
        LockRun(
            ownerKey = owner, id = id, sessionId = "session-$id",
            planIds = setOf("shared"), occurrenceIds = setOf("occurrence-$id"),
            startedAt = 1000L, deadlineAt = 61000L, durationMs = 60000L,
            usesWhitelist = true, checkpointRemainingMs = 60000L,
            checkpointElapsed = 2000L, bootCount = 3, status = status,
            endedAt = if (status == LockRunStatus.ACTIVE) null else 61000L
        )
    )
}
