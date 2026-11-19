package io.github.nanomuse.focus

import io.github.nanomuse.mosaic.MosaicCrop
import io.github.nanomuse.mosaic.MosaicDraft
import io.github.nanomuse.mosaic.MosaicShape
import io.github.nanomuse.mosaic.MosaicStore
import io.github.nanomuse.todo.TodoSelection
import io.github.nanomuse.todo.TodoStore
import java.time.Instant
import java.time.ZoneId
import java.util.UUID

/** 专注心得使用独立且按账号隔离的草稿，不覆盖当天已有的自由记录。 */
object FocusReflectionDrafts {
    private const val PREFIX = "focus-reflection:"

    /** 同一账号和专注始终恢复同一份未提交心得。 */
    fun draftId(ownerKey: String, sessionId: String): String =
        "$PREFIX${ownerToken(ownerKey)}:$sessionId"

    /** 改期时保留专注草稿身份，避免下次点击结束记录时丢失原草稿。 */
    fun isReflectionDraft(id: String): Boolean = id.startsWith(PREFIX)

    /** 编辑器恢复持久草稿前核对归属，不能把旧账号正文作为新账号草稿打开。 */
    fun belongsToOwner(id: String, ownerKey: String): Boolean =
        id.startsWith("$PREFIX${ownerToken(ownerKey)}:")

    /** 持久化事实与初始关联一次提交；已存在的草稿完全沿用用户选择。 */
    suspend fun open(
        focus: FocusStore,
        todo: TodoStore,
        mosaic: MosaicStore,
        sessionId: String,
        zone: ZoneId = ZoneId.systemDefault(),
    ): MosaicDraft = focus.transaction {
        check(todo.database === focus.database && todo.ownerKey == focus.ownerKey &&
            todo.ownerEpoch == focus.ownerEpoch) { "Reflection stores must share an account" }
        val session = checkNotNull(focus.dao.session(focus.ownerKey, sessionId)?.takeIf {
            it.deletedAt == null && it.status == "finished" && it.mode != "break" && it.endedAt != null
        }) { "Focus is not available for a reflection" }
        val id = draftId(focus.ownerKey, session.id)
        mosaic.draft(id)?.let { return@transaction it }
        val draft = newDraft(session, id, zone)
        val task = session.taskId?.let { focus.database.todoDao().task(focus.ownerKey, it) }
            ?.takeIf { it.deletedAt == null }
        val selections = task?.let { listOf(TodoSelection(it.id, it.revision)) }.orEmpty()
        mosaic.putDraft(draft)
        todo.putDraftLinksInTransaction(id, selections)
        focus.putDraftInTransaction(id, listOf(session.id))
        draft
    }

    private fun newDraft(session: FocusSession, id: String, zone: ZoneId): MosaicDraft = MosaicDraft(
        id = id,
        day = Instant.ofEpochMilli(checkNotNull(session.endedAt)).atZone(zone).toLocalDate().toEpochDay(),
        habitId = null,
        entryId = null,
        text = "",
        mediaId = null,
        stagedPath = null,
        shape = MosaicShape.ROUNDED.id,
        focusX = MosaicCrop.DEFAULT_FOCUS_X,
        focusY = MosaicCrop.DEFAULT_FOCUS_Y,
        zoom = 1f,
        markDone = false,
        mood = null,
        mutationId = UUID.randomUUID().toString(),
        updatedAt = System.currentTimeMillis(),
    )

    private fun ownerToken(ownerKey: String): String =
        UUID.nameUUIDFromBytes(ownerKey.toByteArray(Charsets.UTF_8)).toString()
}
