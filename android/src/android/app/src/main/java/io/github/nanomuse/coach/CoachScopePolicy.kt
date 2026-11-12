package io.github.nanomuse.coach

/** 可信专题范围同时约束读取和写入，模型无法用另一个对象ID跨案例操作。 */
object CoachScopePolicy {
    /** 返回宿主范围内的状态；主要聊天和本地界面保留全局管理能力。 */
    fun visibleState(state: CoachState, scope: CoachConversationScope?): CoachState {
        if (scope == null || scope.isMain) return state
        val topic = state.topics.singleOrNull { it.chatSessionId == scope.chatSessionId && scope.chatSessionId.isNotBlank() }
            ?: error("Conversation is not bound to a topic")
        val sessions = state.sessions.filter { it.topicId == topic.id }
        return state.copy(topics = listOf(topic), sessions = sessions,
            tracks = state.tracks.filter { it.course.id == topic.courseId }, drafts = emptyList(),
            actions = state.actions.filter { action -> sessions.any { it.id == action.sessionId } },
            operations = emptyMap(), selectedCourseId = topic.courseId)
    }

    /** 校验必须早于幂等回放，避免另一个专题借用旧操作ID取得成功结果。 */
    fun validate(state: CoachState, command: CoachCommand, scope: CoachConversationScope?) {
        if (scope == null || scope.isMain) return
        val visible = visibleState(state, scope)
        require(visible.topics.single().status == "active") { "This topic is archived and read-only" }
        val target = command.targetId
        val allowed = when (command.action) {
            "start_lesson" -> visible.topics.any { it.id == target }
            "answer", "lesson_message", "coach_reply", "end_lesson", "save_input", "pause_session", "resume_session",
            "request_hint", "dispute", "action_plan" -> visible.sessions.any { it.id == target }
            "action_update", "action_defer", "action_resume", "action_report" -> visible.actions.any { it.id == target }
            else -> false
        }
        require(allowed) { "This conversation can only change its bound topic and lesson records" }
    }
}
