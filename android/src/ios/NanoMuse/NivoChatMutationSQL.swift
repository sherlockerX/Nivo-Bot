import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif

/// 页面历史与数据库不再一致时停止编辑，不能凭过期行数删除另一条消息。
enum NivoChatMutationError: Error, Equatable {
    case staleHistory
    case invalidRequest
}

/// 本机清空、重试截断和中继删除的事务边界，调用者在数据库actor内同步执行。
enum NivoChatMutationSQL {
    typealias DirtyWriter = (_ type: String, _ id: String, _ operation: String) throws -> Void

    /// 保留行改写携带读取时的完整正文，避免覆盖读取后到达的新版本。
    struct Rewrite: Sendable {
        let messageID: String
        let expectedJSON: String
        let partsJSON: String
        let partFlags: Int
    }

    /// 清空保留会话配置，同时删除正文、旧参考、摘要及相应同步记录。
    static func clear(sessionID: String, database: OpaquePointer, at timestamp: Double,
                      markDirty: DirtyWriter) throws {
        try validate(sessionID: sessionID, timestamp: timestamp)
        try NivoSQLiteWrite.transaction(database) {
            try clearInTransaction(sessionID: sessionID, database: database, at: timestamp, markDirty: markDirty)
        }
    }

    /// 整会话删除包含所有子项与文件同步请求；附件实际清理由宿主在提交成功后执行。
    static func deleteSessions(files: [String: [String]], database: OpaquePointer,
                               at timestamp: Double, markDirty: DirtyWriter) throws {
        for sessionID in files.keys { try validate(sessionID: sessionID, timestamp: timestamp) }
        try NivoSQLiteWrite.transaction(database) {
            for sessionID in files.keys.sorted() {
                try clearInTransaction(sessionID: sessionID, database: database, at: timestamp, markDirty: markDirty)
                for identifier in files[sessionID] ?? [] { try markDirty("SessionFile", identifier, "delete") }
                try markDirty("Session", sessionID, "delete")
                try NivoCloudReferenceSQL.deleteSessionInTransaction(id: sessionID, database: database, deletedAt: timestamp)
            }
        }
    }

    /// 用真实消息身份校验整个已加载序列，支持稀疏或重复排序号，不把行数当排序边界。
    static func truncate(sessionID: String, expectedIDs: [String], retainedIDs: [String],
                         rewrite: Rewrite? = nil, database: OpaquePointer, at timestamp: Double,
                         markDirty: DirtyWriter) throws {
        try validate(sessionID: sessionID, timestamp: timestamp)
        guard Set(expectedIDs).count == expectedIDs.count, !expectedIDs.contains(""),
              retainedIDs == Array(expectedIDs.prefix(retainedIDs.count)),
              rewrite.map({ retainedIDs.contains($0.messageID) }) ?? true else {
            throw NivoChatMutationError.invalidRequest
        }
        try NivoSQLiteWrite.transaction(database) {
            let actual = try NivoSQLiteWrite.readRows(database, sql: """
                SELECT id FROM messages WHERE session_id = ? ORDER BY sort_order, created_at, id
                """, values: [.text(sessionID)]) { try text($0, 0) }
            guard actual == expectedIDs else { throw NivoChatMutationError.staleHistory }
            try NivoCloudReferenceSQL.prepareInTransaction(database: database)
            for identifier in expectedIDs.dropFirst(retainedIDs.count) {
                try removeMessage(identifier, sessionID: sessionID, database: database,
                                  at: timestamp, markDirty: markDirty)
            }
            if let rewrite {
                try rewriteMessage(rewrite, sessionID: sessionID, database: database,
                                   at: timestamp, markDirty: markDirty)
            }
            // 摘要可能含已删或已改写的原话，完整历史仍保留，下一轮可重新压缩。
            try removeMarkers(sessionID: sessionID, database: database, at: timestamp, markDirty: markDirty)
        }
    }

