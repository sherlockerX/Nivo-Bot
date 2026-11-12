package io.github.nanomuse.todo

import java.security.MessageDigest
import java.time.LocalDate
import org.json.JSONArray
import org.json.JSONObject

/** 有界本地备份，导入只写当前账号且不覆盖已有同ID任务。 */
internal object TodoBackup {
    internal suspend fun export(store: TodoStore): String = JSONObject().apply {
        put("format", "nanomuse-todo"); put("version", 2)
        put("tasks", JSONArray().apply { store.dao.allTasks(store.ownerKey).forEach { put(TodoJson.task(it)) } })
        put("categories", JSONArray().apply { store.dao.categories(store.ownerKey).forEach { category ->
            put(JSONObject().put("kind", category.kind).put("name", category.name)
                .put("createdAt", category.createdAt).put("updatedAt", category.updatedAt))
        } })
        put("links", JSONArray().apply { store.dao.allEntryLinks(store.ownerKey).forEach { put(TodoJson.link(it)) } })
        put("events", TodoBackupHistory.exportEvents(store))
        put("operations", TodoBackupHistory.exportOperations(store))
        put("categoryOperations", TodoBackupHistory.exportCategoryOperations(store))
    }.also(TodoBackupLimits::validateDocument).toString(2).also(TodoBackupLimits::validateText)

    internal suspend fun import(store: TodoStore, text: String): TodoImportResult {
        TodoBackupLimits.validateText(text)
        val json = JSONObject(text)
        require(json.getString("format") == "nanomuse-todo" && json.getInt("version") in 1..2) { "Unsupported backup version" }
        TodoBackupLimits.validateDocument(json)
        val operationId = "import:" + MessageDigest.getInstance("SHA-256").digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        store.dao.operation(store.ownerKey, operationId)?.let {
            val result = JSONObject(it.resultJson)
            return TodoImportResult(result.getInt("count"), result.optInt("keptLocal"), result.optInt("missingEntries"))
        }
        val rows = json.getJSONArray("tasks")
        val now = System.currentTimeMillis()
        val tasks = (0 until rows.length()).map { validatedTask(rows.getJSONObject(it), store.ownerKey, now) }
        require(tasks.map { it.id }.distinct().size == tasks.size) { "Duplicate task ids in backup" }
        val imported = tasks.filter { store.dao.task(store.ownerKey, it.id) == null }
        val categories = json.optJSONArray("categories") ?: JSONArray()
        val directory = (0 until categories.length()).map { index ->
            val row = categories.getJSONObject(index)
            val kind = row.getString("kind")
            val name = TodoCategoryRules.name(kind, row.getString("name"))
            val created = row.getLong("createdAt")
            val updated = row.getLong("updatedAt")
            require(created >= 0 && updated >= created) { "Invalid category timestamps" }
            TodoCategory(store.ownerKey, kind, name, created, updated)
        }
        store.dao.putCategories(directory)
        imported.forEach { store.dao.putTask(it); store.rememberCategories(it) }
        val ids = imported.map { it.id }.toSet()
        val missing = importLinks(store, json.optJSONArray("links") ?: JSONArray(), tasks.map { it.id }.toSet(), ids)
        TodoBackupHistory.import(store, json, ids)
        val result = TodoImportResult(imported.size, tasks.size - imported.size, missing)
        store.dao.putOperation(TodoOperation(store.ownerKey, operationId, operationId,
            JSONObject().put("count", result.importedCount).put("keptLocal", result.keptLocalCount)
                .put("missingEntries", result.missingEntryCount).toString(), now))
        return result
    }

    private fun validatedTask(json: JSONObject, owner: String, now: Long): TodoTask {
        val input = TodoJson.readTask(json).copy(ownerKey = owner)
        require(input.id.isNotBlank() && input.id.length <= 200 && input.revision >= 1) { "Invalid imported task" }
        require(input.createdAt >= 0 && input.updatedAt >= input.createdAt) { "Invalid task timestamps" }
        val normalized = TodoRules.update(input, null, owner, input.id, now, LocalDate.now().toEpochDay())
            .copy(revision = input.revision, createdAt = input.createdAt, updatedAt = input.updatedAt, deletedAt = input.deletedAt)
        if (input.status != "done") return normalized
        require(input.completedDay != null && input.completedAt != null && input.completedAt in 0..now) {
            "Completed task is missing its completion date or is in the future"
        }
        return normalized.copy(completedAt = input.completedAt,
            completionTagsJson = todoTagsJson(parseTodoTags(input.completionTagsJson)))
    }

    private suspend fun importLinks(store: TodoStore, rows: JSONArray, taskIds: Set<String>, importedIds: Set<String>): Int {
        val links = mutableListOf<TodoEntryLink>()
        val missingEntries = mutableSetOf<String>()
        for (index in 0 until rows.length()) {
            val row = rows.getJSONObject(index)
            val taskId = row.getString("taskId")
            require(taskId in taskIds && row.getString("statusSnapshot") in TodoRules.STATUSES) { "Invalid task link" }
            val entryId = row.getString("entryId")
            // 来源不存在时不伪造日记记录，也不恢复指向悬空ID的关联。
            val entry = store.database.dao().entry(entryId)
            if (entry == null || entry.deletedAt != null) { missingEntries += entryId; continue }
            val title = row.getString("title")
            require(title.length <= 500)
            if (taskId in importedIds) {
                links += TodoEntryLink(store.ownerKey, entryId, taskId, title, row.getString("statusSnapshot"), row.getLong("linkedAt"))
            }
        }
        store.dao.putEntryLinks(links)
        return missingEntries.size
    }
}
