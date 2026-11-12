package io.github.nanomuse.coach

import java.util.UUID
import org.json.JSONObject

/** 自由教学与严格证据分开处理，阶段不再规定必须先答题才能继续听课。 */
object CoachTeachingProtocol {
    const val VERSION = "topic-v3"
    const val MIN_DELAY_MILLIS = 24 * 60 * 60 * 1000L
    val MODES = setOf("explain", "concept", "compare", "question", "practice", "review")
    val DIMENSIONS = setOf("understanding", "application")

    /** 保存教学回复；新的验证题必须在用户回答之前形成可追溯的记录。 */
    fun reply(state: CoachState, session: CoachSession, text: String, payload: String, now: Long): CoachSession {
        require(session.status in setOf("active", "waiting_real")) { "Lesson is not accepting replies" }
        require(text.isNotBlank()) { "A visible teaching reply is required" }
        val data = if (payload.isBlank()) JSONObject() else JSONObject(payload)
        // Android 的 optString 会把 JSON null 读成字符串 "null"，模型常为可选字段传 null。
        val mode = if (data.isNull("mode")) session.mode else data.optString("mode", session.mode)
        require(mode in MODES) { "Unknown teaching mode" }
        require(session.pendingTurnId == null || data.optString("requestTurnId") == session.pendingTurnId) {
            "This response belongs to an older message"
        }
        val evidence = parseEvidence(session, data)
        val turn = CoachTurn(UUID.randomUUID().toString(), "coach", text, mode,
            // "assessment": null 或 false 不是验证题，不能留下没有编号的验证回合。
            support = session.nextSupport, createdAt = now,
            purpose = if (data.optJSONObject("assessment") != null) "assessment" else "teaching")
        val assessment = data.optJSONObject("assessment")?.let { value ->
            createAssessment(state, session, turn, value, mode, now)
        }
        val savedTurn = if (assessment == null) turn else turn.copy(dimension = assessment.dimension,
            assessmentId = assessment.id, reviewKind = if (assessment.isDelayed) "delayed" else "immediate",
            reviewOfSessionId = assessment.reviewOfSessionId)
        return session.copy(turns = session.turns + savedTurn, evidence = session.evidence + evidence,
            mode = mode, stage = mode, pendingTurnId = null, assessment = assessment,
            nextSupport = if (assessment != null) "none" else session.nextSupport, status = "active")
    }

    /** 宿主保存原话时固定当时的题目和支持程度，后续模型不能改写该来源。 */
    fun message(session: CoachSession, text: String, user: CoachUserInput, purpose: String, now: Long): CoachSession {
        require(session.status in setOf("active", "complete")) { "Resume the lesson before sending a message" }
        require(session.status != "complete" || purpose != "attempt") { "Start a new lesson before a verification attempt" }
        requireUserQuote(text, user)
        require(purpose in setOf("question", "continue", "attempt")) { "Unknown message purpose" }
        val existing = session.turns.find { it.role == "user" && it.originMessageId == user.messageId }
        if (existing != null) return markExistingAttempt(session, existing, purpose)
        val pending = session.turns.find { it.id == session.pendingTurnId }
        val hasPendingAssessment = pending?.purpose in setOf("attempt", "report")
        require(purpose != "attempt" || session.pendingTurnId == null) { "Save feedback on the previous attempt first" }
        val assessment = session.assessment.takeIf { session.status == "active" }
            ?.takeIf { hasTraceableAssessment(session, it.id) }
        require(purpose != "attempt" || assessment != null) { "Save a verification question before an attempt" }
        val turn = CoachTurn(UUID.randomUUID().toString(), "user", text, session.mode,
            support = session.nextSupport, originMessageId = user.messageId, createdAt = now, purpose = purpose,
            assessmentId = assessment?.id.orEmpty(), dimension = assessment?.dimension.orEmpty(),
            reviewKind = if (assessment?.isDelayed == true) "delayed" else "immediate",
            reviewOfSessionId = assessment?.reviewOfSessionId.orEmpty())
        return session.copy(turns = session.turns + turn,
            pendingTurnId = if (hasPendingAssessment) session.pendingTurnId else turn.id, draft = "", assessment = null)
    }

