package io.github.nanomuse.todo

import org.json.JSONObject

/** 保存编辑时的完整任务快照，不重新读取数据库而改变原修订号。 */
internal object TodoEditorSnapshot {
    private const val VERSION = 1

    /** 标签保留原JSON字符串，使恢复后的提交快照仍可直接进行相等比较。 */
    fun save(task: TodoTask): String = JSONObject().apply {
        put("version", VERSION)
        put("task", TodoJson.task(task))
        put("tagsJson", task.tagsJson)
        put("completionTagsJson", task.completionTagsJson)
    }.toString()

    /** 损坏、未知版本或其他账号的状态不进入当前编辑器。 */
    fun restore(value: String, ownerKey: String): TodoTask? = runCatching {
        val json = JSONObject(value)
        require(json.getInt("version") == VERSION)
        TodoJson.readTask(json.getJSONObject("task")).copy(
            tagsJson = json.getString("tagsJson"),
            completionTagsJson = json.getString("completionTagsJson"),
        ).takeIf { it.ownerKey == ownerKey }
    }.getOrNull()
}
