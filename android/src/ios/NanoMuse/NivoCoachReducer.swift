import Foundation

/// 候选状态上的单次变更结果，只有仓库成功落盘后才对调用方可见。
struct NivoCoachApplied {
    var id: String
    var data: String

    /// 在类型仍然明确时编码，不把Any误传给泛型Encodable。
    init<Value: Encodable>(id: String, value: Value) throws {
        self.id = id
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        data = String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// 全部模型命令在值类型候选状态上执行，失败不触碰磁盘或观察状态。
enum NivoCoachReducer {
    /// 每个分支只返回确定类型的对象和精确ID。
    static func apply(_ command: NivoCoachCommand, context: NivoCoachCommandContext,
                      state: inout NivoCoachState, now: Int64) throws -> NivoCoachApplied {
        let payload = try NivoCoachPayload.decode(command.payload)
        if NivoCoachPolicy.draftActions.contains(command.action) {
            return try NivoCoachDraftRules.apply(command, payload: payload, context: context, state: &state, now: now)
        }
        if NivoCoachPolicy.topicActions.contains(command.action) {
            return try topic(command, payload: payload, state: &state, now: now)
        }
        if NivoCoachPolicy.courseActions.contains(command.action) {
            return try course(command, payload: payload, state: &state, now: now)
        }
        if NivoCoachPolicy.actionActions.contains(command.action) {
            return try action(command, context: context, state: &state, now: now)
        }
        return try lesson(command, payload: payload, context: context, state: &state, now: now)
    }

    private static func topic(_ command: NivoCoachCommand, payload: NivoCoachPayload,
                              state: inout NivoCoachState, now: Int64) throws -> NivoCoachApplied {
        switch command.action {
        case "start_topic":
            let created = try startTopic(courseID: command.targetID, payload: payload, text: command.text, state: &state, now: now)
            return try NivoCoachApplied(id: created.id, value: created)
        case "start_lesson":
            let session = try startLesson(topicID: command.targetID, state: &state, now: now)
            return try NivoCoachApplied(id: session.id, value: session)
        case "end_lesson":
            let session = try endLesson(command, payload: payload, state: &state, now: now)
            return try NivoCoachApplied(id: session.id, value: session)
        default: throw NivoLifeError.invalidField("coach_action")
        }
    }

    private static func startTopic(courseID: String, payload: NivoCoachPayload, text: String,
                                   state: inout NivoCoachState, now: Int64) throws -> NivoCoachTopic {
        let track = try state.track(courseID)
        try requireStartable(track)
        let unitID = payload.unitId ?? track.currentUnitID
        guard let unit = track.course.units.first(where: { $0.id == unitID }) else { throw NivoLifeError.notFound("coach_unit") }
        let title = (payload.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let caseText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenCase = caseText.isEmpty ? unit.focus : caseText
        let chosenTitle = title.isEmpty ? unit.title : title
        guard chosenTitle.utf16.count <= 160, chosenCase.utf16.count <= 16_000 else { throw NivoLifeError.invalidField("coach_topic") }
        if let saved = state.topics.last(where: { $0.courseID == courseID && $0.unitID == unitID && $0.caseText == chosenCase && $0.status == "active" }) { return saved }
        let topic = NivoCoachTopic(id: UUID().uuidString, courseID: courseID, unitID: unitID,
            title: chosenTitle, caseText: chosenCase, createdAt: now)
        state.topics.append(topic)
        state.selectedCourseID = courseID
        return topic
    }

    /// 继续同一课次包括waiting_real，不会因为等待现实反馈而另开平行记录。
    static func startLesson(topicID: String, state: inout NivoCoachState, now: Int64) throws -> NivoCoachSession {
        let topic = try state.topic(topicID)
        let track = try state.track(topic.courseID)
        try requireStartable(track)
        guard topic.status == "active", track.course.units.contains(where: { $0.id == topic.unitID }) else {
            throw NivoLifeError.invalidTransition("coach_topic")
        }
        if let active = state.sessions.first(where: { $0.id == topic.activeSessionID }),
           !active.requiresCourseReview, active.course.version == track.course.version,
           ["active", "paused", "waiting_real"].contains(active.status) { return active }
        var session = NivoCoachSession(id: UUID().uuidString, course: track.course, unitID: topic.unitID,
            topicID: topic.id, teachingProtocol: "topic-v3")
        session.chatSessionID = topic.chatSessionID
        session.startedAt = now
        state.sessions.append(session)
        if let index = state.topics.firstIndex(where: { $0.id == topicID }) { state.topics[index].activeSessionID = session.id }
        if let index = state.tracks.firstIndex(where: { $0.id == track.id }) { state.tracks[index].lastPracticedAt = now }
        return session
    }

    private static func endLesson(_ command: NivoCoachCommand, payload: NivoCoachPayload,
                                  state: inout NivoCoachState, now: Int64) throws -> NivoCoachSession {
        var session = try state.session(command.targetID)
        try NivoCoachPolicy.requireCurrentCourse(state, session: session)
        guard session.teachingProtocol == "topic-v3" else { throw NivoLifeError.invalidField("teaching_protocol") }
        if session.status == "complete" { return session }
        let pending = session.turns.first { $0.id == session.pendingTurnID }
        guard !["attempt", "report", "action_report"].contains(pending?.purpose ?? "") else {
            throw NivoLifeError.invalidTransition("pending_feedback")
        }
        let summary = command.text.isEmpty ? session.summary : command.text
        let sources = session.turns.filter { !$0.sourceInvalidated }.suffix(24).map {
            NivoCoachSummarySource(turnID: $0.id, messageID: $0.originMessageID, quote: String($0.text.prefix(600)))
        }
        session.lessonSummary = NivoCoachLessonSummary(text: summary, courseVersion: session.course.version,
            sourceRevision: session.revision, sources: sources,
            corrections: try summarySources(payload.corrections ?? [], session: session),
            unresolvedHypotheses: try summarySources(payload.unresolvedHypotheses ?? [], session: session))
        session.status = "complete"
        session.stage = "complete"
        session.summary = summary
        session.assessment = nil
        session.pendingTurnID = nil
        session.endedAt = now
        try state.replaceSession(session)
        if let index = state.topics.firstIndex(where: { $0.id == session.topicID && $0.activeSessionID == session.id }) {
            state.topics[index].activeSessionID = nil
        }
        return try state.session(session.id)
    }

    private static func summarySources(_ sources: [NivoCoachSourceRequest], session: NivoCoachSession) throws -> [NivoCoachSummarySource] {
        guard sources.count <= 12 else { throw NivoLifeError.invalidField("summary_sources") }
        return try sources.map { source in
            guard let turn = session.turns.first(where: { $0.id == source.turnId && !$0.sourceInvalidated }),
                  !source.quote.isEmpty, turn.text.contains(source.quote) else { throw NivoLifeError.invalidField("summary_quote") }
            return NivoCoachSummarySource(turnID: turn.id, messageID: turn.originMessageID, quote: source.quote)
        }
    }

    private static func course(_ command: NivoCoachCommand, payload: NivoCoachPayload,
                               state: inout NivoCoachState, now: Int64) throws -> NivoCoachApplied {
        if command.action == "start" {
            let topic = try startTopic(courseID: command.targetID, payload: payload, text: command.text, state: &state, now: now)
            let session = try startLesson(topicID: topic.id, state: &state, now: now)
            return try NivoCoachApplied(id: session.id, value: session)
        }
        var track = try state.track(command.targetID)
        switch command.action {
        case "pause_course":
            track.paused = true
            for index in state.sessions.indices where state.sessions[index].course.id == track.id && state.sessions[index].status == "active" {
                state.sessions[index].status = "paused"
                state.sessions[index].revision = try increment(state.sessions[index].revision)
            }
        case "resume_course": track.paused = false
        case "advance":
            // 页面展示后可能暂停课程或更新复核要求，命令入口仍须核对当前状态。
            try requireStartable(track)
            if let displayedUnit = payload.unitId, displayedUnit != track.currentUnitID {
                throw NivoLifeError.invalidTransition("stale_unit")
            }
            guard track.demonstrated.contains(track.currentUnitID), let index = track.course.units.firstIndex(where: { $0.id == track.currentUnitID }),
                  index + 1 < track.course.units.count else { throw NivoLifeError.invalidTransition("unit_evidence") }
            track.currentUnitID = track.course.units[index + 1].id
        default: throw NivoLifeError.invalidField("coach_action")
        }
        if let index = state.tracks.firstIndex(where: { $0.id == track.id }) { state.tracks[index] = track }
        return try NivoCoachApplied(id: track.id, value: track)
    }

    private static func lesson(_ command: NivoCoachCommand, payload: NivoCoachPayload, context: NivoCoachCommandContext,
                               state: inout NivoCoachState, now: Int64) throws -> NivoCoachApplied {
        var session = try state.session(command.targetID)
        try NivoCoachPolicy.requireCurrentCourse(state, session: session)
        switch command.action {
        case "answer", "lesson_message":
            let user = try NivoCoachPolicy.quote(command.text, user: context.user)
            session = try NivoCoachTeaching.message(session, text: command.text, user: user,
                purpose: command.action == "answer" ? "attempt" : payload.purpose ?? "question", now: now)
        case "coach_reply": session = try NivoCoachTeaching.reply(session, state: state, text: command.text, payload: payload, now: now)
        case "dispute": session = try disputed(session, command: command, context: context, now: now)
        default: session = try controlled(session, command: command, state: state)
        }
        try state.replaceSession(session)
        return try NivoCoachApplied(id: session.id, value: state.session(session.id))
    }

    private static func controlled(_ original: NivoCoachSession, command: NivoCoachCommand, state: NivoCoachState) throws -> NivoCoachSession {
        var session = original
        switch command.action {
        case "save_input":
            guard ["active", "paused"].contains(session.status), command.text.utf16.count <= 12_000 else { throw NivoLifeError.invalidField("draft") }
            session.draft = command.text
        case "pause_session":
            guard ["active", "waiting_real", "paused"].contains(session.status) else { throw NivoLifeError.invalidTransition("pause_session") }
            session.status = "paused"
            if !command.text.isEmpty { session.draft = String(command.text.prefix(12_000)) }
        case "resume_session":
            guard session.status == "paused", try !state.track(session.course.id).paused else { throw NivoLifeError.invalidTransition("resume_session") }
            session.status = "active"
        case "request_hint":
            guard session.status == "active" else { throw NivoLifeError.invalidTransition("coach_session") }
            session.nextSupport = "hinted"
            if let index = session.turns.firstIndex(where: { $0.id == session.pendingTurnID }) { session.turns[index].support = "hinted" }
        default: throw NivoLifeError.invalidField("coach_action")
        }
        return session
    }

    private static func disputed(_ original: NivoCoachSession, command: NivoCoachCommand,
                                 context: NivoCoachCommandContext, now: Int64) throws -> NivoCoachSession {
        let user = try NivoCoachPolicy.quote(command.text, user: context.user)
        var session = original
        session.turns.append(NivoCoachTurn(id: UUID().uuidString, role: "user", text: command.text, stage: "dispute",
            support: "hinted", originMessageID: user.id, createdAt: now, purpose: "dispute",
            originChatSessionID: user.chatSessionID, sourceDigest: user.sourceDigest))
        session.evidence = session.evidence.map { var item = $0; item.disputed = true; return item }
        session.pendingTurnID = nil
        session.assessment = nil
        session.nextSupport = "hinted"
        session.status = "active"
        session.stage = "question"
        return session
    }

    private static func action(_ command: NivoCoachCommand, context: NivoCoachCommandContext,
                               state: inout NivoCoachState, now: Int64) throws -> NivoCoachApplied {
        if command.action == "action_plan" {
            let session = try state.session(command.targetID)
            try NivoCoachPolicy.requireCurrentCourse(state, session: session)
            guard !command.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !state.actions.contains(where: { $0.sessionID == session.id && ["planned", "deferred"].contains($0.status) }) else {
                throw NivoLifeError.invalidField("action_plan")
            }
            let action = NivoCoachAction(id: UUID().uuidString, sessionID: session.id, plan: command.text)
            state.actions.append(action)
            return try NivoCoachApplied(id: action.id, value: action)
        }
        guard let index = state.actions.firstIndex(where: { $0.id == command.targetID }) else { throw NivoLifeError.notFound("coach_action") }
        var action = state.actions[index]
        try NivoCoachPolicy.requireCurrentCourse(state, session: state.session(action.sessionID))
        switch command.action {
        case "action_report": action = try report(action, text: command.text, user: context.user, state: &state, now: now)
        case "action_update":
            guard !command.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NivoLifeError.invalidField("action_plan") }
            action.planHistory.append(action.plan)
            action.plan = command.text
            action.status = "planned"
        case "action_defer": action.status = "deferred"
        case "action_resume": action.status = "planned"
        default: throw NivoLifeError.invalidField("coach_action")
        }
        state.actions[index] = action
        return try NivoCoachApplied(id: action.id, value: action)
    }

    private static func report(_ original: NivoCoachAction, text: String, user: NivoSavedUserTurn?,
                               state: inout NivoCoachState, now: Int64) throws -> NivoCoachAction {
        let user = try NivoCoachPolicy.quote(text, user: user)
        var action = original
        if let existing = action.reports.first(where: { $0.originMessageID == user.id }) {
            guard existing.text == text, !existing.sourceInvalidated else { throw NivoLifeError.operationConflict }
            return action
        }
        var session = try state.session(action.sessionID)
        let pending = session.turns.first { $0.id == session.pendingTurnID }
        guard pending == nil || (pending?.originMessageID == user.id && pending?.purpose == "question") else {
            throw NivoLifeError.invalidTransition("pending_feedback")
        }
        let turn = NivoCoachTurn(id: UUID().uuidString, role: "user", text: text, stage: "real_report",
            context: "reported_real", originMessageID: user.id, createdAt: now, purpose: "report", dimension: "application",
            originChatSessionID: user.chatSessionID, sourceDigest: user.sourceDigest)
        action.reports.append(turn)
        action.status = "reported"
        session.turns.append(turn)
        session.pendingTurnID = turn.id
        session.status = "active"
        session.stage = "real_report"
        try state.replaceSession(session)
        return action
    }

    private static func requireStartable(_ track: NivoCoachTrack) throws {
        guard !track.paused else { throw NivoLifeError.invalidTransition("course_paused") }
        try NivoCoachPolicy.requireReviewed(track.course)
    }

    /// 防止损坏快照中的最大版本在写入时溢出崩溃。
    static func increment(_ revision: Int64) throws -> Int64 {
        guard revision >= 0, revision < Int64.max else { throw NivoLifeError.invalidField("revision") }
        return revision + 1
    }
}

extension NivoCoachState {
    /// 对失效ID报错，不悄悄切到最近课程。
    func track(_ id: String) throws -> NivoCoachTrack {
        guard let value = tracks.first(where: { $0.id == id }) else { throw NivoLifeError.notFound("coach_course") }
        return value
    }

    /// 对失效ID报错，不创建替代课次。
    func session(_ id: String) throws -> NivoCoachSession {
        guard let value = sessions.first(where: { $0.id == id }) else { throw NivoLifeError.notFound("coach_session") }
        return value
    }

    /// 专题必须属于当前账户快照。
    func topic(_ id: String) throws -> NivoCoachTopic {
        guard let value = topics.first(where: { $0.id == id }) else { throw NivoLifeError.notFound("coach_topic") }
        return value
    }

    /// 实际变更才增加课次版本，精确重复消息不产生假变化。
    mutating func replaceSession(_ value: NivoCoachSession) throws {
        guard let index = sessions.firstIndex(where: { $0.id == value.id }) else { throw NivoLifeError.notFound("coach_session") }
        if sessions[index] == value { return }
        var updated = value
        updated.revision = try NivoCoachReducer.increment(sessions[index].revision)
        sessions[index] = updated
    }
}