    private fun markExistingAttempt(session: CoachSession, turn: CoachTurn, purpose: String): CoachSession {
        if (purpose != "attempt" || turn.purpose == "attempt") return session
        require(turn.assessmentId.isNotBlank()) { "Ordinary discussion cannot be upgraded to independent evidence" }
        require(!turn.sourceInvalidated && hasTraceableAssessment(session, turn.assessmentId)) {
            "The verification question must be present in a saved conversation reply"
        }
        return session.copy(turns = session.turns.map { if (it.id == turn.id) it.copy(purpose = "attempt") else it })
    }

    private fun hasTraceableAssessment(session: CoachSession, assessmentId: String): Boolean =
        session.turns.any { prompt -> prompt.role == "coach" && prompt.purpose == "assessment" &&
            prompt.assessmentId == assessmentId && !prompt.sourceInvalidated && hasVisibleSource(session, prompt) }

    private fun hasVisibleSource(session: CoachSession, prompt: CoachTurn): Boolean {
        if (session.chatSessionId.isBlank()) return true
        if (prompt.originMessageId.isBlank()) return false
        // 同来源ID最后一条是宿主归档正文；旧版错误补绑不能凭非空ID继续通过。
        val visible = session.turns.lastOrNull { it.role == "coach" && it.originMessageId == prompt.originMessageId }
        return visible != null && !visible.sourceInvalidated && visible.text.contains(prompt.text)
    }

    private fun createAssessment(state: CoachState, session: CoachSession, turn: CoachTurn, data: JSONObject,
        mode: String, now: Long): CoachAssessment {
        require(mode in setOf("practice", "review")) { "Verification questions require practice or review mode" }
        val dimension = data.getString("dimension")
        require(dimension in DIMENSIONS) { "Choose understanding or application evidence" }
        require(session.turns.none { it.role == "coach" && it.purpose == "assessment" && it.text.trim() == turn.text.trim() }) {
            "Independent practice needs a new question"
        }
        val reviewId = if (data.isNull("reviewOfSessionId")) "" else data.optString("reviewOfSessionId") // null 表示不是复习题
        val isDelayed = if (reviewId.isBlank()) false else {
            val previous = state.session(reviewId)
            require(previous.id != session.id && previous.topicId == session.topicId && previous.status == "complete") {
                "A delayed review must reference an earlier completed lesson in this topic"
            }
            require(previous.endedAt > 0 && now - previous.endedAt >= MIN_DELAY_MILLIS) {
                "The host clock has not reached the delayed review interval"
            }
            require(previous.course.version == session.course.version && hasImmediateEvidence(previous, dimension)) {
                "A delayed review needs valid earlier independent evidence in the same dimension"
            }
            true
        }
        return CoachAssessment(UUID.randomUUID().toString(), turn.id, dimension, reviewId, isDelayed)
    }

    private fun hasImmediateEvidence(session: CoachSession, dimension: String): Boolean = session.evidence.any { evidence ->
        evidence.met && !evidence.disputed && session.turns.any {
            it.id == evidence.turnId && it.dimension == dimension && it.reviewKind == "immediate"
        } && runCatching { validateEvidence(session, evidence) }.isSuccess
    }

    private fun isValidDelayedReview(state: CoachState, session: CoachSession, turn: CoachTurn): Boolean {
        if (turn.reviewKind != "delayed") return false
        val previous = state.sessions.singleOrNull { it.id == turn.reviewOfSessionId } ?: return false
        return previous.topicId == session.topicId && previous.status == "complete" && previous.endedAt > 0 &&
            turn.createdAt - previous.endedAt >= MIN_DELAY_MILLIS && previous.course.version == session.course.version &&
            !previous.requiresCourseReview && hasImmediateEvidence(previous, turn.dimension)
    }

