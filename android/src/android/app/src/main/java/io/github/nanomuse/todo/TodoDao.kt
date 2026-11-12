package io.github.nanomuse.todo

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

/** 每条任务查询都显式限定账号，不依赖界面过滤。 */
@Dao
interface TodoDao {
    /** 目录独立于任务，未被使用的分类也可以选择。 */
    @Query("SELECT * FROM todo_categories WHERE ownerKey = :owner ORDER BY kind, name COLLATE NOCASE, name")
    fun observeCategories(owner: String): Flow<List<TodoCategory>>

    /** 导出与工具读取同一份账号目录。 */
    @Query("SELECT * FROM todo_categories WHERE ownerKey = :owner ORDER BY kind, name COLLATE NOCASE, name")
    suspend fun categories(owner: String): List<TodoCategory>

    /** 同名重复创建幂等，不覆盖首次创建时间。 */
    @Insert(onConflict = androidx.room.OnConflictStrategy.IGNORE)
    suspend fun putCategories(categories: List<TodoCategory>)

    /** 删除已确认的精确分类，不跨账号或模糊匹配名称。 */
    @Query("DELETE FROM todo_categories WHERE ownerKey = :owner AND kind = :kind AND name = :name")
    suspend fun deleteCategory(owner: String, kind: String, name: String)

    /** 账号删除同时清理独立分类。 */
    @Query("DELETE FROM todo_categories WHERE ownerKey = :owner")
    suspend fun deleteOwnerCategories(owner: String)

    /** 观察当前账号未删除任务。 */
    @Query("SELECT * FROM todo_tasks WHERE ownerKey = :owner AND deletedAt IS NULL ORDER BY updatedAt DESC, id")
    fun observeTasks(owner: String): Flow<List<TodoTask>>

    /** 读取当前可见任务。 */
    @Query("SELECT * FROM todo_tasks WHERE ownerKey = :owner AND deletedAt IS NULL ORDER BY updatedAt DESC, id")
    suspend fun tasks(owner: String): List<TodoTask>

    /** 备份保留软删除行，使历史事件和幂等结果仍可解释。 */
    @Query("SELECT * FROM todo_tasks WHERE ownerKey = :owner ORDER BY id")
    suspend fun allTasks(owner: String): List<TodoTask>

    /** 导出当前账号状态历史。 */
    @Query("SELECT * FROM todo_events WHERE ownerKey = :owner ORDER BY createdAt, operationId")
    suspend fun events(owner: String): List<TodoEvent>

    /** 导出当前账号幂等结果。 */
    @Query("SELECT * FROM todo_operations WHERE ownerKey = :owner ORDER BY createdAt, operationId")
    suspend fun operations(owner: String): List<TodoOperation>

    /** 用于版本校验及幂等处理，包含删除标记。 */
    @Query("SELECT * FROM todo_tasks WHERE ownerKey = :owner AND id = :id")
    suspend fun task(owner: String, id: String): TodoTask?

    /** 写入已验证的任务。 */
    @Upsert suspend fun putTask(task: TodoTask)

    /** 读取持久幂等结果。 */
    @Query("SELECT * FROM todo_operations WHERE ownerKey = :owner AND operationId = :id")
    suspend fun operation(owner: String, id: String): TodoOperation?

    /** 幂等键冲突交由上层验证，不覆盖旧请求。 */
    @Insert suspend fun putOperation(operation: TodoOperation)

    /** 状态事件与任务同事务落盘。 */
    @Insert suspend fun putEvent(event: TodoEvent)

    /** 读取一个碎片在当前账号的关联。 */
    @Query("SELECT * FROM todo_entry_links WHERE ownerKey = :owner AND entryId = :entryId ORDER BY linkedAt, taskId")
    suspend fun entryLinks(owner: String, entryId: String): List<TodoEntryLink>

    /** 任务详情只列出未删除碎片，保留内部历史快照。 */
    @Query("SELECT l.* FROM todo_entry_links l INNER JOIN entries e ON e.id = l.entryId WHERE l.ownerKey = :owner AND l.taskId = :taskId AND e.deletedAt IS NULL ORDER BY e.day DESC, l.linkedAt DESC")
    suspend fun taskLinks(owner: String, taskId: String): List<TodoEntryLink>

    /** 导出仍有来源的碎片关联。 */
    @Query("SELECT l.* FROM todo_entry_links l INNER JOIN entries e ON e.id = l.entryId WHERE l.ownerKey = :owner AND e.deletedAt IS NULL")
    suspend fun allEntryLinks(owner: String): List<TodoEntryLink>

    /** 替换碎片关联前移除当前账号旧集合。 */
    @Query("DELETE FROM todo_entry_links WHERE ownerKey = :owner AND entryId = :entryId")
    suspend fun clearEntryLinks(owner: String, entryId: String)

    /** 写入已验证关联快照。 */
    @Upsert suspend fun putEntryLinks(links: List<TodoEntryLink>)

    /** 读取草稿中尚未执行的状态意图。 */
    @Query("SELECT * FROM todo_draft_links WHERE ownerKey = :owner AND draftId = :draftId ORDER BY taskId")
    suspend fun draftLinks(owner: String, draftId: String): List<TodoDraftLink>

    /** 替换当前账号草稿意图。 */
    @Query("DELETE FROM todo_draft_links WHERE ownerKey = :owner AND draftId = :draftId")
    suspend fun clearDraftLinks(owner: String, draftId: String)

    /** 日记草稿彻底丢弃时清理所有账号的悬挂意图。 */
    @Query("DELETE FROM todo_draft_links WHERE draftId = :draftId")
    suspend fun discardDraftLinks(draftId: String)

    /** 重定日记日期时保持各账号草稿关联。 */
    @Query("UPDATE todo_draft_links SET draftId = :newId WHERE draftId = :oldId")
    suspend fun redateDraftLinks(oldId: String, newId: String)

    /** 写入草稿意图。 */
    @Upsert suspend fun putDraftLinks(links: List<TodoDraftLink>)

    /** 删除已物理清理日记的关联，不改变任务完成快照。 */
    @Query("DELETE FROM todo_entry_links WHERE entryId NOT IN (SELECT id FROM entries)")
    suspend fun purgeOrphanLinks()

    /** 账号退出且不保留时清理任务。 */
    @Query("DELETE FROM todo_tasks WHERE ownerKey = :owner")
    suspend fun deleteOwnerTasks(owner: String)

    /** 账号退出且不保留时清理关联。 */
    @Query("DELETE FROM todo_entry_links WHERE ownerKey = :owner")
    suspend fun deleteOwnerLinks(owner: String)

    /** 账号退出且不保留时清理草稿意图。 */
    @Query("DELETE FROM todo_draft_links WHERE ownerKey = :owner")
    suspend fun deleteOwnerDrafts(owner: String)

    /** 账号退出且不保留时清理幂等请求。 */
    @Query("DELETE FROM todo_operations WHERE ownerKey = :owner")
    suspend fun deleteOwnerOperations(owner: String)

    /** 账号退出且不保留时清理状态历史。 */
    @Query("DELETE FROM todo_events WHERE ownerKey = :owner")
    suspend fun deleteOwnerEvents(owner: String)
}