    /// 中继使用小写UUID；两种旧存储形式共同校验归属、删除与防复活，不回发删除。
    static func deleteRelayMessage(id: String, sessionID: String, database: OpaquePointer,
                                   at timestamp: Double) throws {
        try validate(sessionID: sessionID, timestamp: timestamp)
        guard !id.isEmpty else { throw NivoChatMutationError.invalidRequest }
        let identifiers = UUID(uuidString: id).map { [$0.uuidString.lowercased(), $0.uuidString] } ?? [id]
        try NivoSQLiteWrite.transaction(database) {
            try NivoCloudReferenceSQL.prepareInTransaction(database: database)
            for identifier in identifiers {
                try removeMessage(identifier, sessionID: sessionID, database: database,
                                  at: timestamp, markDirty: { _, _, _ in })
            }
        }
    }

    /// 中继整会话删除的数据库入口，主会话保留策略由宿主确定。
    static func applyRelayConversationDeletion(sessionID: String, conversationID: String,
                                               preservesSession: Bool, database: OpaquePointer,
                                               deletedAt: Double) throws {
        try validate(sessionID: sessionID, timestamp: deletedAt)
        guard !conversationID.isEmpty else { throw NivoChatMutationError.invalidRequest }
        let receiptID = sessionID + ":" + conversationID
        try NivoSQLiteWrite.transaction(database) {
            try NivoCloudReferenceSQL.prepareInTransaction(database: database)
            let appliedAt = try NivoSQLiteWrite.readRow(database, sql: """
                SELECT deleted_at FROM deleted_record_tombstones
                WHERE record_type = 'RelayConversation' AND record_id = ?
                """, values: [.text(receiptID)]) { sqlite3_column_double($0, 0) }
            if let appliedAt, appliedAt >= deletedAt { return }
            try clearInTransaction(sessionID: sessionID, database: database, at: deletedAt, markDirty: { _, _, _ in })
            if !preservesSession {
                try NivoCloudReferenceSQL.deleteSessionInTransaction(id: sessionID, database: database, deletedAt: deletedAt)
            }
            // 删除和回执共同提交，游标文件失败后的重放不能清空用户随后写入的新消息。
            try NivoSQLiteWrite.execute(database, sql: """
                INSERT INTO deleted_record_tombstones(record_type, record_id, deleted_at)
                VALUES ('RelayConversation', ?, ?)
                ON CONFLICT(record_type, record_id) DO UPDATE SET deleted_at = MAX(deleted_at, excluded.deleted_at)
                """, values: [.text(receiptID), .real(deletedAt)])
        }
    }

    /// 单条撤销摘要的数据库入口，由调用方提供当前显示的会话和摘要身份。
    static func revertMarker(id: String, sessionID: String, database: OpaquePointer,
                             at timestamp: Double, markDirty: DirtyWriter) throws {
        try validate(sessionID: sessionID, timestamp: timestamp)
        guard !id.isEmpty else { throw NivoChatMutationError.invalidRequest }
        try NivoSQLiteWrite.transaction(database) {
            let latest = try NivoSQLiteWrite.readRow(database, sql: """
                SELECT id, created_at FROM compact_markers WHERE session_id = ? ORDER BY created_at DESC LIMIT 1
                """, values: [.text(sessionID)]) { (try text($0, 0), sqlite3_column_double($0, 1)) }
            guard let latest, latest.0 == id, latest.1.isFinite else { throw NivoChatMutationError.staleHistory }
            try NivoCloudReferenceSQL.prepareInTransaction(database: database)
            try NivoSQLiteWrite.execute(database, sql: """
                INSERT INTO deleted_record_tombstones(record_type, record_id, deleted_at)
                VALUES ('CompactMarker', ?, ?)
                ON CONFLICT(record_type, record_id) DO UPDATE SET deleted_at = MAX(deleted_at, excluded.deleted_at)
                """, values: [.text(id), .real(max(timestamp, latest.1))])
            try markDirty("CompactMarker", id, "delete")
            try NivoSQLiteWrite.execute(database, sql: "DELETE FROM compact_markers WHERE id = ? AND session_id = ?",
                values: [.text(id), .text(sessionID)])
        }
    }

    private static func validate(sessionID: String, timestamp: Double) throws {
        guard !sessionID.isEmpty, timestamp.isFinite else { throw NivoChatMutationError.invalidRequest }
    }

