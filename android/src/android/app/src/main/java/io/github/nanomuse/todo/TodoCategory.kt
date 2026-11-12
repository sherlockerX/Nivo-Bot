package io.github.nanomuse.todo

import androidx.room.Entity

/** 账号内可复用分类目录，独立于任务存活，名称沿用任务的精确语义。 */
@Entity(tableName = "todo_categories", primaryKeys = ["ownerKey", "kind", "name"])
data class TodoCategory(
    val ownerKey: String,
    val kind: String,
    val name: String,
    val createdAt: Long,
    val updatedAt: Long,
)

/** 分组与标签共用名称约束，不擅自合并不同大小写或修改历史快照。 */
object TodoCategoryRules {
    const val GROUP = "group"
    const val TAG = "tag"

    /** 去除首尾空白，拒绝空名称、换行及超长输入。 */
    fun name(kind: String, text: String): String {
        require(kind == GROUP || kind == TAG) { "Unknown category kind" }
        val value = text.trim()
        require(value.isNotEmpty() && value.length <= if (kind == GROUP) 200 else 80) { "Invalid category name" }
        require(value.none { it == '\n' || it == '\r' || it == '\u0000' }) { "Category must fit one line" }
        return value
    }
}
