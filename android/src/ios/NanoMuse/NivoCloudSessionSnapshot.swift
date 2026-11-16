import Foundation

/// 强制拉取在删除任何本机行之前完成解码与归属检查，坏云端记录不会变成空聊天。
struct NivoCloudSessionSnapshot {
    struct Message {
        var value: RawMessage
        let partsJSON: String
        let usageJSON: String?
        let updatedAt: Date
    }

    let sessionID: String
    let messages: [Message]
    let markers: [CompactMarker]
    let recordCount: Int

    /// 必须有且只有一条父会话，所有子项属于同一会话；不支持的字段类型直接拒绝。
    init(sessionID: String, records: [PortableRecord]) throws {
        guard !sessionID.isEmpty, records.count <= 100_000,
              Set(records.map(\.id)).count == records.count else { throw CocoaError(.fileReadCorruptFile) }
        var parentCount = 0
        var messages: [Message] = []
        var markers: [CompactMarker] = []
        for record in records {
            guard (record.minimumCompatibleVersion ?? 1) <= 1,
                  try Self.string(record, "sessionId") == sessionID else { throw CocoaError(.fileReadCorruptFile) }
            switch record.id.type {
            case "SessionV2":
                guard record.id.id == sessionID else { throw CocoaError(.fileReadCorruptFile) }
                parentCount += 1
            case "MessageV2": messages.append(try Self.message(record, sessionID: sessionID))
            case "CompactMarkerV2": markers.append(try Self.marker(record, sessionID: sessionID))
            default: throw CocoaError(.fileReadCorruptFile)
            }
        }
        guard parentCount == 1 else { throw CocoaError(.fileReadCorruptFile) }
        self.sessionID = sessionID
        self.messages = messages.sorted {
            if $0.value.createdAt != $1.value.createdAt { return $0.value.createdAt < $1.value.createdAt }
            return $0.value.id < $1.value.id
        }
        self.markers = markers
        recordCount = records.count
    }

    private static func message(_ record: PortableRecord, sessionID: String) throws -> Message {
        let identifier = try string(record, "messageId")
        guard identifier == record.id.id, !identifier.isEmpty,
              let role = try MessageRole(rawValue: string(record, "role")) else { throw CocoaError(.fileReadCorruptFile) }
        let partsJSON = try string(record, "partsJson")
        let parts = try JSONDecoder().decode([ContentPart].self, from: Data(partsJSON.utf8))
        let usageJSON = try optionalString(record, "tokenUsageJson")
        let usage = try usageJSON.map { try JSONDecoder().decode(StoredTokenUsage.self, from: Data($0.utf8)) }
        var message = RawMessage(id: identifier, sessionId: sessionID, role: role, parts: parts,
            createdAt: try date(record, "createdAt"), tokenUsage: usage,
            reasoningContent: try optionalString(record, "reasoningContent"),
            streamInterruptCount: try integer(record, "streamInterruptCount") ?? 0,
            sortOrder: try integer(record, "sortOrder") ?? 0)
        guard message.streamInterruptCount >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        message.modelId = try optionalString(record, "modelId")
        message.modelDisplayName = try optionalString(record, "modelDisplayName")
        message.providerType = try optionalString(record, "providerType")
        message.providerInstanceId = try optionalString(record, "providerInstanceId")
        let updatedAt = record.fields["updatedAt"] == nil ? record.updatedAt : try date(record, "updatedAt")
        guard updatedAt.timeIntervalSince1970.isFinite else { throw CocoaError(.fileReadCorruptFile) }
        return Message(value: message, partsJSON: partsJSON, usageJSON: usageJSON, updatedAt: updatedAt)
    }

    private static func marker(_ record: PortableRecord, sessionID: String) throws -> CompactMarker {
        let identifier = try string(record, "markerId")
        let count = try integer(record, "compactedCount") ?? 0
        let version = try integer(record, "markerVersion") ?? 1
        guard identifier == record.id.id, !identifier.isEmpty, count >= 0, (1...2).contains(version) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return CompactMarker(id: identifier, sessionId: sessionID, summary: try string(record, "summary"),
            firstKeptSortOrder: try integer(record, "firstKeptSortOrder") ?? 0, compactedCount: count,
            createdAt: try date(record, "createdAt"), uiBoundarySortOrder: try integer(record, "uiBoundarySortOrder"),
            boundaryMessageId: try optionalString(record, "boundaryMessageId"),
            firstKeptMessageId: try optionalString(record, "firstKeptMessageId"),
            lastCompactedMessageId: try optionalString(record, "lastCompactedMessageId"), version: version)
    }

    private static func string(_ record: PortableRecord, _ key: String) throws -> String {
        guard let value = try optionalString(record, key) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    /// 大正文的CloudKit附件也必须完整读取，不允许使用空数组替代读取失败。
    private static func optionalString(_ record: PortableRecord, _ key: String) throws -> String? {
        switch record.fields[key] {
        case .string(let value), .json(let value): return value
        case .none, .null:
            guard let asset = record.assets[key + "Asset"] else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: asset.fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let bytes = attributes[.size] as? NSNumber, bytes.int64Value <= 32 * 1_024 * 1_024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try String(contentsOf: asset.fileURL, encoding: .utf8)
        default: throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func integer(_ record: PortableRecord, _ key: String) throws -> Int? {
        switch record.fields[key] {
        case .int(let value): return value
        case .none, .null: return nil
        default: throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func date(_ record: PortableRecord, _ key: String) throws -> Date {
        guard case .date(let value) = record.fields[key], value.timeIntervalSince1970.isFinite else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
}
