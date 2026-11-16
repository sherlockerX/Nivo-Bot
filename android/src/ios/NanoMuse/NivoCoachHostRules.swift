import Foundation

/// 只接受聊天宿主已落盘事件，模型命令不能调用这些归档和失效入口。
enum NivoCoachHostRules {
    /// 专题和聊天互为唯一绑定，移动分组或改名不会改变身份。
    static func bind(topicID: String, chatSessionID: String, state: inout NivoCoachState) throws {
        guard !chatSessionID.isEmpty, let index = state.topics.firstIndex(where: { $0.id == topicID }) else {
            throw NivoLifeError.notFound("coach_topic")
        }
        let topic = state.topics[index]
        guard topic.status == "active", topic.chatSessionID.isEmpty || topic.chatSessionID == chatSessionID,
              !state.topics.contains(where: { $0.id != topicID && $0.chatSessionID == chatSessionID }) else {
            throw NivoLifeError.invalidField("coach_binding")
        }
        state.topics[index].chatSessionID = chatSessionID
        for sessionIndex in state.sessions.indices where state.sessions[sessionIndex].topicID == topicID {
            state.sessions[sessionIndex].chatSessionID = chatSessionID
        }
    }

    /// 聊天删除后保留历史回看，撤销全部来源证据并停止当前课次。
    static func invalidateConversation(chatSessionID: String, reason: String, state: inout NivoCoachState) throws {
        guard !reason.isEmpty else { throw NivoLifeError.invalidField("archive_reason") }
        guard let index = state.topics.firstIndex(where: { !$0.chatSessionID.isEmpty && $0.chatSessionID == chatSessionID }) else { return }
        let topicID = state.topics[index].id
        if state.topics[index].status == "archived" { return }
        state.topics[index].status = "archived"
        state.topics[index].archiveReason = reason
        state.topics[index].activeSessionID = nil
        for sessionIndex in state.sessions.indices where state.sessions[sessionIndex].topicID == topicID {
            var session = state.sessions[sessionIndex]
            if session.status != "complete" { session.status = "paused" }
            session.pendingTurnID = nil
            session.assessment = nil
            session.turns = session.turns.map { var turn = $0; turn.sourceInvalidated = true; return turn }
            session.evidence = session.evidence.map { var evidence = $0; evidence.disputed = true; return evidence }
            session.lessonSummary?.sourceInvalidated = true
            try state.replaceSession(session)
        }
        invalidateReports(state: &state)
    }

    /// 同一次删除可能影响多个原话或验证题，批量失效只产生一次磁盘提交。
    static func invalidateMessages(chatSessionID: String, messageIDs: Set<String>, state: inout NivoCoachState) throws {
        guard let topic = state.topics.first(where: { !$0.chatSessionID.isEmpty && $0.chatSessionID == chatSessionID }) else { return }
        for index in state.sessions.indices where state.sessions[index].topicID == topic.id {
            let original = state.sessions[index]
            let originals = original.turns.filter { messageIDs.contains($0.originMessageID) }
            if originals.isEmpty { continue }
            let assessments = Set(originals.filter { $0.role == "coach" }.map(\.assessmentID).filter { !$0.isEmpty })
            let invalid = Set(original.turns.filter { messageIDs.contains($0.originMessageID) || assessments.contains($0.assessmentID) }.map(\.id))
            try state.replaceSession(invalidated(original, turns: invalid, assessments: assessments))
        }
        invalidateReports(state: &state)
    }

    private static func invalidated(_ original: NivoCoachSession, turns: Set<String>, assessments: Set<String>) -> NivoCoachSession {
        var session = original
        for index in session.turns.indices where turns.contains(session.turns[index].id) { session.turns[index].sourceInvalidated = true }
        for index in session.evidence.indices where turns.contains(session.evidence[index].turnID) { session.evidence[index].disputed = true }
        if let pending = session.pendingTurnID, turns.contains(pending) { session.pendingTurnID = nil }
        if let assessment = session.assessment, assessments.contains(assessment.id) { session.assessment = nil }
        if let summary = session.lessonSummary,
           (summary.sources + summary.corrections + summary.unresolvedHypotheses).contains(where: { turns.contains($0.turnID) }) {
            session.lessonSummary?.sourceInvalidated = true
        }
        return session
    }

    private static func invalidateReports(state: inout NivoCoachState) {
        let invalid = Set(state.sessions.flatMap { $0.turns.filter(\.sourceInvalidated).map(\.id) })
        for actionIndex in state.actions.indices {
            for reportIndex in state.actions[actionIndex].reports.indices where invalid.contains(state.actions[actionIndex].reports[reportIndex].id) {
                state.actions[actionIndex].reports[reportIndex].sourceInvalidated = true
            }
        }
    }

