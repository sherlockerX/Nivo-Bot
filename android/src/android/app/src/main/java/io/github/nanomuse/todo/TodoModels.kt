package io.github.nanomuse.todo

import androidx.room.Entity
import androidx.room.Index
import org.json.JSONArray

/** 个人待办，完成快照只在真正进入完成状态时生成。 */
@Entity(tableName = "todo_tasks", primaryKeys = ["ownerKey", "id"], indices = [
    Index(value = ["ownerKey", "status", "deletedAt"]),
    Index(value = ["ownerKey", "scheduledDay"]),
    Index(value = ["ownerKey", "completedDay"]),
])
data class TodoTask(
    val ownerKey: String = "",
    val id: String = "",
    val title: String = "",
    val notes: String = "",
    val status: String = "todo",
    val scheduledDay: Long? = null,
    val dueDay: Long? = null,
    val groupName: String = "",
    val tagsJson: String = "[]",
    val isImportant: Boolean = false,
    val isUrgent: Boolean = false,
    val revision: Long = 0,
    val createdAt: Long = 0,
    val updatedAt: Long = 0,
    val deletedAt: Long? = null,
    val completedDay: Long? = null,
    val completedAt: Long? = null,
    val completionTagsJson: String = "[]",
) {
    /** 当前标签，去空白并按首次出现顺序去重。 */
    fun tags(): List<String> = parseTodoTags(tagsJson)
}

/** 草稿中的明确状态意图；空状态只关联，不改变任务。 */
data class TodoSelection(
    val taskId: String,
    val expectedRevision: Long,
    val requestedStatus: String? = null,
    val completedDay: Long? = null,
)

/** 任务已被修改或移除，编辑器保留草稿并提示重新选择。 */
class TodoConflictException(
    message: String,
    val code: String = "stale_revision",
    val taskId: String? = null,
    val expectedRevision: Long? = null,
    val actualRevision: Long? = null,
) : IllegalStateException(message)

/** 导入结果明确区分新增、保留本地和缺失来源，不把部分恢复伪报完整。 */
data class TodoImportResult(val importedCount: Int, val keptLocalCount: Int, val missingEntryCount: Int)

/** 碎片保存时的任务快照，任务改名和重开不改写历史。 */
@Entity(tableName = "todo_entry_links", primaryKeys = ["ownerKey", "entryId", "taskId"],
    indices = [Index(value = ["ownerKey", "taskId"])])
data class TodoEntryLink(
    val ownerKey: String,
    val entryId: String,
    val taskId: String,
    val title: String,
    val statusSnapshot: String,
    val linkedAt: Long,
)

/** 草稿关联与日记草稿同库保存，不在自动保存时修改任务状态。 */
@Entity(tableName = "todo_draft_links", primaryKeys = ["ownerKey", "draftId", "taskId"])
data class TodoDraftLink(
    val ownerKey: String,
    val draftId: String,
    val taskId: String,
    val expectedRevision: Long,
    val requestedStatus: String?,
    val completedDay: Long?,
)

/** 幂等结果持久化，同一操作ID不能悄悄变成另一条命令。 */
@Entity(tableName = "todo_operations", primaryKeys = ["ownerKey", "operationId"])
data class TodoOperation(
    val ownerKey: String,
    val operationId: String,
    val requestJson: String,
    val resultJson: String,
    val createdAt: Long,
)

/** 状态事件供追溯；有效完成统计使用任务当前快照。 */
@Entity(tableName = "todo_events", primaryKeys = ["ownerKey", "operationId"],
    indices = [Index(value = ["ownerKey", "taskId"])])
data class TodoEvent(
    val ownerKey: String,
    val operationId: String,
    val taskId: String,
    val previousStatus: String?,
    val status: String,
    val completedDay: Long?,
    val tagsJson: String,
    val createdAt: Long,
)

/** 严格解析标签，拒绝损坏或非字符串JSON而不静默丢数据。 */
fun parseTodoTags(json: String): List<String> {
    val array = JSONArray(json)
    require(array.length() <= 50) { "Too many tags" }
    return (0 until array.length()).map { index ->
        require(array.get(index) is String) { "Tags must be strings" }
        array.getString(index).trim().also { require(it.length <= 80) { "Tag too long" } }
    }.filter { it.isNotEmpty() }.distinct()
}

/** 生成规范标签JSON，供界面、导入和工具共用。 */
fun todoTagsJson(tags: List<String>): String = JSONArray(tags.map(String::trim).filter(String::isNotEmpty).distinct()).toString()
