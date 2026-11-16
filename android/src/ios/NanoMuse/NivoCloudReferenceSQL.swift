import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif

/// 旧设备参考副本仍参与回填，必须保留版本、归属和完整事务，失败交由同步层重放。
enum NivoCloudReferenceSQL {
    /// 当前发送端使用Message:消息ID，也兼容历史复合名称中的会话前缀。
    struct MessageIdentity: Sendable {
        let id: String
        let sessionID: String?

        /// 不从空前缀猜测记录身份，避免删除错误会话的同名内容。
        init(recordName: String) throws {
            guard recordName.hasPrefix("Message:") else { throw NivoCloudChatSQLError.invalidRecord }
            let parts = recordName.dropFirst("Message:".count).split(separator: ":", maxSplits: 1,
                omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { throw NivoCloudChatSQLError.invalidRecord }
            id = String(parts.last!)
            sessionID = parts.count == 2 ? String(parts[0]) : nil
        }
    }

    /// 读取旧库前补充可空版本列，旧行用created_at兼容，不虚构新的修改时间。
    static func prepare(database: OpaquePointer) throws {
        try NivoSQLiteWrite.transaction(database) { try prepareInTransaction(database: database) }
    }

    /// 迁移和写消息可复用外层事务，DDL失败不会留下已标记完成的数据迁移。
    static func prepareInTransaction(database: OpaquePointer) throws {
        guard sqlite3_get_autocommit(database) == 0 else {
            throw NivoSQLiteWriteError.sqlite(operation: "transaction_required", code: SQLITE_MISUSE)
        }
        let columns = try NivoSQLiteWrite.readRows(database, sql: "PRAGMA table_info(remote_messages)") {
            try requiredText($0, 1)
        }
        guard !columns.isEmpty else { throw NivoCloudChatSQLError.invalidRecord }
        if !columns.contains("updated_at") {
            try NivoSQLiteWrite.execute(database, sql: "ALTER TABLE remote_messages ADD COLUMN updated_at REAL")
        }
    }

    /// 占位会话与正文共同提交，乱序重放只能更新同一归属且版本更老的记录。
    static func mergeMessage(_ message: NivoCloudChatSQL.Message, deviceID: String, sortOrder: Int,
                             database: OpaquePointer) throws {
        guard !message.id.isEmpty, !message.sessionID.isEmpty, !deviceID.isEmpty, !message.role.isEmpty,
              message.createdAt.isFinite, message.updatedAt.isFinite, message.interruptCount >= 0,
              sortOrder >= 0 else { throw NivoCloudChatSQLError.invalidRecord }
        try NivoSQLiteWrite.transaction(database) {
            try prepareInTransaction(database: database)
            try requireOwner(message, database: database)
            if try NivoCloudChatSQL.isMessageDeleted(message, database: database) { return }
            try NivoSQLiteWrite.execute(database, sql: """
                INSERT OR IGNORE INTO remote_sessions (id, device_id, title, category, model_id, created_at, updated_at)
                VALUES (?, ?, NULL, NULL, 'unknown', ?, ?)
                """, values: [.text(message.sessionID), .text(deviceID), .real(message.createdAt), .real(message.createdAt)])
            try writeMessage(message, deviceID: deviceID, sortOrder: sortOrder, database: database)
        }
    }

    /// 查询参考副本和本机来源，读取失败或跨会话同ID都不能被当成缺失。
    static func messageSession(id: String, deviceID: String, database: OpaquePointer) throws -> String? {
        let owners = try NivoSQLiteWrite.readRows(database, sql: """
            SELECT session_id FROM messages WHERE id = ?
            UNION SELECT session_id FROM remote_messages WHERE id = ? AND device_id = ?
            """, values: [.text(id), .text(id), .text(deviceID)]) { try requiredText($0, 0) }
        guard owners.count <= 1 else { throw NivoCloudChatSQLError.messageOwnerChanged }
        return owners.first
    }

    /// 旧协议整会话删除仅清理指定设备的参考副本，保留已有本机聊天。
    static func deleteSession(id: String, deviceID: String, database: OpaquePointer) throws {
        guard !id.isEmpty, !deviceID.isEmpty else { throw NivoCloudChatSQLError.invalidRecord }
        try NivoSQLiteWrite.transaction(database) {
            for table in ["remote_messages", "remote_media"] {
                try NivoSQLiteWrite.execute(database, sql: "DELETE FROM \(table) WHERE session_id = ? AND device_id = ?",
                    values: [.text(id), .text(deviceID)])
            }
            try NivoSQLiteWrite.execute(database, sql: "DELETE FROM remote_sessions WHERE id = ? AND device_id = ?",
                values: [.text(id), .text(deviceID)])
        }
    }

    /// 单消息删除和参考清理原子提交；整会话级联则只清参考，沿用旧协议语义。
    @discardableResult
    static func deleteMessage(_ identity: MessageIdentity, deviceID: String, expectedSessionID: String?,
                              preservingSessions: Set<String>, database: OpaquePointer,
                              deletedAt: Double = Date().timeIntervalSince1970) throws -> Bool {
        guard !deviceID.isEmpty, deletedAt.isFinite else { throw NivoCloudChatSQLError.invalidRecord }
        return try NivoSQLiteWrite.transaction(database) {
            let owner = try messageSession(id: identity.id, deviceID: deviceID, database: database)
            if let claimed = identity.sessionID, let owner, claimed != owner {
                throw NivoCloudChatSQLError.messageOwnerChanged
            }
            let resolved = identity.sessionID ?? owner
            guard resolved == expectedSessionID else { throw NivoCloudChatSQLError.messageOwnerChanged }
            if let resolved, preservingSessions.contains(resolved) {
                try NivoSQLiteWrite.execute(database, sql: "DELETE FROM remote_messages WHERE id = ? AND device_id = ?",
                    values: [.text(identity.id), .text(deviceID)])
                return false
            }
            return try deleteMessageInTransaction(id: identity.id, database: database, deletedAt: deletedAt)
        }
    }

