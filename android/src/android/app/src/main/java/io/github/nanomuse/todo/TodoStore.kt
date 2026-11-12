package io.github.nanomuse.todo

import android.content.Context
import androidx.room.withTransaction
import io.github.nanomuse.account.AccountData
import io.github.nanomuse.mosaic.MosaicDatabase
import java.time.LocalDate
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import org.json.JSONObject

/** 固定账号和代次的待办入口；旧页面不能在账号切换后重新获得写入权限。 */
class TodoStore internal constructor(
    private val context: Context,
    internal val database: MosaicDatabase,
    val ownerKey: String,
    val ownerEpoch: Long,
) {
    internal val dao = database.todoDao()

    /** 账号迁移立即隐藏旧结果，下一页面应重新取得Store。 */
    fun observeTasks(): Flow<List<TodoTask>> = combine(dao.observeTasks(ownerKey), AccountData.epoch) { tasks, epoch ->
        if (epoch == ownerEpoch && AccountData.key(context) == ownerKey) tasks else emptyList()
    }

    /** 旧账号页面隐藏目录，防止账号切换时复用其他人的分类。 */
    fun observeCategories(): Flow<List<TodoCategory>> = combine(dao.observeCategories(ownerKey), AccountData.epoch) { rows, epoch ->
        if (epoch == ownerEpoch && AccountData.key(context) == ownerKey) rows else emptyList()
    }

    /** 读取已保存目录，包含尚未用于任务的分类。 */
    suspend fun categories(): List<TodoCategory> = withOwner { dao.categories(ownerKey) }

    /** 就地创建立即落盘，取消任务编辑不会撤销已经明确创建的分类。 */
    suspend fun createCategory(kind: String, text: String): String = transaction { createCategoryInTransaction(kind, text) }

    private suspend fun createCategoryInTransaction(kind: String, text: String): String {
        val name = TodoCategoryRules.name(kind, text)
        val now = System.currentTimeMillis()
        dao.putCategories(listOf(TodoCategory(ownerKey, kind, name, now, now)))
        return name
    }

    /** 删除目录并解除任务当前分类；历史完成快照及事件不重写。 */
    suspend fun deleteCategory(kind: String, text: String, expectedCreatedAt: Long) = transaction { deleteCategoryInTransaction(kind, text, expectedCreatedAt) }

    private suspend fun deleteCategoryInTransaction(kind: String, text: String, expectedCreatedAt: Long) {
        val name = TodoCategoryRules.name(kind, text)
        val category = dao.categories(ownerKey).firstOrNull { it.kind == kind && it.name == name }
        if (category != null) {
            check(category.createdAt == expectedCreatedAt) { "Category changed; reopen the list" }
            val now = System.currentTimeMillis()
            dao.allTasks(ownerKey).forEach { task ->
                val changed = when {
                    kind == TodoCategoryRules.GROUP && task.groupName == name -> task.copy(groupName = "")
                    kind == TodoCategoryRules.TAG && name in task.tags() -> task.copy(tagsJson = todoTagsJson(task.tags() - name))
                    else -> null
                }
                changed?.let { dao.putTask(it.copy(revision = task.revision + 1, updatedAt = now)) }
            }
            dao.deleteCategory(ownerKey, kind, name)
        }
    }

    /** 分类命令记录首次结果，重试旧删除不能删除后来重建的同名分类。 */
    suspend fun categoryCommand(action:String,kind:String,text:String,expectedCreatedAt:Long?,operationId:String):String = transaction {
        require(action in setOf("create_category","delete_category"))
        val name=TodoCategoryRules.name(kind,text)
        val request=JSONObject().put("kind",action).put("categoryKind",kind).put("name",name)
            .put("expectedCreatedAt",expectedCreatedAt ?: JSONObject.NULL).toString()
        val previous=dao.operation(ownerKey,operationId)
        if(previous!=null) {
            require(previous.requestJson==request) { "Operation id was already used for different content" }
            return@transaction previous.resultJson
        }
        val result=if(action=="create_category") {
            createCategoryInTransaction(kind,name)
            val category=dao.categories(ownerKey).first { it.kind==kind && it.name==name }
            JSONObject().put("kind",kind).put("name",name).put("createdAt",category.createdAt)
        } else {
            require(expectedCreatedAt!=null)
            deleteCategoryInTransaction(kind,name,expectedCreatedAt)
            JSONObject().put("kind",kind).put("name",name).put("deleted",true).put("tasksPreserved",true)
        }.toString()
        dao.putOperation(TodoOperation(ownerKey,operationId,request,result,System.currentTimeMillis()))
        result
    }

    /** 任务、AI和导入共用登记，删除任务不会删除目录或完成标签快照。 */
    internal suspend fun rememberCategories(task: TodoTask) {
        val now = System.currentTimeMillis()
        val rows = task.tags().map { TodoCategory(ownerKey, TodoCategoryRules.TAG, it, now, now) }.toMutableList()
        if (task.groupName.isNotBlank()) rows += TodoCategory(ownerKey, TodoCategoryRules.GROUP, task.groupName, now, now)
        dao.putCategories(rows)
    }

    /** 返回当前账号的有效任务。 */
    suspend fun tasks(): List<TodoTask> = withOwner { dao.tasks(ownerKey) }

    /** 读取有效任务，软删除任务不再向普通调用者返回。 */
    suspend fun task(id: String): TodoTask? = withOwner { dao.task(ownerKey, id)?.takeIf { it.deletedAt == null } }

    /** 新建或以revision更新任务，同操作ID重试返回首次落盘结果。 */
    suspend fun saveTask(task: TodoTask, operationId: String): TodoTask = transaction {
        val request = JSONObject().put("kind", "save").put("task", TodoJson.task(task)).toString()
        taskOperation(operationId, request) {
            val old = if (task.id.isEmpty()) null else requireTask(task.id, task.revision)
            val id = old?.id ?: UUID.randomUUID().toString()
            val saved = TodoRules.update(task, old, ownerKey, id, System.currentTimeMillis(), LocalDate.now().toEpochDay())
            persist(saved, old, operationId)
        }
    }

    /** 显式变更状态；重复标完成不会改动完成日期或标签快照。 */
    suspend fun changeStatus(id: String, status: String, expectedRevision: Long, operationId: String,
        completedDay: Long? = null): TodoTask = transaction {
        changeStatusInTransaction(id, status, expectedRevision, operationId, completedDay)
    }

    /** 软删除保留关联快照，统计自动移除此任务。 */
    suspend fun deleteTask(id: String, expectedRevision: Long, operationId: String) {
        transaction {
            val request = JSONObject().put("kind", "delete").put("id", id).put("revision", expectedRevision).toString()
            taskOperation(operationId, request) {
                val old = requireTask(id, expectedRevision)
                val now = System.currentTimeMillis()
                persist(old.copy(deletedAt = now, updatedAt = now, revision = old.revision + 1), old, operationId)
            }
        }
    }

    /** 仅返回当前账号的历史关联快照。 */
    suspend fun entryLinks(entryId: String): List<TodoEntryLink> = withOwner { dao.entryLinks(ownerKey, entryId) }

    /** 任务详情回顾仍存在且未删除的关联碎片。 */
    suspend fun taskLinks(taskId: String): List<TodoEntryLink> = withOwner { dao.taskLinks(ownerKey, taskId) }

    /** 恢复未提交的关联和明确状态意图。 */
    suspend fun draftLinks(draftId: String): List<TodoSelection> = withOwner {
        dao.draftLinks(ownerKey, draftId).map { TodoSelection(it.taskId, it.expectedRevision, it.requestedStatus, it.completedDay) }
    }

    /** 保存关联草稿，不改变任何任务的状态。 */
    suspend fun putDraftLinks(draftId: String, selections: List<TodoSelection>) = transaction {
        putDraftLinksInTransaction(draftId, selections)
    }

    /** 导出当前账号有效任务及可恢复关联，不含图片或其他账号数据。 */
    suspend fun exportJson(): String = transaction { TodoBackup.export(this) }

    /** 全量校验后原子导入当前账号，同ID冲突不覆盖本地编辑。 */
    suspend fun importJson(json: String): Int = importJsonDetailed(json).importedCount

    /** 提供界面需要的完整恢复说明；同ID任务保留本地内容。 */
    suspend fun importJsonDetailed(json: String): TodoImportResult = transaction { TodoBackup.import(this, json) }

    /** 碎片调用此边界后复用同一个Room事务，锁顺序始终为账号再数据库。 */
    internal suspend fun <T> withOwner(block: suspend () -> T): T =
        AccountData.withTodoOwnerMutation(ownerKey, ownerEpoch, block)

    /** 一次操作同时提交状态、完成快照、事件与幂等结果。 */
    internal suspend fun <T> transaction(block: suspend () -> T): T = withOwner { database.withTransaction(block) }

    internal suspend fun requireTask(id: String, revision: Long? = null): TodoTask {
        val task = dao.task(ownerKey, id)?.takeIf { it.deletedAt == null }
            ?: throw TodoConflictException("Task no longer exists", "task_not_found", id)
        if (revision != null && revision != task.revision) throw TodoConflictException(
            "Task changed; query again before saving", taskId = id, expectedRevision = revision, actualRevision = task.revision)
        return task
    }

    internal suspend fun putDraftLinksInTransaction(draftId: String, selections: List<TodoSelection>) {
        require(selections.size <= 100 && selections.map { it.taskId }.distinct().size == selections.size) { "Invalid task selection" }
        val entryId = database.dao().draft(draftId)?.entryId
        val existingLinks = entryId?.let { dao.entryLinks(ownerKey, it) }.orEmpty().associateBy { it.taskId }
        selections.forEach { selection ->
            val isHistoricalLink = selection.requestedStatus == null && selection.taskId in existingLinks
            if (!isHistoricalLink) requireTask(selection.taskId)
            require(selection.requestedStatus == null || selection.requestedStatus in TodoRules.STATUSES)
        }
        dao.clearDraftLinks(ownerKey, draftId)
        dao.putDraftLinks(selections.map { TodoDraftLink(ownerKey, draftId, it.taskId, it.expectedRevision, it.requestedStatus, it.completedDay) })
    }

    /** 仅在日记保存事务内消费状态意图，删除/恢复和普通重读不会再次执行。 */
    internal suspend fun saveEntryLinksInTransaction(entryId: String, draftId: String,
        mutationId: String, selections: List<TodoSelection>) {
        require(selections.size <= 100 && selections.map { it.taskId }.distinct().size == selections.size) { "Invalid task selection" }
        val oldLinks = dao.entryLinks(ownerKey, entryId).associateBy { it.taskId }
        val links = selections.map { selection ->
            val status = selection.requestedStatus
            val previous = oldLinks[selection.taskId]
            if (status == null && previous != null) return@map previous
            val task = if (status == null) requireTask(selection.taskId) else {
                val operationId = "mosaic:$mutationId:${selection.taskId}:${selection.expectedRevision}:$status:${selection.completedDay}"
                changeStatusInTransaction(selection.taskId, status, selection.expectedRevision, operationId, selection.completedDay)
            }
            TodoEntryLink(ownerKey, entryId, task.id, task.title, task.status, System.currentTimeMillis())
        }
        dao.clearEntryLinks(ownerKey, entryId)
        dao.putEntryLinks(links)
        dao.clearDraftLinks(ownerKey, draftId)
    }

    private suspend fun changeStatusInTransaction(id: String, status: String, expectedRevision: Long,
        operationId: String, completedDay: Long?): TodoTask {
        val request = JSONObject().put("kind", "status").put("id", id).put("status", status)
            .put("revision", expectedRevision).put("completedDay", completedDay ?: JSONObject.NULL).toString()
        return taskOperation(operationId, request) {
            require(status in TodoRules.STATUSES) { "Invalid task status" }
            val old = requireTask(id, expectedRevision)
            if (old.status == status) old else {
                val input = old.copy(status = status, completedDay = completedDay)
                val saved = TodoRules.update(input, old, ownerKey, id, System.currentTimeMillis(), LocalDate.now().toEpochDay())
                persist(saved, old, operationId)
            }
        }
    }

    private suspend fun taskOperation(operationId: String, request: String, block: suspend () -> TodoTask): TodoTask {
        require(operationId.isNotBlank() && operationId.length <= 1000) { "Operation id is required" }
        dao.operation(ownerKey, operationId)?.let { previous ->
            check(previous.requestJson == request) { "Operation id was already used for different content" }
            return TodoJson.readTask(JSONObject(previous.resultJson))
        }
        val result = block()
        dao.putOperation(TodoOperation(ownerKey, operationId, request, TodoJson.task(result).toString(), System.currentTimeMillis()))
        return result
    }

    private suspend fun persist(task: TodoTask, old: TodoTask?, operationId: String): TodoTask {
        dao.putTask(task)
        if (task.deletedAt == null) rememberCategories(task)
        if (old?.status != task.status || old?.deletedAt != task.deletedAt) {
            dao.putEvent(TodoEvent(ownerKey, operationId, task.id, old?.status,
                if (task.deletedAt != null) "deleted" else task.status, task.completedDay, task.completionTagsJson, task.updatedAt))
        }
        return task
    }

    companion object {
        /** 每次取得当前账号快照，不缓存跨账号的实例。 */
        fun get(context: Context): TodoStore {
            val appContext = context.applicationContext
            AccountData.requireAvailable()
            val epoch = AccountData.epoch.value
            val owner = AccountData.key(appContext)
            check(epoch == AccountData.epoch.value) { "The account changed; retry" }
            return TodoStore(appContext, MosaicDatabase.get(appContext), owner, epoch)
        }
    }
}
