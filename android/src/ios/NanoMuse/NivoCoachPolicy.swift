import Foundation

/// 主聊天可以管理课程，专题只可读取和修改宿主绑定的案例。
enum NivoCoachPolicy {
    static let courseActions = ["start", "pause_course", "resume_course", "advance"]
    static let topicActions = ["start_topic", "start_lesson", "end_lesson"]
    static let draftActions = ["new_draft", "revise_draft", "propose", "activate"]
    static let sessionActions = ["save_input", "answer", "lesson_message", "coach_reply", "pause_session", "resume_session", "request_hint", "dispute"]
    static let actionActions = ["action_plan", "action_update", "action_defer", "action_resume", "action_report"]
    static var actions: [String] { courseActions + topicActions + draftActions + sessionActions + actionActions }

    /// 读取也执行范围裁剪，专题模型不会看到其他案例、建课草稿或回执。
    static func visible(_ state: NivoCoachState, chatID: String, isMain: Bool) throws -> NivoCoachState {
        if isMain { return state }
        guard !chatID.isEmpty, let topic = state.topics.first(where: { $0.chatSessionID == chatID }),
              state.topics.filter({ $0.chatSessionID == chatID }).count == 1 else { throw NivoLifeError.invalidField("coach_scope") }
        var result = state
        result.topics = [topic]
        result.tracks = state.tracks.filter { $0.id == topic.courseID }
        result.sessions = state.sessions.filter { $0.topicID == topic.id }
        let lessonIDs = Set(result.sessions.map(\.id))
        result.actions = state.actions.filter { lessonIDs.contains($0.sessionID) }
        result.drafts = []
        result.operations = [:]
        result.selectedCourseID = topic.courseID
        return result
    }

    /// 范围和当前用户来源先于回执读取，避免借用其他专题的旧operationId。
    static func authorize(_ command: NivoCoachCommand, context: NivoCoachCommandContext, state: NivoCoachState) throws {
        guard actions.contains(command.action), command.text.utf16.count <= 40_000,
              command.payload.utf16.count <= 200_000 else { throw NivoLifeError.invalidField("coach_command") }
        if !context.isHost {
            guard let user = context.user, !user.id.isEmpty, user.ownerKey == context.ownerKey,
                  user.chatSessionID == context.chatSessionID, !context.chatSessionID.isEmpty else { throw NivoLifeError.accountChanged }
        }
        if context.isMain { return }
        let visible = try visible(state, chatID: context.chatSessionID, isMain: false)
        guard visible.topics.first?.status == "active", permits(command, in: visible) else {
            throw NivoLifeError.invalidField("coach_scope")
        }
    }

    private static func permits(_ command: NivoCoachCommand, in state: NivoCoachState) -> Bool {
        if command.action == "start_lesson" { return state.topics.contains { $0.id == command.targetID } }
        if sessionActions.contains(command.action) || ["end_lesson", "action_plan"].contains(command.action) {
            return state.sessions.contains { $0.id == command.targetID }
        }
        if actionActions.contains(command.action) { return state.actions.contains { $0.id == command.targetID } }
        return false
    }

    /// 旧版课程只能回看，不能继续使用过期标准产生新证据。
    static func requireCurrentCourse(_ state: NivoCoachState, session: NivoCoachSession) throws {
        guard let track = state.tracks.first(where: { $0.id == session.course.id }),
              !session.requiresCourseReview, session.course.version == track.course.version else {
            throw NivoLifeError.invalidField("course_review")
        }
        try requireReviewed(session.course)
        if !session.topicID.isEmpty {
            guard state.topics.first(where: { $0.id == session.topicID })?.status == "active" else {
                throw NivoLifeError.invalidTransition("archived_topic")
            }
        }
    }

    /// 显式标记待审阅的课程不得被训练或激活绕过。
    static func requireReviewed(_ course: NivoCoachCourse) throws {
        guard !course.needsCriteriaReview, !course.units.contains(where: \.needsCriteriaReview) else {
            throw NivoLifeError.invalidField("course_review")
        }
    }

