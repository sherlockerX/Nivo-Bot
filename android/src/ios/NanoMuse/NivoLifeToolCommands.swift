import Foundation

/// 是否回放由事务直接返回，不根据当前对象的版本号猜测。
struct NivoLifeTransactionResult<Value> {
    var value: Value
    var isReplay: Bool
}

extension NivoLifeTransactionResult: Sendable where Value: Sendable {}

/// 幂等请求同时绑定真实用户消息和聊天范围，不能借用其他回合的操作ID。
struct NivoLifeToolIdentity: Codable, Equatable, Sendable {
    var chatID: String
    var messageID: String
    var sourceDigest: String
}

/// 编辑只记录用户提交的字段，重试不会重新采集当前任务并改变请求签名。
struct NivoTodoToolPatch: Codable, Equatable, Sendable {
    var title: String?
    var notes: String?
    var groupName: String?
    var tags: [String]?
    var isImportant: Bool?
    var isUrgent: Bool?
    var scheduledDay: Int64?
    var dueDay: Int64?
    var clearsScheduledDay = false
    var clearsDueDay = false

    /// 字段缺席保留旧值，显式null只清空可选日期。
    func apply(to task: inout NivoTodoTask) {
        if let title { task.title = title }
        if let notes { task.notes = notes }
        if let groupName { task.groupName = groupName }
        if let tags { task.tags = tags }
        if let isImportant { task.isImportant = isImportant }
        if let isUrgent { task.isUrgent = isUrgent }
        if clearsScheduledDay || scheduledDay != nil { task.scheduledDay = scheduledDay }
        if clearsDueDay || dueDay != nil { task.dueDay = dueDay }
    }
}

/// 原始待办命令是持久化签名，所有当前对象读取都在回放检查之后执行。
struct NivoTodoToolCommand: Codable, Equatable, Sendable {
    var action: String
    var identity: NivoLifeToolIdentity
    var targetID = ""
    var expectedRevision: Int64?
    var patch = NivoTodoToolPatch()
    var completedDay: Int64?
    var userQuote: String?
    var categoryKind: NivoTodoCategory.Kind?
    var categoryName: String?
    var expectedCreatedAt: Int64?
}

/// 类别操作与任务操作共享事务，但结果保留各自类型。
enum NivoTodoToolResult: Codable, Sendable {
    case task(NivoTodoTask)
    case category(NivoTodoCategory)
}

/// 专注工具只传用户请求，不包含当前时钟和新对象随机ID。
struct NivoFocusToolCommand: Codable, Equatable, Sendable {
    var action: String
    var identity: NivoLifeToolIdentity
    var targetID = ""
    var expectedRevision: Int64?
    var title = "Focus"
    var taskID: String?
    var mode: NivoFocusMode = .pomodoro
    var minutes = 25
}
