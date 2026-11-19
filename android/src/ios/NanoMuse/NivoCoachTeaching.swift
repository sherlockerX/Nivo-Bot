import Foundation

/// 与安卓topic-v3共用的教学规则：自由讨论、独立验证与现实报告各自留证。
enum NivoCoachTeaching {
    static let modes = ["explain", "concept", "compare", "question", "practice", "review"]
    static let dimensions = ["understanding", "application"]
    static let MIN_REVIEW_DELAY: Int64 = 24 * 60 * 60 * 1_000

    /// 宿主先保存原话；模型只可把当时已有验证题的回合标记为attempt。
    static func message(_ original: NivoCoachSession, text: String, user: NivoSavedUserTurn,
                        purpose: String, now: Int64) throws -> NivoCoachSession {
        _ = try NivoCoachPolicy.quote(text, user: user)
        guard ["active", "paused", "waiting_real", "complete"].contains(original.status), ["question", "continue", "attempt"].contains(purpose),
              original.status == "active" || purpose != "attempt" else { throw NivoLifeError.invalidTransition("coach_message") }
        if let index = original.turns.firstIndex(where: { $0.role == "user" && $0.originMessageID == user.id }) {
            return try markAttempt(original, index: index, text: text, purpose: purpose)
        }
        let pending = original.turns.first { $0.id == original.pendingTurnID }
        guard purpose != "attempt" || pending == nil else { throw NivoLifeError.invalidTransition("pending_feedback") }
        let assessment = original.assessment.flatMap { value in
            original.status == "active" && hasTraceableAssessment(original, id: value.id) &&
                assessmentWasVisible(original, id: value.id, before: user.createdAt) ? value : nil
        }
        guard purpose != "attempt" || assessment != nil else { throw NivoLifeError.invalidField("assessment") }
        var session = original
        let turn = NivoCoachTurn(id: UUID().uuidString, role: "user", text: text, stage: session.mode,
            support: session.nextSupport, originMessageID: user.id, createdAt: user.createdAt, purpose: purpose,
            assessmentID: assessment?.id ?? "", dimension: assessment?.dimension ?? "",
            reviewKind: assessment?.isDelayed == true ? "delayed" : "immediate",
            reviewOfSessionID: assessment?.reviewOfSessionID ?? "", originChatSessionID: user.chatSessionID, sourceDigest: user.sourceDigest)
        session.turns.append(turn)
        if !["attempt", "report", "action_report"].contains(pending?.purpose ?? "") { session.pendingTurnID = turn.id }
        session.draft = ""
        session.assessment = nil
        return session
    }

    private static func markAttempt(_ original: NivoCoachSession, index: Int, text: String, purpose: String) throws -> NivoCoachSession {
        let turn = original.turns[index]
        guard !turn.sourceInvalidated, turn.text.contains(text) else { throw NivoLifeError.operationConflict }
        if purpose != "attempt" || turn.purpose == "attempt" { return original }
        guard !turn.assessmentID.isEmpty, hasTraceableAssessment(original, id: turn.assessmentID) else {
            throw NivoLifeError.invalidField("independent_evidence")
        }
        var session = original
        session.turns[index].purpose = "attempt"
        return session
    }

