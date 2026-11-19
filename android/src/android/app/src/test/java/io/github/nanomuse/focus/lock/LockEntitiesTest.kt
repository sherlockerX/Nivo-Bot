package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 持久化转换必须保留计划含义，且不能恢复进程内的临时开机身份。 */
class LockEntitiesTest {
    /** 星期掩码及跨午夜区间完整往返，删除时间仅留在持久化实体。 */
    @Test
    fun should_preservePlan_when_roundTrippingEntity() {
        val model = LockPlan(
            id = "plan", name = "晚间阅读", days = setOf(1, 4, 7),
            ranges = listOf(TimeRange(1380, 60), TimeRange(600, 600)),
            isEnabled = false, usesWhitelist = false, title = "读书",
            taskId = "task", ownerKey = "owner", revision = 4L
        )
        val entity = LockPlanEntity.fromModel(model, updatedAt = 5L, deletedAt = 6L)
        assertEquals(73, entity.daysMask)
        assertEquals(5L, entity.updatedAt)
        assertEquals(6L, entity.deletedAt)
        assertEquals(model, entity.toModel())
    }

    /** 空星期和空区间在配置阶段可往返，不应被补成默认工作日。 */
    @Test
    fun should_preserveEmptySchedule_when_roundTrippingEntity() {
        val model = LockPlan("plan", "未配置", days = emptySet(), ranges = emptyList())
        assertEquals(model, LockPlanEntity.fromModel(model, 1L).toModel())
    }

    /** 数字字符串不能被JSON宽松转换成计划分钟。 */
    @Test
    fun should_rejectStringMinutes_when_loadingPlan() {
        for (field in listOf("startMinute", "endMinute")) {
            assertInvalidMinute(field, "\"480\"")
        }
    }

    /** 小数和整数形式的浮点值均不得截断成合法时间。 */
    @Test
    fun should_rejectFractionalMinutes_when_loadingPlan() {
        for (field in listOf("startMinute", "endMinute")) {
            for (value in listOf("480.5", "480.0", "4.8e2")) {
                assertInvalidMinute(field, value)
            }
        }
    }

    /** 非数字和超出整数范围的分钟不能溢出后冒充合法区间。 */
    @Test
    fun should_rejectInvalidMinuteTypesAndOverflow_when_loadingPlan() {
        for (value in listOf("true", "null", "[]", "{}", "4294967776")) {
            assertInvalidMinute("startMinute", value)
        }
    }

    /** 已知开机计数的完整运行记录在JSON转换后保持相等。 */
    @Test
    fun should_preserveRun_when_roundTrippingKnownBoot() {
        LockRunStatus.entries.forEach { status ->
            val model = run().copy(status = status, endedAt = if (status == LockRunStatus.ACTIVE) null else 61000L)
            val entity = LockRunEntity.fromModel(model)
            assertEquals(status.name.lowercase(), entity.status)
            assertEquals(model, entity.toModel())
        }
    }

    /** 进程内占位启动号写入数据库前必须降为未知。 */
    @Test
    fun should_discardProcessBootIdentity_when_persisting() {
        val entity = LockRunEntity.fromModel(run().copy(bootCount = LockRun.PROCESS_BOOT_COUNT))
        assertEquals(-1, entity.bootCount)
        assertTrue(entity.toModel().remaining(2000L, 3000L, LockRun.PROCESS_BOOT_COUNT).requiresRebaseline)
    }

    /** 旧库中意外保存的进程启动号也不能在读回时重新使用。 */
    @Test
    fun should_discardStoredProcessBootIdentity_when_loading() {
        val entity = LockRunEntity.fromModel(run()).copy(bootCount = LockRun.PROCESS_BOOT_COUNT)
        assertEquals(-1, entity.toModel().bootCount)
        assertTrue(entity.toModel().remaining(2000L, 3000L, LockRun.PROCESS_BOOT_COUNT).requiresRebaseline)
    }

    /** JSON编码保留引号和分隔符，集合落库次序稳定。 */
    @Test
    fun should_escapeIdentifiersAndSortSets_when_serializingRun() {
        val model = run().copy(planIds = linkedSetOf("z", "a\"b"), occurrenceIds = setOf("x,y", "x|y"))
        val first = LockRunEntity.fromModel(model)
        val second = LockRunEntity.fromModel(model.copy(planIds = model.planIds.reversed().toSet()))
        assertEquals(first.planIds, second.planIds)
        assertEquals(model, first.toModel())
        assertFalse(first.planIds.contains("a\"b"))
    }

    /** 未识别的状态不能被静默降成已结束，从而绕过强制限制。 */
    @Test(expected = IllegalArgumentException::class)
    fun should_rejectUnknownStatus_when_loadingRun() {
        LockRunEntity.fromModel(run()).copy(status = "unknown").toModel()
    }

    private fun run() = LockRun(
        ownerKey = "owner", id = "run", sessionId = "session", planIds = setOf("plan"),
        occurrenceIds = setOf("occurrence"), startedAt = 1000L, deadlineAt = 61000L,
        durationMs = 60000L, usesWhitelist = true, checkpointRemainingMs = 42000L,
        checkpointElapsed = 20000L, bootCount = 3
    )

    private fun assertInvalidMinute(field: String, value: String) {
        val start = if (field == "startMinute") value else "480"
        val end = if (field == "endMinute") value else "540"
        val entity = LockPlanEntity.fromModel(LockPlan("plan", "计划"), 1L)
            .copy(rangesJson = """[{"startMinute":$start,"endMinute":$end}]""")
        val error = runCatching { entity.toModel() }.exceptionOrNull()
        assertTrue("非法分钟$field=${value}应被拒绝，实际为$error", error is IllegalArgumentException)
    }
}
