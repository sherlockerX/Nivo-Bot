package io.github.nanomuse.focus.lock

/** 配置保存、备份恢复和合并前共用的纯校验。 */
object LockConfigurationRules {
    const val MAX_PLANS = 1000
    const val MAX_WHITELIST = 1000
    const val MAX_RANGES = 64
    private val PACKAGE_PATTERN = Regex("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*")

    /** 校验合并后的完整账户配置，不允许只校验本次新增部分。 */
    fun validateConfiguration(plans: List<LockPlan>, whitelist: Set<String>) {
        require(plans.size <= MAX_PLANS) { "计划数量超限" }
        val ownerKey = plans.firstOrNull()?.ownerKey
        require(plans.all { it.ownerKey == ownerKey }) { "配置不能混入其他账号的计划" }
        require(plans.map { it.id }.distinct().size == plans.size) { "计划身份重复" }
        plans.forEach { validatePlan(it) }
        validateWhitelist(whitelist)
    }

    /** 草稿可保留空日程，正式保存或启用时要求星期与时段非空。 */
    fun validatePlan(plan: LockPlan, requiresRunnableSchedule: Boolean = false) {
        requireOwner(plan.ownerKey)
        validatePlanText(plan)
        require(plan.days.all { it in 1..7 }) { "星期必须位于周一至周日之间" }
        require(plan.ranges.size <= MAX_RANGES) { "计划时段数量超限" }
        require(plan.ranges.distinct().size == plan.ranges.size) { "计划时段重复" }
        if (requiresRunnableSchedule) {
            require(plan.days.isNotEmpty() && plan.ranges.isNotEmpty()) { "执行计划需要星期与时段" }
        }
    }

    /** 白名单在持久化与备份时采用相同数量、长度和包名语法。 */
    fun validateWhitelist(packages: Set<String>) {
        require(packages.size <= MAX_WHITELIST) { "白名单数量超限" }
        require(packages.all { it.length <= 255 && PACKAGE_PATTERN.matches(it) }) { "白名单包名无效" }
    }

    /** 空字符串代表离线本地账号，不能把非空纯空白键当成另一个本地账号。 */
    internal fun requireOwner(ownerKey: String) {
        require(ownerKey.isEmpty() || ownerKey.isNotBlank()) { "账号键不能仅包含空白" }
    }

    private fun validatePlanText(plan: LockPlan) {
        require(plan.id.isNotBlank() && plan.id.length <= 200) { "计划身份长度无效" }
        require(plan.name.isNotBlank() && plan.name.length <= 500) { "计划名称长度无效" }
        require((plan.title?.length ?: 0) <= 500) { "专注标题过长" }
        require((plan.taskId?.length ?: 0) <= 200) { "待办身份过长" }
    }
}