    private static func clearInTransaction(sessionID: String, database: OpaquePointer, at timestamp: Double,
                                           markDirty: DirtyWriter) throws {
        try NivoCloudReferenceSQL.prepareInTransaction(database: database)
        let identifiers = try NivoSQLiteWrite.readRows(database, sql: """
            SELECT id FROM messages WHERE session_id = ?
            UNION SELECT id FROM remote_messages WHERE session_id = ?
            """, values: [.text(sessionID), .text(sessionID)]) { try text($0, 0) }
        for identifier in identifiers {
            try removeMessage(identifier, sessionID: sessionID, database: database, at: timestamp, markDirty: markDirty)
        }
        try removeMarkers(sessionID: sessionID, database: database, at: timestamp, markDirty: markDirty)
    }

    private static func removeMessage(_ id: String, sessionID: String, database: OpaquePointer,
                                      at timestamp: Double, markDirty: DirtyWriter) throws {
        let versions = try NivoSQLiteWrite.readRows(database, sql: """
            SELECT session_id, COALESCE(updated_at, created_at) FROM messages WHERE id = ?
            UNION ALL SELECT session_id, COALESCE(updated_at, created_at) FROM remote_messages WHERE id = ?
            """, values: [.text(id), .text(id)]) { (try text($0, 0), sqlite3_column_double($0, 1)) }
        guard versions.allSatisfy({ $0.0 == sessionID && $0.1.isFinite }) else {
            throw NivoCloudChatSQLError.messageOwnerChanged
        }
        let deletedAt = max(timestamp, versions.map(\.1).max() ?? timestamp)
        try NivoCloudReferenceSQL.deleteMessageInTransaction(id: id, database: database, deletedAt: deletedAt)
        try markDirty("Message", id, "delete")
    }

    private static func rewriteMessage(_ rewrite: Rewrite, sessionID: String, database: OpaquePointer,
                                       at timestamp: Double, markDirty: DirtyWriter) throws {
        let version = try NivoSQLiteWrite.readRow(database, sql: """
            SELECT COALESCE(updated_at, created_at) FROM messages
            WHERE id = ? AND session_id = ? AND parts_json = ?
            """, values: [.text(rewrite.messageID), .text(sessionID), .text(rewrite.expectedJSON)]) {
                sqlite3_column_double($0, 0)
            }
        guard let version, version.isFinite else { throw NivoChatMutationError.staleHistory }
        let updatedAt = max(timestamp, max(version + 0.001, version.nextUp))
        guard updatedAt.isFinite else { throw NivoChatMutationError.invalidRequest }
        try NivoSQLiteWrite.execute(database, sql: """
            UPDATE messages SET parts_json = ?, part_flags = ?, updated_at = ?, error_info = NULL,
                stream_interrupt_count = 0 WHERE id = ? AND session_id = ?
            """, values: [.text(rewrite.partsJSON), .integer(Int64(rewrite.partFlags)), .real(updatedAt),
                .text(rewrite.messageID), .text(sessionID)])
        guard sqlite3_changes(database) == 1 else { throw NivoChatMutationError.staleHistory }
        try markDirty("Message", rewrite.messageID, "upsert")
    }

    private static func removeMarkers(sessionID: String, database: OpaquePointer, at timestamp: Double,
                                       markDirty: DirtyWriter) throws {
        let markers = try NivoSQLiteWrite.readRows(database,
            sql: "SELECT id, created_at FROM compact_markers WHERE session_id = ?", values: [.text(sessionID)]) {
                (try text($0, 0), sqlite3_column_double($0, 1))
            }
        for (identifier, version) in markers {
            guard version.isFinite else { throw NivoChatMutationError.invalidRequest }
            try NivoSQLiteWrite.execute(database, sql: """
                INSERT INTO deleted_record_tombstones(record_type, record_id, deleted_at)
                VALUES ('CompactMarker', ?, ?)
                ON CONFLICT(record_type, record_id) DO UPDATE SET deleted_at = MAX(deleted_at, excluded.deleted_at)
                """, values: [.text(identifier), .real(max(timestamp, version))])
            try markDirty("CompactMarker", identifier, "delete")
        }
        try NivoSQLiteWrite.execute(database, sql: "DELETE FROM compact_markers WHERE session_id = ?",
                                   values: [.text(sessionID)])
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(statement, column) else { throw NivoChatMutationError.invalidRequest }
        return String(cString: bytes)
    }
}
