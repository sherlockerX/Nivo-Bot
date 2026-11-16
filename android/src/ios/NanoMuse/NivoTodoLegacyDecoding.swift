import Foundation

extension NivoTodoTask {
    /// 安卓v1允许省略非核心属性；类型错误仍然抛出，不能静默接受损坏文件。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ownerKey = try values.decodeIfPresent(String.self, forKey: .ownerKey) ?? ""
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        status = try values.decode(NivoTodoStatus.self, forKey: .status)
        scheduledDay = try values.decodeIfPresent(Int64.self, forKey: .scheduledDay)
        dueDay = try values.decodeIfPresent(Int64.self, forKey: .dueDay)
        groupName = try values.decodeIfPresent(String.self, forKey: .groupName) ?? ""
        tags = try values.decode([String].self, forKey: .tags)
        isImportant = try values.decodeIfPresent(Bool.self, forKey: .isImportant) ?? false
        isUrgent = try values.decodeIfPresent(Bool.self, forKey: .isUrgent) ?? false
        revision = try values.decode(Int64.self, forKey: .revision)
        createdAt = try values.decode(Int64.self, forKey: .createdAt)
        updatedAt = try values.decode(Int64.self, forKey: .updatedAt)
        deletedAt = try values.decodeIfPresent(Int64.self, forKey: .deletedAt)
        completedDay = try values.decodeIfPresent(Int64.self, forKey: .completedDay)
        completedAt = try values.decodeIfPresent(Int64.self, forKey: .completedAt)
        completionTags = try values.decodeIfPresent([String].self, forKey: .completionTags) ?? []
    }
}