    /// 重复持久化回调不重复归档；后续普通追问不会重开已结束的课。
    static func registerUser(_ user: NivoSavedUserTurn, expectedSessionID: String?, state: inout NivoCoachState, now: Int64) throws {
        let topic = try boundTopic(user.chatSessionID, state: state)
        if let duplicate = state.sessions.first(where: { $0.topicID == topic.id && $0.turns.contains(where: { $0.role == "user" && $0.originMessageID == user.id }) }) {
            guard duplicate.turns.contains(where: { $0.role == "user" && $0.originMessageID == user.id && $0.text == user.text && !$0.sourceInvalidated }) else {
                throw NivoLifeError.operationConflict
            }
            return
        }
        let session = try latestLesson(topic: topic, expectedID: expectedSessionID, state: &state, now: now)
        try NivoCoachPolicy.requireCurrentCourse(state, session: session)
        let updated = try NivoCoachTeaching.message(session, text: user.text, user: user, purpose: "question", now: now)
        try state.replaceSession(updated)
    }

    /// 最终正文给本轮真实出现的题目补绑来源，未展示给用户的隐藏验证题立即作废。
    static func recordReply(chatSessionID: String, messageID: String, text: String, expectedSessionID: String?,
                            state: inout NivoCoachState, now: Int64, sourceDigest: String? = nil) throws {
        guard !messageID.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NivoLifeError.invalidField("coach_reply") }
        let topic = try boundTopic(chatSessionID, state: state)
        let originals = state.sessions.filter { $0.topicID == topic.id }.flatMap(\.turns)
            .filter { $0.role == "coach" && $0.originMessageID == messageID }
        if !originals.isEmpty {
            guard originals.contains(where: { $0.text == text }), originals.allSatisfy({ !$0.sourceInvalidated }) else { throw NivoLifeError.operationConflict }
            return
        }
        guard var session = state.sessions.last(where: { $0.topicID == topic.id }),
              expectedSessionID == nil || session.id == expectedSessionID else { throw NivoLifeError.invalidTransition("stale_lesson_reply") }
        try NivoCoachPolicy.requireCurrentCourse(state, session: session)
        let lastUser = session.turns.lastIndex(where: { $0.role == "user" }) ?? -1
        for index in session.turns.indices where index > lastUser {
            let turn = session.turns[index]
            guard turn.role == "coach", turn.originMessageID.isEmpty else { continue }
            if !turn.sourceInvalidated, !turn.text.isEmpty, text.contains(turn.text) {
                session.turns[index].originMessageID = messageID
                session.turns[index].originChatSessionID = chatSessionID
                session.turns[index].sourceDigest = sourceDigest
            }
            else if turn.purpose == "assessment" { session.turns[index].sourceInvalidated = true }
        }
        // 始终追加宿主正文作为同来源最后一条，验证时不会把工具内容误当作可见正文。
        session.turns.append(NivoCoachTurn(id: UUID().uuidString, role: "coach", text: text, stage: session.mode,
            support: session.nextSupport, originMessageID: messageID, createdAt: now, purpose: "teaching",
            originChatSessionID: chatSessionID, sourceDigest: sourceDigest))
        session = invalidateHiddenAssessments(session)
        let pending = session.turns.first { $0.id == session.pendingTurnID }
        if !["attempt", "report", "action_report"].contains(pending?.purpose ?? "") { session.pendingTurnID = nil }
        session.stage = session.status == "complete" ? "complete" : session.mode
        if let summary = session.lessonSummary {
            let updatedSources = summary.sources.map { source in
                var updated = source
                updated.messageID = session.turns.first(where: { $0.id == source.turnID })?.originMessageID ?? source.messageID
                return updated
            }
            session.lessonSummary?.sources = updatedSources
        }
        try state.replaceSession(session)
    }

    private static func invalidateHiddenAssessments(_ session: NivoCoachSession) -> NivoCoachSession {
        let ids = Set(session.turns.filter { $0.purpose == "assessment" && $0.sourceInvalidated }.map(\.assessmentID).filter { !$0.isEmpty })
        let turns = Set(session.turns.filter { ids.contains($0.assessmentID) }.map(\.id))
        return invalidated(session, turns: turns, assessments: ids)
    }

    private static func boundTopic(_ chatID: String, state: NivoCoachState) throws -> NivoCoachTopic {
        guard !chatID.isEmpty, let topic = state.topics.first(where: { $0.chatSessionID == chatID }), topic.status == "active" else {
            throw NivoLifeError.invalidField("coach_scope")
        }
        return topic
    }

    private static func latestLesson(topic: NivoCoachTopic, expectedID: String?, state: inout NivoCoachState, now: Int64) throws -> NivoCoachSession {
        if let latest = state.sessions.last(where: { $0.topicID == topic.id }) {
            guard expectedID == nil || expectedID == latest.id else { throw NivoLifeError.invalidTransition("stale_lesson_message") }
            return latest
        }
        guard expectedID == nil else { throw NivoLifeError.invalidTransition("stale_lesson_message") }
        return try NivoCoachReducer.startLesson(topicID: topic.id, state: &state, now: now)
    }
}
