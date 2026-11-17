import Foundation

/// 待办、专注和碎片共用的明确错误，调用方按错误码提供恢复入口。
enum NivoLifeError: Error, Equatable, Sendable {
    case invalidField(String)
    case notFound(String)
    case staleRevision(expected: Int64, actual: Int64)
    case operationConflict
    case accountChanged
    case activeSessionExists
    case invalidTransition(String)
    case unsupportedVersion(Int)
    case corruptStore
}

/// 与安卓一致的待办状态，完成与开始专注互不替代。
enum NivoTodoStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case inProgress = "in_progress"
    case done
}

/// 任务完整快照，日期使用公历epoch day，时间戳使用毫秒。
struct NivoTodoTask: Codable, Equatable, Identifiable, Sendable {
    enum CodingKeys: String, CodingKey {
        case ownerKey, id, title, notes, status, scheduledDay, dueDay, groupName, tags
        case isImportant, isUrgent, revision, createdAt, updatedAt, deletedAt, completedDay, completedAt, completionTags
    }
    var ownerKey = ""
    var id = ""
    var title = ""
    var notes = ""
    var status: NivoTodoStatus = .todo
    var scheduledDay: Int64?
    var dueDay: Int64?
    var groupName = ""
    var tags: [String] = []
    var isImportant = false
    var isUrgent = false
    var revision: Int64 = 0
    var createdAt: Int64 = 0
    var updatedAt: Int64 = 0
    var deletedAt: Int64?
    var completedDay: Int64?
    var completedAt: Int64?
    var completionTags: [String] = []
}

/// 可复用的分组与标签目录，不因任务被删除而自动消失。
struct NivoTodoCategory: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case group, tag }
    var kind: Kind
    var name: String
    var createdAt: Int64
    var updatedAt: Int64
    var id: String { kind.rawValue + ":" + name }
}

/// 碎片编辑器中的任务选择，自动保存草稿时不执行状态变更。
struct NivoTodoSelection: Codable, Equatable, Sendable {
    var taskId: String
    var expectedRevision: Int64
    var requestedStatus: NivoTodoStatus?
    var completedDay: Int64?
    /// 只有用户操作日期控件才允许更正已完成日期，旧草稿缺失时保留重复完成语义。
    var isCompletionDayExplicit: Bool?
}

/// 专注模式，休息计时不进入专注统计。
enum NivoFocusMode: String, Codable, CaseIterable, Sendable {
    case pomodoro, stopwatch
    case rest = "break"
}

/// 活动计时包含运行和暂停两种状态。
enum NivoFocusStatus: String, Codable, Sendable { case running, paused, finished }

/// 注入时钟让真实设备计量和可重复测试使用同一套规则。
struct NivoFocusClockSample: Equatable, Sendable {
    var wallMs: Int64
    var elapsedMs: Int64
    var bootID: String
}

/// 专注记录保存开始时的任务语义，后续任务改名不改写历史。
struct NivoFocusSession: Codable, Equatable, Identifiable, Sendable {
    var ownerKey: String
    var id: String
    var title: String
    var taskId: String?
    var groupName: String
    var tags: [String]
    var mode: NivoFocusMode
    var targetMs: Int64
    var status: NivoFocusStatus = .running
    var elapsedMs: Int64 = 0
    var startedAt: Int64
    var endedAt: Int64?
    var updatedAt: Int64
    var runningWall: Int64
    var runningElapsed: Int64
    var bootID: String
    var revision: Int64 = 1
    var deletedAt: Int64?
    var isActive: Bool { deletedAt == nil && status != .finished }
}

/// 已计量的连续区间，暂停时间不生成区间，跨午夜时按区间求交。
struct NivoFocusSpan: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sessionId: String
    var startedAt: Int64
    var durationMs: Int64
}

/// 完成和统计只读取持久化数据，保存的操作回执用于精确重试。
struct NivoLifeOperation: Codable, Equatable, Sendable {
    var request: Data
    var result: Data
}

/// 同一账号生命周期中的能力凭证，切换账号后旧页面和旧AI回合不可再写。
struct NivoLifeScope: Equatable, Hashable, Sendable {
    var ownerKey: String
    var generation: UInt64
}

/// 首版持久化容器，字段增加时必须提供明确迁移。
struct NivoLifeState: Codable, Equatable, Sendable {
    var version = 1
    var ownerKey: String
    var tasks: [NivoTodoTask] = []
    var categories: [NivoTodoCategory] = []
    var focusSessions: [NivoFocusSession] = []
    var focusSpans: [NivoFocusSpan] = []
    var operations: [String: NivoLifeOperation] = [:]
    /// 可选字段兼容早期本地快照，同名分类即使在同一毫秒重建也有不同代次。
    var categoryGeneration: Int64?
    /// 整体快照序号阻止异步刷新晚到时覆盖较新的界面状态。
    var storeRevision: Int64?
    /// 碎片与任务状态在同一文件内提交，旧版本快照缺少此字段时由迁移器补入。
    var mosaic: NivoMosaicState?
    /// 独立任务备份保留事件和外部历史，但外部回执不能执行本机命令。
    var todoHistory: NivoTodoBackupHistory?
}
