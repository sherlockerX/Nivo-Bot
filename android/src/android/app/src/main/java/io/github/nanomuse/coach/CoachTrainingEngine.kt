package io.github.nanomuse.coach

import java.util.UUID
import org.json.JSONObject

/** 模型负责教学判断，客户端负责合法阶段、原文引用和完成门槛。 */
object CoachTrainingEngine {
    /** 应用一次完整教练响应，不接受中途流片段或过期回合。 */
    fun reply(session: CoachSession, text: String, payload: String): CoachSession {
        require(session.status in setOf("active", "waiting_real")) { "Session is not accepting replies" }
        require(text.isNotBlank()) { "A visible coaching reply is required" }
        val data = JSONObject(payload)
        val next = data.getString("next")
        validateTransition(session, next)
        val requestTurnId = data.optString("requestTurnId")
        require(session.pendingTurnId == null || requestTurnId == session.pendingTurnId) { "This response belongs to an older answer" }
        val newEvidence = parseEvidence(data)
        newEvidence.forEach { validateEvidence(session, it) }
        val evidence = session.evidence + newEvidence
        if (next == "probe") require(session.turns.none { it.role == "coach" && it.text.trim() == text.trim() }) {
            "Independent practice must use a new scenario, not repeat the previous prompt"
        }
        val coachTurn = CoachTurn(UUID.randomUUID().toString(), "coach", text, next,
            support = if (next == "retry") "hinted" else "none")
        val updated = session.copy(turns = session.turns + coachTurn, evidence = evidence,
            stage = next, pendingTurnId = null, nextSupport = if (next == "retry") "hinted" else "none",
            summary = if (next == "complete") text else session.summary)
        if (next != "complete") return updated.copy(status = "active")
        val requiresReal = unit(session).criteria.any { it.requiresRealAction }
        return updated.copy(status = if (requiresReal && !demonstrated(updated)) "waiting_real" else "complete")
    }

    /** 所有标准分别满足才展示目标达成，不以平均分抵消缺项。 */
    fun demonstrated(session: CoachSession): Boolean {
        if (session.stage != "complete") return false
        val criteria = unit(session).criteria
        return criteria.isNotEmpty() && criteria.all { criterion ->
            session.evidence.any { evidence ->
                val turn = session.turns.find { it.id == evidence.turnId }
                evidence.criterionId == criterion.id && evidence.met && !evidence.disputed && turn != null &&
                    turn.support == "none" && if (criterion.requiresRealAction) {
                        turn.context == "reported_real" && turn.stage == "real_report"
                    } else turn.stage == "probe"
            }
        }
    }

    private fun validateTransition(session: CoachSession, next: String) {
        val allowed = when (session.stage) {
            "setup" -> setOf("first")
            "first", "retry" -> setOf("retry", "probe")
            "probe", "real_report" -> setOf("retry", "probe", "complete")
            "complete" -> emptySet()
            else -> emptySet()
        }
        require(next in allowed) { "Invalid training stage transition" }
        require(session.stage == "setup" || session.pendingTurnId != null ||
            (session.nextSupport == "hinted" && next == "retry")) { "A user answer is required before assessment" }
        if (next == "probe") {
            require(session.turns.any { it.role == "user" }) { "Keep the first attempt before independent practice" }
        }
    }

    private fun parseEvidence(data: JSONObject): List<CoachEvidence> {
        val values = data.optJSONArray("evidence") ?: return emptyList()
        require(values.length() <= 24) { "Too many evidence entries" }
        return (0 until values.length()).map { index ->
            val value = values.getJSONObject(index)
            CoachEvidence(value.getString("criterionId"), value.getString("turnId"), value.getString("quote"),
                value.getString("reason"), value.getBoolean("met"))
        }
    }

    private fun validateEvidence(session: CoachSession, evidence: CoachEvidence) {
        val criterion = unit(session).criteria.find { it.id == evidence.criterionId }
            ?: error("Evidence refers to an unknown criterion")
        val turn = session.turns.find { it.id == evidence.turnId && it.role == "user" }
            ?: error("Evidence must reference a saved user answer")
        require(evidence.quote.isNotBlank() && turn.text.contains(evidence.quote)) { "Evidence quote does not match the original answer" }
        require(evidence.reason.isNotBlank()) { "Evidence needs a specific explanation" }
        require(!criterion.requiresRealAction || !evidence.met || turn.context == "reported_real") {
            "A simulation cannot satisfy a real-action criterion"
        }
    }

    private fun unit(session: CoachSession): CoachUnit = session.course.units.single { it.id == session.unitId }
}
