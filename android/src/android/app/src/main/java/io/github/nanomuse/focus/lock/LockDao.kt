package io.github.nanomuse.focus.lock

import androidx.room.Dao
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

/** 锁机三表的账号隔离访问；跨专注表的业务事务由LockStore组织。 */
@Dao
interface LockDao {
    /** 观察当前账号未删除的计划，包括尚未启用的计划。 */
    @Query("SELECT * FROM focus_lock_plans WHERE ownerKey = :owner AND deletedAt IS NULL ORDER BY updatedAt DESC, id")
    fun observePlans(owner: String): Flow<List<LockPlanEntity>>

    /** 读取当前账号未删除的计划。 */
    @Query("SELECT * FROM focus_lock_plans WHERE ownerKey = :owner AND deletedAt IS NULL ORDER BY updatedAt DESC, id")
    suspend fun plans(owner: String): List<LockPlanEntity>

    /** 读取当前账号全部计划及删除标记，用于修订合并。 */
    @Query("SELECT * FROM focus_lock_plans WHERE ownerKey = :owner ORDER BY updatedAt DESC, id")
    suspend fun allPlans(owner: String): List<LockPlanEntity>

    /** 按账号和身份读取计划，保留删除标记以便校验修订。 */
    @Query("SELECT * FROM focus_lock_plans WHERE ownerKey = :owner AND id = :id")
    suspend fun plan(owner: String, id: String): LockPlanEntity?

    /** 写入调用方在账号变更边界内校验过的计划。 */
    @Upsert
    suspend fun putPlan(plan: LockPlanEntity)

    /** 观察账号全局白名单，按加入时间及包名稳定排序。 */
    @Query("SELECT * FROM focus_lock_whitelist WHERE ownerKey = :owner ORDER BY addedAt, packageName")
    fun observeWhitelist(owner: String): Flow<List<LockWhitelistEntity>>

    /** 读取账号全局白名单。 */
    @Query("SELECT * FROM focus_lock_whitelist WHERE ownerKey = :owner ORDER BY addedAt, packageName")
    suspend fun whitelist(owner: String): List<LockWhitelistEntity>

    /** 批量写入调用方校验过的白名单，不删除列表之外的包。 */
    @Upsert
    suspend fun putWhitelist(entries: List<LockWhitelistEntity>)

    /** 只移除指定账号中的一个包。 */
    @Query("DELETE FROM focus_lock_whitelist WHERE ownerKey = :owner AND packageName = :packageName")
    suspend fun removeWhitelist(owner: String, packageName: String)

    /** 观察账号的全部运行历史，完成记录用于具体时段去重。 */
    @Query("SELECT * FROM focus_lock_runs WHERE ownerKey = :owner ORDER BY startedAt DESC, id")
    fun observeRuns(owner: String): Flow<List<LockRunEntity>>

    /** 读取账号的全部运行历史。 */
    @Query("SELECT * FROM focus_lock_runs WHERE ownerKey = :owner ORDER BY startedAt DESC, id")
    suspend fun runs(owner: String): List<LockRunEntity>

    /** 按账号和身份读取一个运行记录。 */
    @Query("SELECT * FROM focus_lock_runs WHERE ownerKey = :owner AND id = :id")
    suspend fun run(owner: String, id: String): LockRunEntity?

    /** 读取当前账号的活动锁定，结束记录不能继续阻止普通专注操作。 */
    @Query("SELECT * FROM focus_lock_runs WHERE ownerKey = :owner AND status = 'active' ORDER BY startedAt DESC, id LIMIT 1")
    suspend fun active(owner: String): LockRunEntity?

    /** 判断指定专注是否仍由活动锁定保护。 */
    @Query("SELECT * FROM focus_lock_runs WHERE ownerKey = :owner AND sessionId = :sessionId AND status = 'active' LIMIT 1")
    suspend fun activeForSession(owner: String, sessionId: String): LockRunEntity?

    /** 在业务事务内保存运行状态和检查点。 */
    @Upsert
    suspend fun putRun(run: LockRunEntity)

    /** 清理指定账号的全部运行记录，由账号删除流程调用。 */
    @Query("DELETE FROM focus_lock_runs WHERE ownerKey = :owner")
    suspend fun deleteRuns(owner: String)

    /** 清理指定账号的白名单，其他账号不受影响。 */
    @Query("DELETE FROM focus_lock_whitelist WHERE ownerKey = :owner")
    suspend fun deleteWhitelist(owner: String)

    /** 清理指定账号的计划和软删除标记。 */
    @Query("DELETE FROM focus_lock_plans WHERE ownerKey = :owner")
    suspend fun deletePlans(owner: String)

    /** 在同一事务中清理账号的三表数据，调用方负责账号变更授权。 */
    @Transaction
    suspend fun deleteOwner(owner: String) {
        deleteRuns(owner)
        deleteWhitelist(owner)
        deletePlans(owner)
    }
}
