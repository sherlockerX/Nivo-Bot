import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif

/// 入站记录的归属、父记录或内容不可靠时保留同步批次，等待修复后重放。
enum NivoCloudChatSQLError: Error, Equatable {
    case invalidRecord
    case missingSession
    case messageOwnerChanged
    case invalidSortOrder
}

/// 聊天同步的严格SQL入口，在调用方的数据库actor内执行完整事务。
enum NivoCloudChatSQL {
    /// 正文已经由宿主使用真实ContentPart解码，SQL层负责归属和原子写入。
    struct Message {
        let id: String
        let sessionID: String
        let role: String
        let partsJSON: String
        let createdAt: Double
        let usageJSON: String?
        let reasoning: String?
        let interruptCount: Int
        let updatedAt: Double
        let partFlags: Int
        var modelID: String? = nil
        var modelName: String? = nil
        var providerType: String? = nil
        var providerID: String? = nil
    }

    /// 分组同步使用独立值，允许便携测试执行与应用相同的生产SQL。
    struct Folder {
        let id: String
        let name: String
        let icon: String?
        let color: String?
        let origin: String
        let sortIndex: Int
        let pinnedAt: Double?
        let description: String?
        let createdAt: Double
        let updatedAt: Double
    }

    /// 摘要边界是会话上下文的一部分，同一ID不能被另一会话抢占。
    struct Marker {
        let id: String
        let sessionID: String
        let summary: String
        let firstKeptSortOrder: Int
        let compactedCount: Int
        let createdAt: Double
        let uiBoundarySortOrder: Int?
        let boundaryMessageID: String?
        let firstKeptMessageID: String?
        let lastCompactedMessageID: String?
        let version: Int
    }

    /// 相同ID必须仍属于同一会话；插入时的排序调整与正文写入共同提交或回滚。
    @discardableResult
    static func mergeMessage(_ message: Message, database: OpaquePointer) throws -> Bool {
        try NivoSQLiteWrite.transaction(database) {
            try mergeMessageInTransaction(message, database: database)
        }
    }

    /// 会话元数据与旧消息补入共用外层事务，避免嵌套提交或部分成功。
    @discardableResult
    static func mergeMessageInTransaction(_ message: Message, database: OpaquePointer) throws -> Bool {
        guard sqlite3_get_autocommit(database) == 0 else {
            throw NivoSQLiteWriteError.sqlite(operation: "transaction_required", code: SQLITE_MISUSE)
        }
        guard !message.id.isEmpty, !message.sessionID.isEmpty, !message.role.isEmpty,
              message.createdAt.isFinite, message.updatedAt.isFinite,
              message.interruptCount >= 0 else { throw NivoCloudChatSQLError.invalidRecord }
        let local = try NivoSQLiteWrite.readRow(database,
                sql: "SELECT session_id, COALESCE(updated_at, created_at) FROM messages WHERE id = ?",
                values: [.text(message.id)]) { statement in
                    (try requiredText(statement, column: 0), sqlite3_column_double(statement, 1))
                }
        if let local, local.0 != message.sessionID { throw NivoCloudChatSQLError.messageOwnerChanged }
        if try isMessageDeleted(message, database: database) { return false }
        let parent = try NivoSQLiteWrite.readRow(database,
                sql: "SELECT id FROM sessions WHERE id = ?", values: [.text(message.sessionID)]) {
                    try requiredText($0, column: 0)
                }
        guard parent != nil else { throw NivoCloudChatSQLError.missingSession }
        if let local {
            guard message.updatedAt > local.1 else { return false }
            try updateMessage(message, database: database)
        } else {
            let order = try insertionOrder(message, database: database)
            try insertMessage(message, order: order, database: database)
        }
        return true
    }

    /// 分组版本读取失败不能视为不存在，也不提前发布刷新通知。
    @discardableResult
    static func mergeFolder(_ folder: Folder, database: OpaquePointer,
                            respectTombstones: Bool = true) throws -> Bool {
        guard !folder.id.isEmpty, !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              folder.createdAt.isFinite, folder.updatedAt.isFinite,
              folder.pinnedAt?.isFinite != false else { throw NivoCloudChatSQLError.invalidRecord }
        return try NivoSQLiteWrite.transaction(database) {
            if respectTombstones,
               try wasRecordDeleted(database, type: "Folder", id: folder.id, updatedAt: folder.updatedAt) { return false }
            let local = try NivoSQLiteWrite.readRow(database,
                sql: "SELECT updated_at FROM folders WHERE id = ?", values: [.text(folder.id)]) {
                    sqlite3_column_double($0, 0)
                }
            if let local, local >= folder.updatedAt { return false }
            try NivoSQLiteWrite.execute(database, sql: """
                INSERT INTO folders (id, name, icon, color, origin, sort_index, pinned_at, description, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name, icon = excluded.icon, color = excluded.color,
                    origin = excluded.origin, sort_index = excluded.sort_index,
                    pinned_at = excluded.pinned_at, description = excluded.description,
                    updated_at = excluded.updated_at
                """, values: [.text(folder.id), .text(folder.name), .text(folder.icon), .text(folder.color),
                    .text(folder.origin), .integer(Int64(folder.sortIndex)), .real(folder.pinnedAt),
                    .text(folder.description), .real(folder.createdAt), .real(folder.updatedAt)])
            return true
        }
    }

