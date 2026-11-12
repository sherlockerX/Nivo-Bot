package io.github.nanomuse.coach

import java.util.UUID

/** 编辑器绑定当前题目和用户回合，单纯保存草稿不会产生新题目。 */
data class CoachAnswerDraftTarget(
    val sessionId: String, val courseVersion: String, val unitId: String,
    val stage: String, val status: String, val pendingTurnId: String?,
    val nextSupport: String, val turnIds: List<String>, val requiresCourseReview: Boolean,
)

/** 延迟保存与离开页面时的刷盘共用同一入口，不改变已提交的原始回答。 */
object CoachAnswerDraftPolicy {
    /** 只捕获决定题目身份的字段，避免草稿自身更新导致编辑器重建。 */
    fun target(session: CoachSession): CoachAnswerDraftTarget = CoachAnswerDraftTarget(
        session.id, session.course.version, session.unitId, session.stage, session.status,
        session.pendingTurnId, session.nextSupport, session.turns.map { it.id }, session.requiresCourseReview,
    )

    /** 校验编辑器仍属于当前可作答题目，不能只比较可能重复的阶段名称。 */
    fun canSave(editor: CoachAnswerDraftTarget, session: CoachSession): Boolean =
        target(session) == editor && session.status == "active" && session.pendingTurnId == null &&
            session.stage in setOf("first", "retry", "probe") && !session.requiresCourseReview

    /** 检查与提交共用execute的服务锁，作答和换题不能插入两者之间。 */
    fun save(service: CoachCommandService, editor: CoachAnswerDraftTarget, text: String,
        isCurrentInput: () -> Boolean = { true }): CoachResult? =
        synchronized(service) {
            if (!isCurrentInput()) return@synchronized null
            val state = service.state.value
            val session = state.sessions.find { it.id == editor.sessionId } ?: return@synchronized null
            if (!canSave(editor, session)) return@synchronized null
            if (session.draft == text) return@synchronized null
            service.execute(CoachCommand("save_input", UUID.randomUUID().toString(),
                state.revision, session.id, text))
        }
}