    /// 模型回复与其证据、验证题一次形成候选快照，任何校验失败都不留下半条回复。
    static func reply(_ original: NivoCoachSession, state: NivoCoachState, text: String,
                      payload: NivoCoachPayload, now: Int64) throws -> NivoCoachSession {
        let mode = payload.mode ?? original.mode
        guard ["active", "waiting_real"].contains(original.status), modes.contains(mode),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NivoLifeError.invalidField("coach_reply") }
        guard original.pendingTurnID == nil || payload.requestTurnId == original.pendingTurnID else {
            throw NivoLifeError.invalidTransition("stale_coach_reply")
        }
        let evidence = payload.evidence ?? []
        guard evidence.count <= 24 else { throw NivoLifeError.invalidField("coach_evidence") }
        for item in evidence { try validate(item, session: original) }
        var turn = NivoCoachTurn(id: UUID().uuidString, role: "coach", text: text, stage: mode,
            support: original.nextSupport, createdAt: now, purpose: "teaching")
        var assessment: NivoCoachAssessment?
        if let request = payload.assessment {
            assessment = try createAssessment(original, state: state, turn: turn, request: request, mode: mode, now: now)
            turn.purpose = "assessment"
            turn.assessmentID = assessment?.id ?? ""
            turn.dimension = request.dimension
            turn.reviewKind = assessment?.isDelayed == true ? "delayed" : "immediate"
            turn.reviewOfSessionID = request.reviewOfSessionId ?? ""
        }
        var session = original
        session.turns.append(turn)
        session.evidence.append(contentsOf: evidence)
        session.mode = mode
        session.stage = mode
        session.pendingTurnID = nil
        session.assessment = assessment
        if assessment != nil { session.nextSupport = "none" }
        session.status = "active"
        return session
    }

    private static func createAssessment(_ session: NivoCoachSession, state: NivoCoachState, turn: NivoCoachTurn,
                                         request: NivoCoachAssessmentRequest, mode: String, now: Int64) throws -> NivoCoachAssessment {
        guard ["practice", "review"].contains(mode), dimensions.contains(request.dimension),
              !session.turns.contains(where: { $0.role == "coach" && $0.purpose == "assessment" && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == turn.text.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
            throw NivoLifeError.invalidField("assessment")
        }
        let reviewID = request.reviewOfSessionId ?? ""
        if !reviewID.isEmpty {
            guard let previous = state.sessions.first(where: { $0.id == reviewID }),
                  validReviewSource(previous, for: session, at: now, dimension: request.dimension) else {
                throw NivoLifeError.invalidField("delayed_review")
            }
        }
        return NivoCoachAssessment(id: UUID().uuidString, promptTurnID: turn.id, dimension: request.dimension,
            reviewOfSessionID: reviewID, isDelayed: !reviewID.isEmpty)
    }

    /// 已写入聊天的最终正文必须确实包含验证题，工具调用中的隐藏题目不算题目来源。
    static func hasTraceableAssessment(_ session: NivoCoachSession, id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return session.turns.contains { turn in
            guard turn.role == "coach", turn.purpose == "assessment", turn.assessmentID == id,
                  !turn.sourceInvalidated, !turn.text.isEmpty else { return false }
            guard !turn.originMessageID.isEmpty,
                  let visible = session.turns.last(where: { $0.role == "coach" && $0.originMessageID == turn.originMessageID }) else { return false }
            return !visible.sourceInvalidated && visible.text.contains(turn.text)
        }
    }

    /// 真实用户消息必须晚于可见题目，重试旧输入不能获得后来才出现的独立验证资格。
    private static func assessmentWasVisible(_ session: NivoCoachSession, id: String, before timestamp: Int64) -> Bool {
        guard let prompt = session.turns.first(where: { $0.role == "coach" && $0.purpose == "assessment" && $0.assessmentID == id }),
              let visible = session.turns.last(where: { $0.role == "coach" && $0.originMessageID == prompt.originMessageID }) else { return false }
        return visible.createdAt <= timestamp
    }

    /// 每次汇总重新检验证据，删除题目或原话后，旧达成状态会一起撤销。
    static func validate(_ evidence: NivoCoachEvidence, session: NivoCoachSession) throws {
        guard let criterion = session.course.units.first(where: { $0.id == session.unitID })?.criteria.first(where: { $0.id == evidence.criterionID }),
              let turn = session.turns.first(where: { $0.id == evidence.turnID && $0.role == "user" }),
              !turn.sourceInvalidated, !evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              turn.text.contains(evidence.quote), !evidence.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NivoLifeError.invalidField("coach_evidence")
        }
        if !evidence.met { return }
        guard turn.support == "none" else { throw NivoLifeError.invalidField("hinted_evidence") }
        if criterion.requiresRealAction {
            guard turn.context == "reported_real", turn.stage == "real_report" else { throw NivoLifeError.invalidField("real_action_evidence") }
            return
        }
        guard turn.purpose == "attempt", turn.dimension == NivoCoachPolicy.dimension(criterion),
              hasTraceableAssessment(session, id: turn.assessmentID),
              session.turns.contains(where: { $0.role == "coach" && $0.purpose == "assessment" && !$0.sourceInvalidated && $0.assessmentID == turn.assessmentID && $0.createdAt <= turn.createdAt }) else {
            throw NivoLifeError.invalidField("independent_evidence")
        }
    }

    /// 延迟复核需要可回查的即时作答。
    static func hasImmediateEvidence(_ session: NivoCoachSession, dimension: String) -> Bool {
        session.evidence.contains { evidence in
            evidence.met && !evidence.disputed && (try? validate(evidence, session: session)) != nil &&
                session.turns.contains { $0.id == evidence.turnID && $0.dimension == dimension && $0.reviewKind == "immediate" }
        }
    }

    private static func validReviewSource(_ previous: NivoCoachSession, for session: NivoCoachSession,
                                          at now: Int64, dimension: String) -> Bool {
        previous.id != session.id && previous.topicID == session.topicID && previous.unitID == session.unitID &&
            previous.status == "complete" &&
            previous.endedAt > 0 && now >= previous.endedAt && now - previous.endedAt >= MIN_REVIEW_DELAY &&
            !previous.requiresCourseReview && previous.course.version == session.course.version &&
            hasImmediateEvidence(previous, dimension: dimension)
    }

    /// 从一个一致快照计算理解、应用及延迟复核，避免并行读取拼成不同版本。
    static func progress(_ state: NivoCoachState, topicID: String, unitID: String? = nil) -> NivoCoachTopicProgress {
        let empty = NivoCoachTopicProgress(hasUnderstanding: false, hasApplication: false, hasDelayedReview: false, isDemonstrated: false)
        guard let topic = state.topics.first(where: { $0.id == topicID }), topic.status == "active",
              let course = state.tracks.first(where: { $0.id == topic.courseID })?.course,
              let unit = course.units.first(where: { $0.id == unitID ?? topic.unitID }) else { return empty }
        let sessions = state.sessions.filter {
            $0.topicID == topicID && $0.unitID == unit.id && $0.teachingProtocol == "topic-v3" &&
                !$0.requiresCourseReview && $0.course.version == course.version
        }
        let met = Set(sessions.flatMap { session in session.evidence.filter {
            $0.met && !$0.disputed && (try? validate($0, session: session)) != nil
        }.map(\.criterionID) })
        let understanding = unit.criteria.filter { NivoCoachPolicy.dimension($0) == "understanding" }
        let application = unit.criteria.filter { NivoCoachPolicy.dimension($0) == "application" }
        let hasUnderstanding = !understanding.isEmpty && understanding.allSatisfy { met.contains($0.id) }
        let hasApplication = !application.isEmpty && application.allSatisfy { met.contains($0.id) }
        let delayed = sessions.contains { hasDelayedEvidence($0, state: state) }
        return NivoCoachTopicProgress(hasUnderstanding: hasUnderstanding, hasApplication: hasApplication,
            hasDelayedReview: delayed, isDemonstrated: hasUnderstanding && hasApplication && delayed && unit.criteria.allSatisfy { met.contains($0.id) })
    }

    private static func hasDelayedEvidence(_ session: NivoCoachSession, state: NivoCoachState) -> Bool {
        session.evidence.contains { evidence in
            guard evidence.met, !evidence.disputed, (try? validate(evidence, session: session)) != nil,
                  let turn = session.turns.first(where: { $0.id == evidence.turnID }) else { return false }
            return isValidDelayedReview(turn, session: session, state: state)
        }
    }

    /// 通过原课次、原维度和宿主时间再次检验延迟复核。
    static func isValidDelayedReview(_ turn: NivoCoachTurn, session: NivoCoachSession, state: NivoCoachState) -> Bool {
        guard turn.reviewKind == "delayed",
              let previous = state.sessions.first(where: { $0.id == turn.reviewOfSessionID }) else { return false }
        return validReviewSource(previous, for: session, at: turn.createdAt, dimension: turn.dimension)
    }
}