    private fun parseEvidence(session: CoachSession, data: JSONObject): List<CoachEvidence> {
        val entries = data.optJSONArray("evidence") ?: return emptyList()
        require(entries.length() <= 24) { "Too many evidence entries" }
        return (0 until entries.length()).map { index ->
            val value = entries.getJSONObject(index)
            CoachEvidence(value.getString("criterionId"), value.getString("turnId"), value.getString("quote"),
                value.getString("reason"), value.getBoolean("met")).also { validateEvidence(session, it) }
        }
    }

    private fun validateEvidence(session: CoachSession, evidence: CoachEvidence) {
        val criterion = session.course.units.single { it.id == session.unitId }.criteria.singleOrNull {
            it.id == evidence.criterionId } ?: error("Unknown evidence criterion")
        val turn = session.turns.singleOrNull { it.id == evidence.turnId && it.role == "user" }
            ?: error("Evidence must reference a saved user message")
        require(!turn.sourceInvalidated) { "The original message was edited or deleted" }
        require(evidence.quote.isNotBlank() && turn.text.contains(evidence.quote) && evidence.reason.isNotBlank()) {
            "Evidence requires an exact quote and specific reason"
        }
        if (!evidence.met) return
        require(turn.support == "none") { "Hinted work cannot satisfy independent evidence" }
        if (criterion.requiresRealAction) {
            require(turn.context == "reported_real" && turn.stage == "real_report") { "An actual reported action is required" }
            return
        }
        require(turn.purpose == "attempt" && turn.assessmentId.isNotBlank()) { "A saved verification attempt is required" }
        require(hasTraceableAssessment(session, turn.assessmentId)) {
            "The verification question must be present in a saved conversation reply"
        }
        require(turn.dimension == dimension(criterion)) { "Understanding and application evidence cannot replace each other" }
        require(session.turns.any { it.role == "coach" && it.purpose == "assessment" &&
            !it.sourceInvalidated && it.assessmentId == turn.assessmentId && it.createdAt <= turn.createdAt }) { "Verification question not found" }
    }

    /** 新课可识别内置标准的明确ID，自定义未声明的标准不会被推断成理解证据。 */
    fun dimension(criterion: CoachCriterion): String = criterion.dimension.ifBlank {
        when (criterion.id) { "understanding" -> "understanding"; "application", "practice" -> "application"; else -> "" }
    }

    /** 汇总当前课程版本同一专题的证据，旧版记录不参与双维度达成。 */
    fun progress(state: CoachState, topicId: String): CoachTopicProgress {
        val topic = state.topic(topicId)
        if (topic.status != "active") return CoachTopicProgress(false, false, false, false)
        val course = state.track(topic.courseId).course
        val criteria = course.units.singleOrNull { it.id == topic.unitId }?.criteria.orEmpty()
        val sessions = state.sessions.filter { it.topicId == topicId && it.teachingProtocol == VERSION &&
            it.course.version == course.version && !it.requiresCourseReview }
        val met = criteria.filter { criterion -> sessions.any { session -> session.evidence.any { evidence ->
            evidence.criterionId == criterion.id && evidence.met && !evidence.disputed &&
                runCatching { validateEvidence(session, evidence) }.isSuccess
        } } }
        val understanding = criteria.filter { dimension(it) == "understanding" }
        val application = criteria.filter { dimension(it) == "application" }
        val hasUnderstanding = understanding.isNotEmpty() && understanding.all { it in met }
        val hasApplication = application.isNotEmpty() && application.all { it in met }
        val delayed = sessions.any { session -> session.evidence.any { evidence -> evidence.met && !evidence.disputed &&
            session.turns.any { it.id == evidence.turnId && isValidDelayedReview(state, session, it) } &&
            runCatching { validateEvidence(session, evidence) }.isSuccess } }
        return CoachTopicProgress(hasUnderstanding, hasApplication, delayed,
            hasUnderstanding && hasApplication && delayed && criteria.all { it in met })
    }
}