    /// V1和V2删除统一保存规范类型标记，同时清理其他设备的旧参考副本。
    @discardableResult
    static func deleteMessageInTransaction(id: String, database: OpaquePointer,
                                           deletedAt: Double) throws -> Bool {
        guard sqlite3_get_autocommit(database) == 0, !id.isEmpty, deletedAt.isFinite else {
            throw NivoCloudChatSQLError.invalidRecord
        }
        let localVersion = try NivoSQLiteWrite.readRow(database,
            sql: "SELECT updated_at FROM messages WHERE id = ?", values: [.text(id)]) { sqlite3_column_double($0, 0) }
        try NivoSQLiteWrite.execute(database, sql: """
            INSERT INTO deleted_record_tombstones(record_type, record_id, deleted_at) VALUES ('Message', ?, ?)
            ON CONFLICT(record_type, record_id) DO UPDATE SET deleted_at = MAX(deleted_at, excluded.deleted_at)
            """, values: [.text(id), .real(max(deletedAt, localVersion ?? deletedAt))])
        try NivoSQLiteWrite.execute(database, sql: "DELETE FROM remote_messages WHERE id = ?", values: [.text(id)])
        try NivoSQLiteWrite.execute(database, sql: "DELETE FROM messages WHERE id = ?", values: [.text(id)])
        return sqlite3_changes(database) > 0
    }

    /// V2整会话删除同时清理旧参考副本与保存删除版本，不能在下次回填时复活。
    @discardableResult
    static func deleteSessionInTransaction(id: String, database: OpaquePointer,
                                           deletedAt: Double) throws -> Bool {
        guard sqlite3_get_autocommit(database) == 0, !id.isEmpty, deletedAt.isFinite else {
            throw NivoCloudChatSQLError.invalidRecord
        }
        let localVersion = try NivoSQLiteWrite.readRow(database,
            sql: "SELECT updated_at FROM sessions WHERE id = ?", values: [.text(id)]) { sqlite3_column_double($0, 0) }
        try NivoSQLiteWrite.execute(database, sql: """
            INSERT INTO deleted_session_tombstones(session_id, deleted_at) VALUES (?, ?)
            ON CONFLICT(session_id) DO UPDATE SET deleted_at = MAX(deleted_at, excluded.deleted_at)
            """, values: [.text(id), .real(max(deletedAt, localVersion ?? deletedAt))])
        for table in ["remote_messages", "remote_media", "messages", "compact_markers"] {
            try NivoSQLiteWrite.execute(database, sql: "DELETE FROM \(table) WHERE session_id = ?", values: [.text(id)])
        }
        try NivoSQLiteWrite.execute(database, sql: "DELETE FROM remote_sessions WHERE id = ?", values: [.text(id)])
        try NivoSQLiteWrite.execute(database, sql: "DELETE FROM sessions WHERE id = ?", values: [.text(id)])
        return sqlite3_changes(database) > 0
    }

    private static func requireOwner(_ message: NivoCloudChatSQL.Message, database: OpaquePointer) throws {
        try NivoSQLiteWrite.forEachRow(database, sql: """
            SELECT session_id FROM remote_messages WHERE id = ?
            UNION SELECT session_id FROM messages WHERE id = ?
            """, values: [.text(message.id), .text(message.id)]) {
                guard try requiredText($0, 0) == message.sessionID else { throw NivoCloudChatSQLError.messageOwnerChanged }
            }
    }

    private static func writeMessage(_ message: NivoCloudChatSQL.Message, deviceID: String, sortOrder: Int,
                                      database: OpaquePointer) throws {
        try NivoSQLiteWrite.execute(database, sql: """
            INSERT INTO remote_messages (id, device_id, session_id, role, parts_json, created_at,
                token_usage, sort_order, reasoning_content, stream_interrupt_count, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id, device_id) DO UPDATE SET role = excluded.role, parts_json = excluded.parts_json,
                token_usage = excluded.token_usage, sort_order = excluded.sort_order,
                reasoning_content = excluded.reasoning_content, stream_interrupt_count = excluded.stream_interrupt_count,
                updated_at = excluded.updated_at
            WHERE excluded.updated_at > COALESCE(remote_messages.updated_at, remote_messages.created_at)
            """, values: [.text(message.id), .text(deviceID), .text(message.sessionID), .text(message.role),
                .text(message.partsJSON), .real(message.createdAt), .text(message.usageJSON), .integer(Int64(sortOrder)),
                .text(message.reasoning), .integer(Int64(message.interruptCount)), .real(message.updatedAt)])
    }

    private static func requiredText(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let text = sqlite3_column_text(statement, column) else {
            throw NivoCloudChatSQLError.invalidRecord
        }
        let value = String(cString: text)
        guard !value.isEmpty else { throw NivoCloudChatSQLError.invalidRecord }
        return value
    }
}
