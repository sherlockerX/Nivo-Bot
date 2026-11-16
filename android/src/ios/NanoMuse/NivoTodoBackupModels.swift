import Foundation

/// 与安卓JSON备份共用的状态事件，记录当时的完成标签。
struct NivoTodoHistoryEvent: Codable, Equatable, Sendable {
    var operationId: String
    var taskId: String
    var previousStatus: String?
    var status: String
    var completedDay: Int64?
    var tags: [String]
    var createdAt: Int64
    /// 新事件保存当时的任务快照，导出时不拿当前字段冒充过去的状态。
    var snapshot: NivoTodoTask?
    var identity: String { "\(operationId.utf8.count):" + operationId + taskId }
}

/// 外部回执仅作为备份档案保留，不进入本机AI命令的授权或幂等表。
struct NivoTodoPortableOperation: Codable, Equatable, Sendable {
    var operationId: String
    var request: String
    var result: String
    var createdAt: Int64
}

/// 增量历史为可选字段，旧快照无需伪造过去的事件。
struct NivoTodoBackupHistory: Codable, Equatable, Sendable {
    static let maximumCount = 50_000
    var events: [NivoTodoHistoryEvent] = []
    var operations: [NivoTodoPortableOperation] = []
    var categoryOperations: [NivoTodoPortableOperation] = []
    var iosReceipts: [String: NivoLifeOperation] = [:]

    /// 只记录状态或删除状态真正变化的任务，重试不重复添加。
    static func recordingChanges(from previous: [NivoTodoTask], in state: inout NivoLifeState, operationID: String) {
        let originals = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let changed = state.tasks.filter {
            originals[$0.id]?.status != $0.status || originals[$0.id]?.deletedAt != $0.deletedAt
        }
        guard !changed.isEmpty else { return }
        var history = state.todoHistory ?? NivoTodoBackupHistory()
        for task in changed {
            history.events.append(NivoTodoHistoryEvent(operationId: operationID, taskId: task.id,
                previousStatus: originals[task.id]?.status.rawValue,
                status: task.deletedAt == nil ? task.status.rawValue : "deleted", completedDay: task.completedDay,
                tags: task.completionTags, createdAt: task.updatedAt, snapshot: task))
        }
        state.todoHistory = history
    }
}

/// 跨设备关联只携带文字快照，缺少碎片原件时不创建空日记。
struct NivoTodoBackupLink: Codable, Equatable, Sendable {
    var entryId: String
    var taskId: String
    var title: String
    var statusSnapshot: NivoTodoStatus
    var linkedAt: Int64
}

/// 兼容安卓v1和v2的任务备份，新增iOS回执字段由旧客户端忽略。
struct NivoTodoBackupDocument: Codable, Sendable {
    var format = "nanomuse-todo"
    var version = 2
    var tasks: [NivoTodoTask]
    var categories: [NivoTodoCategory]
    var links: [NivoTodoBackupLink]
    var events: [NivoTodoHistoryEvent]
    var operations: [NivoTodoPortableOperation]
    var categoryOperations: [NivoTodoPortableOperation]
    var iosReceipts: [String: NivoLifeOperation]

    init(tasks: [NivoTodoTask], categories: [NivoTodoCategory], links: [NivoTodoBackupLink], history: NivoTodoBackupHistory) {
        self.tasks = tasks
        self.categories = categories
        self.links = links
        events = history.events
        operations = history.operations
        categoryOperations = history.categoryOperations
        iosReceipts = history.iosReceipts
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format)
        version = try values.decode(Int.self, forKey: .version)
        tasks = try values.decode([NivoTodoTask].self, forKey: .tasks)
        categories = try values.decodeIfPresent([NivoTodoCategory].self, forKey: .categories) ?? []
        links = try values.decodeIfPresent([NivoTodoBackupLink].self, forKey: .links) ?? []
        events = try values.decodeIfPresent([NivoTodoHistoryEvent].self, forKey: .events) ?? []
        operations = try values.decodeIfPresent([NivoTodoPortableOperation].self, forKey: .operations) ?? []
        categoryOperations = try values.decodeIfPresent([NivoTodoPortableOperation].self, forKey: .categoryOperations) ?? []
        iosReceipts = try values.decodeIfPresent([String: NivoLifeOperation].self, forKey: .iosReceipts) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case format, version, tasks, categories, links, events, operations, categoryOperations, iosReceipts
    }
}

/// 导入结果明确说明保留本地与缺失关联，重复导入返回同一结果。
struct NivoTodoImportResult: Codable, Equatable, Sendable {
    var imported: Int
    var keptLocal: Int
    var missingEntries: Int
}