    /// 解散分组只清除成员关系；删除和防复活标记必须与成员更新一同提交。
    static func deleteFolder(id: String, at timestamp: Double, database: OpaquePointer) throws {
        guard !id.isEmpty, timestamp.isFinite else { throw NivoCloudChatSQLError.invalidRecord }
        try NivoSQLiteWrite.transaction(database) {
            try NivoSQLiteWrite.execute(database,
                sql: "UPDATE sessions SET folder_id = NULL WHERE folder_id = ?", values: [.text(id)])
            try NivoSQLiteWrite.execute(database, sql: "DELETE FROM folders WHERE id = ?", values: [.text(id)])
            try NivoSQLiteWrite.execute(database, sql: """
                INSERT INTO deleted_record_tombstones (record_type, record_id, deleted_at) VALUES ('Folder', ?, ?)
                ON CONFLICT(record_type, record_id) DO UPDATE SET deleted_at = MAX(deleted_at, excluded.deleted_at)
                """, values: [.text(id), .real(timestamp)])
        }
    }

    /// 使用原地UPSERT，保留旧摘要直至新摘要完整提交，远端输入不再登记为本机修改。
    @discardableResult
    static func mergeMarker(_ marker: Marker, database: OpaquePointer) throws -> Bool {
        guard !marker.id.isEmpty, !marker.sessionID.isEmpty, marker.createdAt.isFinite,
              marker.compactedCount >= 0, (1...2).contains(marker.version) else {
            throw NivoCloudChatSQLError.invalidRecord
        }
        return try NivoSQLiteWrite.transaction(database) {
            let local = try NivoSQLiteWrite.readRow(database,
                sql: "SELECT session_id, created_at FROM compact_markers WHERE id = ?", values: [.text(marker.id)]) {
                    (try requiredText($0, column: 0), sqlite3_column_double($0, 1))
                }
            if let local, local.0 != marker.sessionID { throw NivoCloudChatSQLError.messageOwnerChanged }
            if try wasSessionDeleted(database, id: marker.sessionID, updatedAt: marker.createdAt) { return false }
            if try wasRecordDeleted(database, type: "CompactMarker", id: marker.id, updatedAt: marker.createdAt) { return false }
            let parent = try NivoSQLiteWrite.readRow(database,
                sql: "SELECT id FROM sessions WHERE id = ?", values: [.text(marker.sessionID)]) { try requiredText($0, column: 0) }
            guard parent != nil else { throw NivoCloudChatSQLError.missingSession }
            if let local, local.1 >= marker.createdAt { return false }
            try writeMarker(marker, database: database)
            return true
        }
    }

    private static func writeMarker(_ marker: Marker, database: OpaquePointer) throws {
        try NivoSQLiteWrite.execute(database, sql: """
            INSERT INTO compact_markers (id, session_id, summary, first_kept_sort_order, compacted_count,
                created_at, ui_boundary_sort_order, boundary_message_id, first_kept_message_id, last_compacted_message_id, version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET summary = excluded.summary,
                first_kept_sort_order = excluded.first_kept_sort_order, compacted_count = excluded.compacted_count,
                created_at = excluded.created_at, ui_boundary_sort_order = excluded.ui_boundary_sort_order,
                boundary_message_id = excluded.boundary_message_id, first_kept_message_id = excluded.first_kept_message_id,
                last_compacted_message_id = excluded.last_compacted_message_id, version = excluded.version
            """, values: [.text(marker.id), .text(marker.sessionID), .text(marker.summary),
                .integer(Int64(marker.firstKeptSortOrder)), .integer(Int64(marker.compactedCount)), .real(marker.createdAt),
                .integer(marker.uiBoundarySortOrder.map(Int64.init)), .text(marker.boundaryMessageID),
                .text(marker.firstKeptMessageID), .text(marker.lastCompactedMessageID), .integer(Int64(marker.version))])
    }

    private static func updateMessage(_ message: Message, database: OpaquePointer) throws {
        try NivoSQLiteWrite.execute(database, sql: """
            UPDATE messages SET parts_json = ?, token_usage = ?, reasoning_content = ?,
                stream_interrupt_count = ?, updated_at = ?, part_flags = ?,
                model_id = COALESCE(?, model_id), model_display_name = COALESCE(?, model_display_name),
                provider_type = COALESCE(?, provider_type), provider_instance_id = COALESCE(?, provider_instance_id)
            WHERE id = ? AND session_id = ?
            """, values: [.text(message.partsJSON), .text(message.usageJSON), .text(message.reasoning),
                .integer(Int64(message.interruptCount)), .real(message.updatedAt), .integer(Int64(message.partFlags)),
                .text(message.modelID), .text(message.modelName), .text(message.providerType), .text(message.providerID),
                .text(message.id), .text(message.sessionID)])
    }

