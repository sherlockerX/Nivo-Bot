package io.github.nanomuse.todo

import org.json.JSONObject

/** 导出、导入和文件选择器共同使用的完整备份容量限制。 */
internal object TodoBackupLimits {
    const val MAX_BACKUP_BYTES = 8_000_000
    const val MAX_TASKS = 10_000
    const val MAX_LINKS = 50_000
    const val MAX_HISTORY_ROWS = 50_000

    /** 按实际UTF-8文件大小校验，避免中文备份字符数合格但无法读取。 */
    fun validateText(text: String) {
        require(text.length <= MAX_BACKUP_BYTES && text.toByteArray(Charsets.UTF_8).size <= MAX_BACKUP_BYTES) {
            "Backup is too large"
        }
    }

    /** 同时约束所有集合，拒绝超限备份而不截断任务或历史账本。 */
    fun validateDocument(json: JSONObject) {
        require((json.optJSONArray("categories")?.length() ?: 0) <= MAX_TASKS) { "Too many categories in backup" }
        require(json.getJSONArray("tasks").length() <= MAX_TASKS) { "Too many tasks in backup" }
        require((json.optJSONArray("links")?.length() ?: 0) <= MAX_LINKS) { "Too many links in backup" }
        require((json.optJSONArray("events")?.length() ?: 0) <= MAX_HISTORY_ROWS &&
            (json.optJSONArray("categoryOperations")?.length() ?: 0) <= MAX_HISTORY_ROWS &&
            (json.optJSONArray("operations")?.length() ?: 0) <= MAX_HISTORY_ROWS) { "Backup history is too large" }
    }
}
