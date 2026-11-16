import Foundation

/// Android Coach v2 的能力类型。不同类型由课程标准决定证据维度，而不是共用旧版分数。
enum NivoCoachKind: String, Codable, CaseIterable, Sendable {
    case judgment, perspectives, english, expression, leadership, execution, custom

    /// Android 的 kotlinx.serialization 会输出大写枚举；iOS 读入时同时接受两种大小写，
    /// 这样课程提案、备份和跨端调试数据不会因为枚举格式不同而被拒绝。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self).lowercased()
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                    debugDescription: "Unknown Coach kind: \(raw)")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 一个可验证的课程标准；现实行动必须来自用户报告的真实回合。
struct NivoCoachCriterion: Codable, Equatable, Sendable {
    var id: String
    var description: String
    var requiresRealAction = false
    var dimension = ""

    private enum CodingKeys: String, CodingKey {
        case id, description, requiresRealAction, dimension
    }
}

/// 课程单元保留练习方法、来源和标准审查状态。
struct NivoCoachUnit: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var focus: String
    var method: String
    var criteria: [NivoCoachCriterion]
    var source = ""
    var needsCriteriaReview = false

    private enum CodingKeys: String, CodingKey {
        case id, title, focus, method, criteria, source, needsCriteriaReview
    }
}

/// 训练启动时保存的完整课程快照，后续改课不会改写历史课次。
struct NivoCoachCourse: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var place: String
    var kind: NivoCoachKind
    var units: [NivoCoachUnit]
    var version: String
    var source = ""
    var importProtocol = ""
    var builtInSourceID = ""
    var needsCriteriaReview = false

    private enum CodingKeys: String, CodingKey {
        case id, title, place, kind, units, version, source, importProtocol
        case builtInSourceID = "builtInSourceId"
        case needsCriteriaReview
    }
}

/// 每项能力独立记录当前单元、暂停状态和已展示单元。
struct NivoCoachTrack: Codable, Equatable, Identifiable, Sendable {
    var course: NivoCoachCourse
    var currentUnitID: String
    var paused = false
    var demonstrated: Set<String> = []
    var lastPracticedAt: Int64 = 0
    var legacyNote = ""
    var id: String { course.id }

    private enum CodingKeys: String, CodingKey {
        case course
        case currentUnitID = "currentUnitId"
        case paused, demonstrated
        case lastPracticedAt, legacyNote
    }
}

/// 教练与用户回合的原文、提示程度、情境来源和验证用途必须一起保存。
struct NivoCoachTurn: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var role: String
    var text: String
    var stage: String
    var support = "none"
    var context = "simulation"
    var originMessageID = ""
    var createdAt: Int64
    var purpose = "legacy"
    var assessmentID = ""
    var dimension = ""
    var reviewKind = "immediate"
    var reviewOfSessionID = ""
    var sourceInvalidated = false
    var originChatSessionID: String?
    var sourceDigest: String?

    private enum CodingKeys: String, CodingKey {
        case id, role, text, stage, support, context
        case originMessageID = "originMessageId"
        case createdAt, purpose
        case assessmentID = "assessmentId"
        case dimension, reviewKind
        case reviewOfSessionID = "reviewOfSessionId"
        case sourceInvalidated
        case originChatSessionID = "originChatSessionId"
        case sourceDigest
    }
}

/// 证据只允许引用已经保存的用户原话。
struct NivoCoachEvidence: Codable, Equatable, Sendable {
    var criterionID: String
    var turnID: String
    var quote: String
    var reason: String
    var met: Bool
    var disputed = false

    private enum CodingKeys: String, CodingKey {
        case criterionID = "criterionId"
        case turnID = "turnId"
        case quote, reason, met, disputed
    }
}

struct NivoCoachAssessment: Codable, Equatable, Sendable {
    var id: String
    var promptTurnID: String
    var dimension: String
    var reviewOfSessionID = ""
    var isDelayed = false

    private enum CodingKeys: String, CodingKey {
        case id
        case promptTurnID = "promptTurnId"
        case dimension
        case reviewOfSessionID = "reviewOfSessionId"
        case isDelayed
    }
}

/// 一次独立课次，包含课程快照、教学回合和证据。
struct NivoCoachSession: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var course: NivoCoachCourse
    var unitID: String
    var stage = "setup"
    var status = "active"
    var draft = ""
    var turns: [NivoCoachTurn] = []
    var evidence: [NivoCoachEvidence] = []
    var pendingTurnID: String?
    var nextSupport = "none"
    var summary = ""
    var revision: Int64 = 0
    var chatSessionID = ""
    var requiresCourseReview = false
    var topicID = ""
    var teachingProtocol = "legacy"
    var mode = "explain"
    var assessment: NivoCoachAssessment?
    var startedAt: Int64 = 0
    var endedAt: Int64 = 0
    var lessonSummary: NivoCoachLessonSummary?

    private enum CodingKeys: String, CodingKey {
        case id, course
        case unitID = "unitId"
        case stage, status, draft, turns, evidence, pendingTurnID = "pendingTurnId"
        case nextSupport, summary, revision
        case chatSessionID = "chatSessionId"
        case requiresCourseReview
        case topicID = "topicId"
        case teachingProtocol, mode, assessment, startedAt, endedAt, lessonSummary
    }
}

