package io.github.nanomuse.todo

import org.json.JSONArray
import org.json.JSONObject

/** 备份恢复状态历史和幂等账本；同ID本地任务的历史保持原样。 */
internal object TodoBackupHistory {
    internal suspend fun exportEvents(store: TodoStore): JSONArray = JSONArray().apply {
        store.dao.events(store.ownerKey).forEach { event -> put(JSONObject().apply {
            put("operationId", event.operationId); put("taskId", event.taskId)
            put("previousStatus", event.previousStatus ?: JSONObject.NULL); put("status", event.status)
            put("completedDay", event.completedDay ?: JSONObject.NULL)
            put("tags", JSONArray(event.tagsJson)); put("createdAt", event.createdAt)
        }) }
    }

    internal suspend fun exportOperations(store: TodoStore): JSONArray = JSONArray().apply {
        store.dao.operations(store.ownerKey).filterNot { isCategoryOperation(it.requestJson) }.forEach { operation -> put(JSONObject().apply {
            put("operationId", operation.operationId); put("request", operation.requestJson)
            put("result", operation.resultJson); put("createdAt", operation.createdAt)
        }) }
    }

    /** 分类回执独立导出，旧版本仍能读取任务账本。 */
    internal suspend fun exportCategoryOperations(store:TodoStore):JSONArray=JSONArray().apply {
        store.dao.operations(store.ownerKey).filter { isCategoryOperation(it.requestJson) }.forEach { operation ->
            put(JSONObject().put("operationId",operation.operationId).put("request",operation.requestJson)
                .put("result",operation.resultJson).put("createdAt",operation.createdAt))
        }
    }

    private fun isCategoryOperation(request:String):Boolean = runCatching {
        JSONObject(request).optString("kind") in setOf("create_category","delete_category")
    }.getOrDefault(false)

    internal suspend fun import(store: TodoStore, json: JSONObject, taskIds: Set<String>) {
        val operations = json.optJSONArray("operations") ?: JSONArray()
        val events = json.optJSONArray("events") ?: JSONArray()
        val restoredIds = restoreOperations(store, operations, taskIds)
        val categoryOperations=json.optJSONArray("categoryOperations") ?: JSONArray()
        require(categoryOperations.length()<=TodoBackupLimits.MAX_HISTORY_ROWS)
        for(index in 0 until categoryOperations.length()) {
            val row=categoryOperations.getJSONObject(index)
            val id=row.getString("operationId")
            require(id.matches(Regex("[A-Za-z0-9_.:-]{1,160}")))
            val request=JSONObject(row.getString("request"))
            require(isCategoryOperation(request.toString()))
            val kind=request.getString("categoryKind")
            val name=TodoCategoryRules.name(kind,request.getString("name"))
            val result=JSONObject(row.getString("result"))
            require(result.getString("kind")==kind && result.getString("name")==name)
            if(request.getString("kind")=="delete_category") require(result.getBoolean("deleted") && result.getBoolean("tasksPreserved") && request.getLong("expectedCreatedAt")>=0)
            else require(result.getLong("createdAt")>=0)
            if(store.dao.operation(store.ownerKey,id)==null) store.dao.putOperation(TodoOperation(store.ownerKey,id,request.toString(),result.toString(),row.getLong("createdAt")))
        }
        for (index in 0 until events.length()) {
            val event = events.getJSONObject(index)
            val id = event.getString("operationId")
            if (id !in restoredIds) continue
            require(event.getString("taskId") in taskIds && event.getString("status") in TodoRules.STATUSES + "deleted")
            val day = if (event.isNull("completedDay")) null else event.getLong("completedDay")
            if (day != null) {
                TodoRules.validateDay(day)
                require(day <= java.time.LocalDate.now().toEpochDay()) { "Future completion event" }
            }
            store.dao.putEvent(TodoEvent(store.ownerKey, id, event.getString("taskId"),
                if (event.isNull("previousStatus")) null else event.getString("previousStatus"),
                event.getString("status"), day, todoTagsJson(parseTodoTags(event.getJSONArray("tags").toString())),
                event.getLong("createdAt")))
        }
    }

    private suspend fun restoreOperations(store: TodoStore, rows: JSONArray, taskIds: Set<String>): Set<String> {
        val restored = mutableSetOf<String>()
        for (index in 0 until rows.length()) {
            val row = rows.getJSONObject(index)
            val id = row.getString("operationId")
            require(id.isNotBlank() && id.length <= 1000)
            if (id.startsWith("import:")) {
                restoreImportReceipt(store, id, row)
                continue
            }
            val result = TodoJson.readTask(JSONObject(row.getString("result")))
            if (result.id !in taskIds) continue
            val rebound = result.copy(ownerKey = store.ownerKey)
            validateResult(rebound)
            val request = JSONObject(row.getString("request"))
            require(request.getString("kind") in setOf("save", "status", "delete"))
            request.optJSONObject("task")?.put("ownerKey", store.ownerKey)
            if (request.getString("kind") == "save") {
                val requestTask = TodoJson.readTask(request.getJSONObject("task"))
                require(requestTask.id.isEmpty() || requestTask.id == result.id) { "Mismatched operation task" }
            } else require(request.getString("id") == result.id) { "Mismatched operation task" }
            val previous = store.dao.operation(store.ownerKey, id)
            // 全局操作ID冲突时保留本地账本；任务仍可用新的操作ID继续编辑。
            if (previous != null) continue
            store.dao.putOperation(TodoOperation(store.ownerKey, id, request.toString(), TodoJson.task(rebound).toString(), row.getLong("createdAt")))
            restored += id
        }
        return restored
    }

    private fun validateResult(task: TodoTask) {
        val now = System.currentTimeMillis()
        TodoRules.update(task, null, task.ownerKey, task.id, now, java.time.LocalDate.now().toEpochDay())
        require(task.revision >= 1 && task.createdAt >= 0 && task.updatedAt >= task.createdAt)
        if (task.status == "done") require(task.completedDay != null && task.completedAt != null && task.completedAt in 0..now)
        parseTodoTags(task.completionTagsJson)
    }

    private suspend fun restoreImportReceipt(store: TodoStore, id: String, row: JSONObject) {
        val result = JSONObject(row.getString("result"))
        require(result.getInt("count") >= 0 && result.optInt("keptLocal") >= 0 && result.optInt("missingEntries") >= 0)
        require(row.getString("request") == id) { "Invalid import receipt" }
        if (store.dao.operation(store.ownerKey, id) == null) {
            store.dao.putOperation(TodoOperation(store.ownerKey, id, id, result.toString(), row.getLong("createdAt")))
        }
    }
}
