package io.github.nanomuse.coach

import java.util.UUID

/** 现实行动独立于课程暂停，改小计划和暂存都不抹去历史报告。 */
internal object CoachActionCommands {
    fun apply(state: CoachState, command: CoachCommand, user: CoachUserInput?): Pair<CoachState, String> {
        if (command.action == "action_plan") return create(state, command)
        val action = state.actions.singleOrNull { it.id == command.targetId } ?: error("Action task not found")
        if (command.action == "action_report") return report(state, action, command.text, user)
        val updated = when (command.action) {
            "action_update" -> {
                require(command.text.isNotBlank()) { "A smaller concrete plan is required" }
                action.copy(plan = command.text, planHistory = action.planHistory + action.plan, status = "planned")
            }
            "action_defer" -> action.copy(status = "deferred")
            "action_resume" -> action.copy(status = "planned")
            else -> error("Unknown action task command")
        }
        return state.copy(actions = state.actions.map { if (it.id == action.id) updated else it }) to action.id
    }

    private fun create(state: CoachState, command: CoachCommand): Pair<CoachState, String> {
        state.session(command.targetId)
        require(command.text.isNotBlank()) { "Describe a small real-life action" }
        val existing = state.actions.find { it.sessionId == command.targetId && it.status in setOf("planned", "deferred") }
        require(existing == null) { "This session already has a pending action; update it instead" }
        val action = CoachAction(UUID.randomUUID().toString(), command.targetId, command.text)
        return state.copy(actions = state.actions + action) to action.id
    }

    private fun report(state: CoachState, action: CoachAction, text: String, user: CoachUserInput?): Pair<CoachState, String> {
        requireUserQuote(text, user)
        val session = state.session(action.sessionId)
        require(session.pendingTurnId == null) { "Wait for the current training reply before reporting" }
        if (action.reports.any { it.originMessageId == user!!.messageId }) return state to action.id
        val report = CoachTurn(UUID.randomUUID().toString(), "user", text, "real_report",
            context = "reported_real", originMessageId = user!!.messageId)
        val updated = action.copy(status = "reported", reports = action.reports + report)
        val updatedSession = session.copy(turns = session.turns + report, pendingTurnId = report.id,
            status = "active", stage = "real_report", revision = session.revision + 1)
        return state.copy(actions = state.actions.map { if (it.id == action.id) updated else it },
            sessions = state.sessions.map { if (it.id == session.id) updatedSession else it }) to action.id
    }
}