struct NivoCoachSummarySource: Codable, Equatable, Sendable {
    var turnID: String
    var messageID: String
    var quote: String

    private enum CodingKeys: String, CodingKey {
        case turnID = "turnId"
        case messageID = "messageId"
        case quote
    }
}

struct NivoCoachLessonSummary: Codable, Equatable, Sendable {
    var text: String
    var courseVersion: String
    var sourceRevision: Int64
    var sources: [NivoCoachSummarySource] = []
    var corrections: [NivoCoachSummarySource] = []
    var unresolvedHypotheses: [NivoCoachSummarySource] = []
    var sourceInvalidated = false

    private enum CodingKeys: String, CodingKey {
        case text, courseVersion, sourceRevision, sources, corrections, unresolvedHypotheses, sourceInvalidated
    }
}

struct NivoCoachTopic: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var courseID: String
    var unitID: String
    var title: String
    var caseText: String
    var chatSessionID = ""
    var activeSessionID: String?
    var status = "active"
    var createdAt: Int64 = 0
    var archiveReason = ""

    private enum CodingKeys: String, CodingKey {
        case id
        case courseID = "courseId"
        case unitID = "unitId"
        case title, caseText
        case chatSessionID = "chatSessionId"
        case activeSessionID = "activeSessionId"
        case status, createdAt, archiveReason
    }
}

struct NivoCoachDraft: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var text: String
    var course: NivoCoachCourse?
    var revision: Int64 = 0
    var status = "exploring"
    var proposedFromMessageID = ""
    var sourceStatus = "unverified"
    var activatedCourseID: String?
    var proposedAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case id, text, course, revision, status
        case proposedFromMessageID = "proposedFromMessageId"
        case sourceStatus
        case activatedCourseID = "activatedCourseId"
        case proposedAt
    }
}

struct NivoCoachAction: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sessionID: String
    var plan: String
    var status = "planned"
    var planHistory: [String] = []
    var reports: [NivoCoachTurn] = []

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case plan, status, planHistory, reports
    }
}

/// Android的schema 3原子快照，账户目录下只有这一份权威状态。
struct NivoCoachState: Codable, Equatable, Sendable {
    var schemaVersion = 3
    var revision: Int64 = 0
    var tracks: [NivoCoachTrack] = []
    var sessions: [NivoCoachSession] = []
    var drafts: [NivoCoachDraft] = []
    var actions: [NivoCoachAction] = []
    var operations: [String: String] = [:]
    var selectedCourseID = "expression"
    var topics: [NivoCoachTopic] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, tracks, sessions, drafts, actions, operations
        case selectedCourseID = "selectedCourseId"
        case topics
    }
}

struct NivoCoachTopicProgress: Equatable, Sendable {
    var hasUnderstanding: Bool
    var hasApplication: Bool
    var hasDelayedReview: Bool
    var isDemonstrated: Bool
}

extension NivoCoachCriterion {
    /// 自定义课程省略可选标志时采用保守默认，不要求模型生成内部兼容字段。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        description = try values.decode(String.self, forKey: .description)
        requiresRealAction = try values.decodeIfPresent(Bool.self, forKey: .requiresRealAction) ?? false
        dimension = try values.decodeIfPresent(String.self, forKey: .dimension) ?? ""
    }
}

extension NivoCoachUnit {
    /// 读取显式课程字段，不依赖标点猜测理论、情景或现实任务。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        focus = try values.decode(String.self, forKey: .focus)
        method = try values.decode(String.self, forKey: .method)
        criteria = try values.decode([NivoCoachCriterion].self, forKey: .criteria)
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? ""
        needsCriteriaReview = try values.decodeIfPresent(Bool.self, forKey: .needsCriteriaReview) ?? false
    }
}

extension NivoCoachCourse {
    /// 提案协议保留安卓字段名，内部导入字段可省略。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        place = try values.decode(String.self, forKey: .place)
        kind = try values.decode(NivoCoachKind.self, forKey: .kind)
        units = try values.decode([NivoCoachUnit].self, forKey: .units)
        version = try values.decode(String.self, forKey: .version)
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? ""
        importProtocol = try values.decodeIfPresent(String.self, forKey: .importProtocol) ?? ""
        builtInSourceID = try values.decodeIfPresent(String.self, forKey: .builtInSourceID) ?? ""
        needsCriteriaReview = try values.decodeIfPresent(Bool.self, forKey: .needsCriteriaReview) ?? false
    }
}

extension NivoCoachEvidence {
    /// 模型只提交评价，不需要知道宿主维护的异议标志。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        criterionID = try values.decode(String.self, forKey: .criterionID)
        turnID = try values.decode(String.self, forKey: .turnID)
        quote = try values.decode(String.self, forKey: .quote)
        reason = try values.decode(String.self, forKey: .reason)
        met = try values.decode(Bool.self, forKey: .met)
        disputed = try values.decodeIfPresent(Bool.self, forKey: .disputed) ?? false
    }
}
