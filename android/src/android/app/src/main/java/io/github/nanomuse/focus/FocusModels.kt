package io.github.nanomuse.focus

import androidx.room.Entity

/** 每次专注保留开始时任务语义，任务改名不改写历史。 */
@Entity(tableName = "focus_sessions", primaryKeys = ["ownerKey", "id"])
data class FocusSession(
    val ownerKey: String, val id: String, val title: String, val taskId: String?,
    val groupName: String, val tagsJson: String, val mode: String, val targetMs: Long,
    val status: String = "running", val elapsedMs: Long = 0,
    val startedAt: Long, val endedAt: Long? = null, val updatedAt: Long,
    val runningWall: Long, val runningElapsed: Long, val bootCount: Int,
    val revision: Long = 1, val deletedAt: Long? = null,
)

/** 实际计时区间，暂停间隔不入库，跨午夜统计按区间拆分。 */
@Entity(tableName = "focus_spans", primaryKeys = ["ownerKey", "id"])
data class FocusSpan(val ownerKey: String, val id: String, val sessionId: String, val startedAt: Long, val durationMs: Long)

/** 同一操作ID的命令结果持久化，防止重试重复开表或结束。 */
@Entity(tableName = "focus_operations", primaryKeys = ["ownerKey", "id"])
data class FocusOperation(val ownerKey: String, val id: String, val request: String, val result: String)

/** 日记保留选择当时的专注快照，即使之后删除专注记录也可回顾。 */
@Entity(tableName = "focus_entry_links", primaryKeys = ["ownerKey", "entryId", "sessionId"])
data class FocusEntryLink(val ownerKey: String, val entryId: String, val sessionId: String, val title: String,
    val startedAt: Long, val endedAt: Long, val durationMs: Long)

/** 专注选择随日记草稿原子保存。 */
@Entity(tableName = "focus_draft_links", primaryKeys = ["ownerKey", "draftId", "sessionId"])
data class FocusDraftLink(val ownerKey: String, val draftId: String, val sessionId: String)