    /// 模型只能引用本轮已保存的连续原文，不能自行声明用户已经确认或实践。
    static func quote(_ text: String, user: NivoSavedUserTurn?) throws -> NivoSavedUserTurn {
        guard let user, !user.id.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              user.text.contains(text) else { throw NivoLifeError.invalidField("exact_user_quote") }
        return user
    }

    /// 否定、继续修改和疑问不构成课程激活确认。
    static func confirms(_ text: String) -> Bool {
        let denied = "不要|取消|不创建|不加入|不确认|先别|暂不|不同意|不开始|不可以|还没|修改|改一下|再改|是否|能否|[?？]|don't|do not|not yet|cancel|revise|change|not confirm|no[, .!]"
        if text.range(of: denied, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return text.range(of: "确认|就按|按这|加入|创建|可以开始|同意|\\bconfirm\\b|\\bcreate\\b|\\bactivate\\b|go ahead",
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 课程维度允许读取旧内置ID，自定义标准必须明确声明含义。
    static func dimension(_ criterion: NivoCoachCriterion) -> String {
        if !criterion.dimension.isEmpty { return criterion.dimension }
        switch criterion.id {
        case "understanding": return "understanding"
        case "application", "practice": return "application"
        default: return ""
        }
    }
}

/// JSON负载只描述教学或课程内容，身份和时间全部由宿主提供。
struct NivoCoachPayload: Decodable {
    var unitId: String?
    var title: String?
    var course: NivoCoachCourse?
    var sourceStatus: String?
    var draftRevision: Int64?
    var revision: Int64?
    var purpose: String?
    var mode: String?
    var requestTurnId: String?
    var assessment: NivoCoachAssessmentRequest?
    var evidence: [NivoCoachEvidence]?
    var corrections: [NivoCoachSourceRequest]?
    var unresolvedHypotheses: [NivoCoachSourceRequest]?

    private enum CodingKeys: String, CodingKey {
        case unitId, title, course, sourceStatus, draftRevision, revision, purpose, mode, requestTurnId
        case assessment, evidence, corrections, unresolvedHypotheses
    }

    /// 可选字段的null与未提供一致；安卓兼容的assessment:false只表示普通教学。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        unitId = try values.decodeIfPresent(String.self, forKey: .unitId)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        course = try values.decodeIfPresent(NivoCoachCourse.self, forKey: .course)
        sourceStatus = try values.decodeIfPresent(String.self, forKey: .sourceStatus)
        draftRevision = try values.decodeIfPresent(Int64.self, forKey: .draftRevision)
        revision = try values.decodeIfPresent(Int64.self, forKey: .revision)
        purpose = try values.decodeIfPresent(String.self, forKey: .purpose)
        mode = try values.decodeIfPresent(String.self, forKey: .mode)
        requestTurnId = try values.decodeIfPresent(String.self, forKey: .requestTurnId)
        if (try? values.decode(Bool.self, forKey: .assessment)) == false { assessment = nil }
        else { assessment = try values.decodeIfPresent(NivoCoachAssessmentRequest.self, forKey: .assessment) }
        evidence = try values.decodeIfPresent([NivoCoachEvidence].self, forKey: .evidence)
        corrections = try values.decodeIfPresent([NivoCoachSourceRequest].self, forKey: .corrections)
        unresolvedHypotheses = try values.decodeIfPresent([NivoCoachSourceRequest].self, forKey: .unresolvedHypotheses)
    }

    /// 空字符串代表没有可选参数；损坏JSON不能静默改成空参数。
    static func decode(_ text: String) throws -> NivoCoachPayload {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try JSONDecoder().decode(Self.self, from: Data((source.isEmpty ? "{}" : source).utf8))
    }
}

/// 验证题不能携带伪造的宿主时间或用户来源。
struct NivoCoachAssessmentRequest: Decodable {
    var dimension: String
    var reviewOfSessionId: String?
}

/// 摘要引用的来源消息ID由仓库回查原回合，不接收模型自己填写。
struct NivoCoachSourceRequest: Decodable {
    var turnId: String
    var quote: String
}
