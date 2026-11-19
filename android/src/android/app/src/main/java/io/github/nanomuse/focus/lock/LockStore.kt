package io.github.nanomuse.focus.lock

import android.content.Context
import androidx.room.withTransaction
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.focus.DeviceFocusClock
import io.github.nanomuse.focus.FocusClockSource
import io.github.nanomuse.focus.FocusSession
import io.github.nanomuse.focus.FocusSpan
import io.github.nanomuse.focus.FocusStore
import io.github.nanomuse.mosaic.MosaicDatabase
import io.github.nanomuse.todo.TodoConflictException
import kotlinx.coroutines.flow.combine
import java.util.UUID

/** 锁机配置和运行账本共用账号锁及Room事务，不改变普通专注表结构。 */
class LockStore internal constructor(
    private val context: Context,
    internal val database: MosaicDatabase,
    val ownerKey: String,
    val ownerEpoch: Long,
    private val clock: FocusClockSource = DeviceFocusClock(context)
) {
    private val dao = database.lockDao()

    /** 账号切换时立即隐藏旧计划。 */
    fun observePlans() = combine(dao.observePlans(ownerKey), AccountData.epoch) { rows, epoch ->
        if (isCurrent(epoch)) rows.map { it.toModel() } else emptyList()
    }

    /** 白名单变化触发页面和运行时重新读取。 */
    fun observeWhitelist() = combine(dao.observeWhitelist(ownerKey), AccountData.epoch) { rows, epoch ->
        if (isCurrent(epoch)) rows.map { it.packageName }.toSet() else emptySet()
    }

    /** 结束标志与账号代次共同决定页面是否显示锁定形态。 */
    fun observeRuns() = combine(dao.observeRuns(ownerKey), AccountData.epoch) { rows, epoch ->
        if (isCurrent(epoch)) rows.map { effectiveRun(it) } else emptyList()
    }

    /** 读取当前账号的计划，不跨账号复用缓存。 */
    suspend fun plans(): List<LockPlan> = transaction { dao.plans(ownerKey).map { it.toModel() } }

    /** 读取当前账号的持久白名单。 */
    suspend fun whitelist(): Set<String> = transaction { whitelistInTransaction() }

    /** 包含已结束记录，具体时段身份用于防止重放。 */
    suspend fun runs(): List<LockRun> = transaction { dao.runs(ownerKey).map { it.toModel() } }

    /** 查询活动会话前结算到期状态。 */
    suspend fun active(): LockRun? = checkpoint()

    /** 保存计划需要匹配修订，活动计划不接受编辑或重新启用。 */
    suspend fun savePlan(plan: LockPlan, expectedRevision: Long? = null): LockPlan = transaction {
        require(plan.ownerKey == ownerKey) { "wrong_owner" }
        LockConfigurationRules.validatePlan(plan, requiresRunnableSchedule = plan.isEnabled)
        LockMutationPolicy.requirePlanEditable(plan.id, checkpointInTransaction()?.planIds.orEmpty())
        val old = dao.plan(ownerKey, plan.id)
        checkRevision(plan.id, expectedRevision, old?.revision)
        val saved = plan.copy(revision = (old?.revision ?: 0) + 1)
        LockBackup.encode(dao.plans(ownerKey).filter { it.id != saved.id }.map { it.toModel() } + saved, whitelistInTransaction())
        dao.putPlan(LockPlanEntity.fromModel(saved, clock.wall()))
        saved
    }

    /** 删除计划保留身份与修订，旧页面不能重新覆盖已删除行。 */
    suspend fun deletePlan(id: String, expectedRevision: Long) = transaction {
        LockMutationPolicy.requirePlanEditable(id, checkpointInTransaction()?.planIds.orEmpty())
        val old = checkNotNull(dao.plan(ownerKey, id)) { "plan_not_found" }
        checkRevision(id, expectedRevision, old.revision)
        dao.putPlan(old.copy(enabled = false, deletedAt = clock.wall(), updatedAt = clock.wall(), revision = old.revision + 1))
    }

    /** 锁定期间只允许删减白名单，整次替换在同一事务中完成。 */
    suspend fun setWhitelist(packages: Set<String>) = transaction {
        LockConfigurationRules.validateWhitelist(packages)
        val old = whitelistInTransaction()
        LockMutationPolicy.requireWhitelistChange(old, packages, checkpointInTransaction() != null)
        LockBackup.encode(dao.plans(ownerKey).map { it.toModel() }, packages)
        (old - packages).forEach { dao.removeWhitelist(ownerKey, it) }
        dao.putWhitelist((packages - old).map { LockWhitelistEntity(ownerKey, it, clock.wall()) })
    }

    /** 导入仅合并配置，活动锁期间拒绝，恢复的计划均停用。 */
    suspend fun importConfiguration(text: String): Int = transaction {
        val imported = LockBackup.decode(text, ownerKey, checkpointInTransaction() != null)
        val mergedPlans = dao.plans(ownerKey).map { it.toModel() }.associateBy { it.id } + imported.plans.associateBy { it.id }
        val old = whitelistInTransaction()
        LockBackup.encode(mergedPlans.values.toList(), old + imported.whitelist)
        imported.plans.forEach { plan ->
            val old = dao.plan(ownerKey, plan.id)
            dao.putPlan(LockPlanEntity.fromModel(plan.copy(revision = (old?.revision ?: 0) + 1), clock.wall()))
        }
        dao.putWhitelist((imported.whitelist - old).map { LockWhitelistEntity(ownerKey, it, clock.wall()) })
        imported.plans.size
    }

    /** 创建已确认的定时会话；旧普通计时按已计量时长结束，不能重叠。 */
    internal suspend fun start(
        title: String, taskId: String? = null, durationMs: Long, usesWhitelist: Boolean = true,
        planIds: Set<String> = emptySet(), occurrenceIds: Set<String> = emptySet(), mode: String = "pomodoro"
    ): LockRun = transaction {
        // 正计时也可强制执行：截止设为正计时上限，由用户在锁页主动结束。
        require(mode in setOf("pomodoro", "break", "stopwatch")) { "lock_mode_unsupported" }
        require(durationMs in 1..LockRun.MAX_DURATION_MS) { "invalid_lock_duration" }
        check(checkpointInTransaction() == null) { "focus_locked" }
        val task = taskId?.let { database.todoDao().task(ownerKey, it)?.takeIf { row -> row.deletedAt == null }
            ?: error("task_not_found") }
        val name = (task?.title ?: title).trim()
        require(name.isNotEmpty() && name.length <= 500) { "invalid_focus_title" }
        val focus = FocusStore(context, database, ownerKey, ownerEpoch, clock)
        focus.finishForLockInTransaction()
        val wall = clock.wall()
        val elapsed = clock.elapsed()
        val boot = currentBoot()
        val session = FocusSession(ownerKey, UUID.randomUUID().toString(), name, task?.id,
            task?.groupName.orEmpty(), task?.tagsJson ?: "[]", mode, durationMs,
            startedAt = wall, updatedAt = wall, runningWall = wall, runningElapsed = elapsed, bootCount = clock.boot())
        val run = LockRun(ownerKey, UUID.randomUUID().toString(), session.id, planIds, occurrenceIds,
            wall, Math.addExact(wall, durationMs), durationMs, usesWhitelist, durationMs, elapsed, boot)
        database.focusDao().putSession(session)
        saveRun(run)
        run
    }

    /** 心跳最多每15秒写入检查点，到期立即保存完成记录。 */
    suspend fun checkpoint(): LockRun? = transaction { checkpointInTransaction() }

    /** 新重叠计划只能收紧当前策略，不改已开始时段的固定时钟。 */
    internal suspend fun tighten(runId: String, planIds: Set<String>, usesWhitelist: Boolean): LockRun? = transaction {
        val run = checkpointInTransaction() ?: return@transaction null
        if (run.id != runId) return@transaction run
        val restricted = run.copy(planIds = run.planIds + planIds, usesWhitelist = run.usesWhitelist && usesWhitelist)
        if (restricted != run) saveRun(restricted)
        restricted
    }

    /** 调用方已持账号和Room锁，避免嵌套获取非重入的账号互斥锁。 */
    internal suspend fun checkpointInTransaction(force: Boolean = false): LockRun? {
        val entity = dao.active(ownerKey) ?: return null
        val run = effectiveRun(entity)
        val session = checkNotNull(database.focusDao().session(ownerKey, run.sessionId)) { "lock_session_missing" }
        val wall = clock.wall()
        val elapsed = clock.elapsed()
        val result = LockAccounting.settle(run, session.elapsedMs, wall, elapsed, currentBoot())
        val needsRecovery = run.remaining(wall, elapsed, currentBoot()).requiresRebaseline
        if (!force && !result.isFinished && !needsRecovery && elapsed - entity.checkpointElapsed < 15_000) return run
        val updated = run.copy(checkpointRemainingMs = result.remainingMs, checkpointElapsed = elapsed,
            bootCount = currentBoot(), status = if (result.isFinished) LockRunStatus.COMPLETED else LockRunStatus.ACTIVE,
            endedAt = if (result.isFinished) run.deadlineAt else null)
        writeSettlement(session, updated, result.totalMs, result.deltaMs, result.isFinished)
        saveRun(updated)
        return updated.takeIf { it.status == LockRunStatus.ACTIVE }
    }

    /**
     * 强制正计时由用户在锁页结束：先按真实计时结算到此刻，再把会话记为完成并解除锁定。
     * 只接受当前活动且为正计时的运行，倒计时和计划锁机仍须走到期或紧急退出。
     */
    internal suspend fun finishStopwatch(runId: String): LockRun? = transaction {
        val run = checkpointInTransaction(force = true) ?: return@transaction null
        check(run.id == runId) { "lock_not_active" }
        val session = checkNotNull(database.focusDao().session(ownerKey, run.sessionId)) { "lock_session_missing" }
        check(session.mode == "stopwatch") { "lock_not_stopwatch" }
        val ended = run.copy(status = LockRunStatus.COMPLETED, endedAt = clock.wall())
        writeSettlement(session, ended, session.elapsedMs, 0, true)
        saveRun(ended)
        ended
    }

    /** 紧急退出必须由宿主完成等待校验；普通命令不能调用此内部结束入口。 */
    internal suspend fun finishInTransaction(status: LockRunStatus = LockRunStatus.COMPLETED): LockRun? {
        val run = checkpointInTransaction(force = true) ?: return null
        check(status == LockRunStatus.EMERGENCY) { "deadline_not_reached" }
        val session = checkNotNull(database.focusDao().session(ownerKey, run.sessionId))
        val consumed = LockScheduleDecision.emergencyOccurrences(dao.plans(ownerKey).map { it.toModel() },
            dao.runs(ownerKey).map { it.toModel() }, run, clock.wall())
        val ended = run.copy(status = status, endedAt = clock.wall(), occurrenceIds = consumed)
        writeSettlement(session, ended, session.elapsedMs, 0, true)
        saveRun(ended)
        return ended
    }

    /** 命令与到期结算处在同一事务，过期行不能继续拒绝普通操作。 */
    internal suspend fun requireCommandAllowedInTransaction(action: String) {
        val active = checkpointInTransaction()
        LockMutationPolicy.requireCommandAllowed(action, active?.remaining(clock.wall(), clock.elapsed(), currentBoot())?.milliseconds)
    }

    private suspend fun writeSettlement(session: FocusSession, run: LockRun, total: Long, delta: Long, finished: Boolean) {
        val focus = database.focusDao()
        if (delta > 0) focus.putSpan(FocusSpan(ownerKey, UUID.randomUUID().toString(), session.id,
            run.startedAt + session.elapsedMs, delta))
        focus.putSession(session.copy(elapsedMs = total, status = if (finished) "finished" else "running",
            endedAt = if (finished) run.endedAt else null, updatedAt = clock.wall(),
            runningWall = clock.wall(), runningElapsed = clock.elapsed(), bootCount = clock.boot(), revision = session.revision + 1))
    }

    private suspend fun saveRun(run: LockRun) {
        dao.putRun(LockRunEntity.fromModel(run))
        processClocks.remember(run)
    }

    private fun effectiveRun(entity: LockRunEntity): LockRun {
        return processClocks.restore(entity.toModel())
    }

    private fun currentBoot(): Int = clock.boot().takeIf { it >= 0 } ?: LockRun.PROCESS_BOOT_COUNT
    private fun isCurrent(epoch: Long): Boolean = epoch == ownerEpoch && AccountData.key(context) == ownerKey
    private suspend fun whitelistInTransaction(): Set<String> = dao.whitelist(ownerKey).map { it.packageName }.toSet()

    private fun checkRevision(id: String, expected: Long?, actual: Long?) {
        if (expected != actual) throw TodoConflictException("Plan changed; query again", taskId = id,
            expectedRevision = expected, actualRevision = actual)
    }

    /** 同一账号的所有锁机写入都使用现有变更边界。 */
    internal suspend fun <T> transaction(block: suspend () -> T): T =
        AccountData.withTodoOwnerMutation(ownerKey, ownerEpoch) { database.withTransaction(block) }

    companion object {
        private val processClocks = LockProcessClocks()

        /** 取得绑定当前账号及代次的存储入口。 */
        fun get(context: Context): LockStore {
            AccountData.requireAvailable()
            return LockStore(context.applicationContext, MosaicDatabase.get(context), AccountData.key(context), AccountData.epoch.value)
        }
    }
}