    private static func insertMessage(_ message: Message, order: Int64, database: OpaquePointer) throws {
        try NivoSQLiteWrite.execute(database, sql: """
            INSERT INTO messages (id, session_id, role, parts_json, created_at, token_usage, sort_order,
                reasoning_content, stream_interrupt_count, updated_at, part_flags, model_id,
                model_display_name, provider_type, provider_instance_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values: [.text(message.id), .text(message.sessionID), .text(message.role), .text(message.partsJSON),
                .real(message.createdAt), .text(message.usageJSON), .integer(order), .text(message.reasoning),
                .integer(Int64(message.interruptCount)), .real(message.updatedAt), .integer(Int64(message.partFlags)),
                .text(message.modelID), .text(message.modelName), .text(message.providerType), .text(message.providerID)])
    }

    /// 沿用本机按时间和ID排序的规则，远端sortOrder只是提示，不能重排本机已有回复。
    private static func insertionOrder(_ message: Message, database: OpaquePointer) throws -> Int64 {
        let values: [NivoSQLiteWrite.Value] = [.text(message.sessionID), .real(message.createdAt),
            .real(message.createdAt), .text(message.id)]
        let earlier = try NivoSQLiteWrite.readRow(database, sql: """
            SELECT COALESCE(MAX(sort_order), -1) FROM messages
            WHERE session_id = ? AND (created_at < ? OR (created_at = ? AND id < ?))
            """, values: values) { sqlite3_column_int64($0, 0) } ?? -1
        let later: Int64? = try NivoSQLiteWrite.readRow(database, sql: """
            SELECT MIN(sort_order) FROM messages
            WHERE session_id = ? AND (created_at > ? OR (created_at = ? AND id > ?))
            """, values: values) {
                sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : sqlite3_column_int64($0, 0)
            } ?? nil
        guard earlier < Int64.max else { throw NivoCloudChatSQLError.invalidSortOrder }
        guard let later, earlier + 1 >= later else { return earlier + 1 }
        let maximum = try NivoSQLiteWrite.readRow(database,
            sql: "SELECT MAX(sort_order) FROM messages WHERE session_id = ?", values: [.text(message.sessionID)]) {
                sqlite3_column_int64($0, 0)
            }
        guard maximum != Int64.max else { throw NivoCloudChatSQLError.invalidSortOrder }
        try NivoSQLiteWrite.execute(database,
            sql: "UPDATE messages SET sort_order = sort_order + 1 WHERE session_id = ? AND sort_order >= ?",
            values: [.text(message.sessionID), .integer(later)])
        return later
    }

    /// 权威消息和旧参考副本共享删除校验，防止参考回填复活已经撤销的原话。
    static func isMessageDeleted(_ message: Message, database: OpaquePointer) throws -> Bool {
        try isMessageDeleted(id: message.id, sessionID: message.sessionID, updatedAt: message.updatedAt, database: database)
    }

    /// 删除判断早于正文解码，已经撤销的损坏旧副本不应阻塞其他有效消息迁移。
    static func isMessageDeleted(id: String, sessionID: String, updatedAt: Double,
                                  database: OpaquePointer) throws -> Bool {
        guard !id.isEmpty, !sessionID.isEmpty, updatedAt.isFinite else { throw NivoCloudChatSQLError.invalidRecord }
        if try wasSessionDeleted(database, id: sessionID, updatedAt: updatedAt) { return true }
        return try wasRecordDeleted(database, type: "Message", id: id, updatedAt: updatedAt)
    }

    private static func wasSessionDeleted(_ database: OpaquePointer, id: String, updatedAt: Double) throws -> Bool {
        let deletedAt = try NivoSQLiteWrite.readRow(database,
            sql: "SELECT deleted_at FROM deleted_session_tombstones WHERE session_id = ?",
            values: [.text(id)]) { sqlite3_column_double($0, 0) }
        guard let deletedAt else { return false }
        return updatedAt <= deletedAt + 5
    }

    private static func wasRecordDeleted(_ database: OpaquePointer, type: String, id: String,
                                         updatedAt: Double) throws -> Bool {
        let deletedAt = try NivoSQLiteWrite.readRow(database,
            sql: "SELECT deleted_at FROM deleted_record_tombstones WHERE record_type = ? AND record_id = ?",
            values: [.text(type), .text(id)]) { sqlite3_column_double($0, 0) }
        guard let deletedAt else { return false }
        return updatedAt <= deletedAt + 5
    }

    private static func requiredText(_ statement: OpaquePointer, column: Int32) throws -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { throw NivoCloudChatSQLError.invalidRecord }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
}
