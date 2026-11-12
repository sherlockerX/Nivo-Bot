package io.github.nanomuse.todo

import org.json.JSONArray
import org.json.JSONObject

/** 明确版本的本地备份和幂等快照序列化，不读取照片。 */
object TodoJson {
    /** 序列化完整任务，键顺序由此方法固定。 */
    fun task(task: TodoTask): JSONObject = JSONObject().apply {
        put("ownerKey", task.ownerKey); put("id", task.id); put("title", task.title)
        put("notes", task.notes); put("status", task.status)
        put("scheduledDay", task.scheduledDay ?: JSONObject.NULL)
        put("dueDay", task.dueDay ?: JSONObject.NULL); put("groupName", task.groupName)
        put("tags", JSONArray(task.tagsJson)); put("isImportant", task.isImportant)
        put("isUrgent", task.isUrgent); put("revision", task.revision)
        put("createdAt", task.createdAt); put("updatedAt", task.updatedAt)
        put("deletedAt", task.deletedAt ?: JSONObject.NULL)
        put("completedDay", task.completedDay ?: JSONObject.NULL)
        put("completedAt", task.completedAt ?: JSONObject.NULL)
        put("completionTags", JSONArray(task.completionTagsJson))
    }

    /** 从已版本校验的数据解析任务，不信任导入归属。 */
    fun readTask(json: JSONObject): TodoTask = TodoTask(
        ownerKey = json.optString("ownerKey"), id = json.getString("id"), title = json.getString("title"),
        notes = json.optString("notes"), status = json.getString("status"),
        scheduledDay = nullableLong(json, "scheduledDay"), dueDay = nullableLong(json, "dueDay"),
        groupName = json.optString("groupName"), tagsJson = json.getJSONArray("tags").toString(),
        isImportant = json.optBoolean("isImportant"), isUrgent = json.optBoolean("isUrgent"),
        revision = json.optLong("revision"), createdAt = json.optLong("createdAt"), updatedAt = json.optLong("updatedAt"),
        deletedAt = nullableLong(json, "deletedAt"), completedDay = nullableLong(json, "completedDay"),
        completedAt = nullableLong(json, "completedAt"),
        completionTagsJson = json.optJSONArray("completionTags")?.toString() ?: "[]",
    )

    /** 备份只保留任务关联的文字快照，不包含媒体路径。 */
    fun link(link: TodoEntryLink): JSONObject = JSONObject().apply {
        put("entryId", link.entryId); put("taskId", link.taskId); put("title", link.title)
        put("statusSnapshot", link.statusSnapshot); put("linkedAt", link.linkedAt)
    }

    /** 草稿关联用于稳定比较，不包含任务正文。 */
    fun selections(selections: List<TodoSelection>): JSONArray = JSONArray().apply {
        selections.sortedBy { it.taskId }.forEach { selection ->
            put(JSONObject().apply {
                put("taskId", selection.taskId); put("expectedRevision", selection.expectedRevision)
                put("requestedStatus", selection.requestedStatus ?: JSONObject.NULL)
                put("completedDay", selection.completedDay ?: JSONObject.NULL)
            })
        }
    }

    private fun nullableLong(json: JSONObject, key: String): Long? =
        if (!json.has(key) || json.isNull(key)) null else json.getLong(key)
}
