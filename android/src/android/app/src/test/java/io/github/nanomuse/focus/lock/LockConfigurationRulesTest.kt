package io.github.nanomuse.focus.lock

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/** 保存、导入和合并配置共用相同字段与数量约束。 */
class LockConfigurationRulesTest {
    private val plan = LockPlan("plan", "计划", days = setOf(1),
        ranges = listOf(TimeRange(480, 540)), ownerKey = "")

    /** 合法长度边界在保存与备份中保持一致。 */
    @Test
    fun should_acceptMaximumTextLengths_when_planMeetsSharedBounds() {
        val boundary = plan.copy(id = "i".repeat(200), name = "n".repeat(500),
            title = "t".repeat(500), taskId = "k".repeat(200))
        LockConfigurationRules.validatePlan(boundary, requiresRunnableSchedule = true)
        val restored = LockBackup.decode(LockBackup.encode(listOf(boundary), emptySet()), "")
        assertEquals(boundary.copy(isEnabled = false), restored.plans.single())
    }

    /** 超出任意文本字段上限时在写入前拒绝。 */
    @Test
    fun should_rejectOversizedText_when_anyPlanFieldExceedsBound() {
        for (invalid in listOf(plan.copy(id = "i".repeat(201)), plan.copy(name = "n".repeat(501)),
            plan.copy(title = "t".repeat(501)), plan.copy(taskId = "k".repeat(201)), plan.copy(name = " "))) {
            rejected { LockConfigurationRules.validatePlan(invalid) }
        }
    }

    /** 停用导入草稿允许空日程，但正式保存或启用必须有星期与时段。 */
    @Test
    fun should_distinguishDraftFromRunnable_when_calendarCollectionsAreEmpty() {
        for (draft in listOf(plan.copy(days = emptySet()), plan.copy(ranges = emptyList()))) {
            LockConfigurationRules.validatePlan(draft.copy(isEnabled = false))
            rejected { LockConfigurationRules.validatePlan(draft, requiresRunnableSchedule = true) }
        }
    }

    /** 模型创建后被外部修改的集合也必须在写入时重新验证。 */
    @Test
    fun should_rejectInvalidWeekday_when_mutableInputChangesAfterConstruction() {
        val days = mutableSetOf(1)
        val input = plan.copy(days = days)
        days += 8
        rejected { LockConfigurationRules.validatePlan(input) }
    }

    /** 重复时段和超过64段的计划不能持久化。 */
    @Test
    fun should_rejectInvalidRangeCollection_when_duplicateOrExcessive() {
        rejected { LockConfigurationRules.validatePlan(plan.copy(ranges = listOf(TimeRange(1, 2), TimeRange(1, 2)))) }
        rejected { LockConfigurationRules.validatePlan(plan.copy(ranges = (0..64).map { TimeRange(it, it + 1) })) }
    }

    /** 白名单包名长度和语法与备份校验一致。 */
    @Test
    fun should_validateWhitelistBounds_when_savedByStore() {
        LockConfigurationRules.validateWhitelist(setOf("a".repeat(255), "android", "test.reader"))
        for (invalid in listOf(setOf("a".repeat(256)), setOf("bad package"), setOf(""),
            (0..1000).map { "test.app$it" }.toSet())) {
            rejected { LockConfigurationRules.validateWhitelist(invalid) }
        }
    }

    /** 合并后计划总数必须受约束，即使每份导入文件各自合格。 */
    @Test
    fun should_rejectMergedPlanCount_when_existingAndIncomingExceedLimit() {
        val existing = (0 until 700).map { plan.copy(id = "existing-$it") }
        val incoming = (0 until 301).map { plan.copy(id = "incoming-$it") }
        LockConfigurationRules.validateConfiguration(existing, emptySet())
        LockConfigurationRules.validateConfiguration(incoming, emptySet())
        rejected { LockConfigurationRules.validateConfiguration(existing + incoming, emptySet()) }
    }

    /** 合并后的白名单总数同样受约束。 */
    @Test
    fun should_rejectMergedWhitelistCount_when_unionExceedsLimit() {
        val first = (0 until 700).map { "test.first$it" }.toSet()
        val second = (0 until 301).map { "test.second$it" }.toSet()
        rejected { LockConfigurationRules.validateConfiguration(emptyList(), first + second) }
    }

    /** 相同计划ID和跨账号集合都不能作为完整配置写入。 */
    @Test
    fun should_rejectDuplicateOrMixedIdentity_when_validatingConfiguration() {
        rejected { LockConfigurationRules.validateConfiguration(listOf(plan, plan), emptySet()) }
        rejected { LockConfigurationRules.validateConfiguration(listOf(plan, plan.copy(id = "cloud", ownerKey = "cloud")), emptySet()) }
    }

    /** 本地空账号正常使用，非空纯空白身份仍拒绝。 */
    @Test
    fun should_acceptLocalOwner_when_validatingConfiguration() {
        LockConfigurationRules.validateConfiguration(listOf(plan), emptySet())
        rejected { LockConfigurationRules.validatePlan(plan.copy(ownerKey = " ")) }
    }

    private fun rejected(action: () -> Unit) {
        assertThrows(IllegalArgumentException::class.java) { action() }
    }
}
