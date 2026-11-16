import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif

/// 会话入站元数据与旧消息补入在同一数据库事务内提交。
enum NivoCloudSessionSQL {
    /// 仅包含现有同步协议字段，缺少分组字段的旧客户端不清空本机归属。
    struct Session {
        let id: String
        let title: String?
        let category: String?
        let modelID: String
        let createdAt: Double
        let updatedAt: Double
        let sourceDeviceID: String
        let memoryEnabled: Bool
        let modelBinding: String?
        let rawPinnedAt: Double?
        let folderID: String?
        let hasFolderField: Bool
    }

    /// 仅在提交成功后向宿主提供刷新类型，空操作不触发页面重载。
    enum Mutation: Equatable {
        case unchanged
        case inserted
        case updated
    }

    private struct Local {
        let updatedAt: Double
        let pinnedAt: Double?
        let folderID: String?
    }

    /// 不接受读取失败后的默认值；任意补入消息失败时同时回滚标题、分组和置顶状态。
    @discardableResult
    static func merge(_ session: Session, backfill: [NivoCloudChatSQL.Message] = [],
                      database: OpaquePointer) throws -> Mutation {
        try NivoSQLiteWrite.transaction(database) {
            try mergeInTransaction(session, backfill: backfill, database: database)
        }
    }

    /// 启动回填复用会话保护规则，由调用方把全部记录与迁移标记共同提交。
    @discardableResult
    static func mergeInTransaction(_ session: Session, backfill: [NivoCloudChatSQL.Message] = [],
                                   database: OpaquePointer) throws -> Mutation {
        guard sqlite3_get_autocommit(database) == 0 else {
            throw NivoSQLiteWriteError.sqlite(operation: "transaction_required", code: SQLITE_MISUSE)
        }
        guard !session.id.isEmpty, !session.modelID.isEmpty,
              session.createdAt.isFinite, session.updatedAt.isFinite,
              session.rawPinnedAt?.isFinite != false,
              backfill.allSatisfy({ $0.sessionID == session.id }) else { throw NivoCloudChatSQLError.invalidRecord }
        let local = try readLocal(id: session.id, database: database)
        if local == nil, try wasDeleted(session, database: database) { return .unchanged }
        let pin = resolvePin(remote: session.rawPinnedAt, local: local?.pinnedAt)
        var result = try writeMetadata(session, local: local, pin: pin, database: database)
        for message in backfill {
            if try NivoCloudChatSQL.mergeMessageInTransaction(message, database: database), result == .unchanged {
                result = .updated
            }
        }
        return result
    }

    /// 旧协议的参考副本也严格写入，失败保留接收批次，重放不会覆盖较新的参考版本。
    static func mergeReference(_ session: Session, database: OpaquePointer) throws {
        try NivoSQLiteWrite.execute(database, sql: """
            INSERT INTO remote_sessions (id, device_id, title, category, model_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id, device_id) DO UPDATE SET title = excluded.title, category = excluded.category,
                model_id = excluded.model_id, updated_at = excluded.updated_at
            WHERE excluded.updated_at > remote_sessions.updated_at
            """, values: [.text(session.id), .text(session.sourceDeviceID), .text(session.title), .text(session.category),
                .text(session.modelID), .real(session.createdAt), .real(session.updatedAt)])
    }

    private static func readLocal(id: String, database: OpaquePointer) throws -> Local? {
        try NivoSQLiteWrite.readRow(database,
            sql: "SELECT updated_at, pinned_at, folder_id FROM sessions WHERE id = ?", values: [.text(id)]) {
                guard sqlite3_column_type($0, 0) != SQLITE_NULL else { throw NivoCloudChatSQLError.invalidRecord }
                let updatedAt = sqlite3_column_double($0, 0)
                guard updatedAt.isFinite else { throw NivoCloudChatSQLError.invalidRecord }
                return Local(updatedAt: updatedAt,
                    pinnedAt: sqlite3_column_type($0, 1) == SQLITE_NULL ? nil : sqlite3_column_double($0, 1),
                    folderID: sqlite3_column_text($0, 2).map { String(cString: $0) })
            }
    }

    private static func writeMetadata(_ session: Session, local: Local?, pin: Double?,
                                      database: OpaquePointer) throws -> Mutation {
        guard let local else {
            try insert(session, pin: pin, database: database)
            return .inserted
        }
        if session.updatedAt > local.updatedAt {
            try NivoSQLiteWrite.execute(database, sql: """
                UPDATE sessions SET title = ?, category = ?, updated_at = ?, memory_enabled = ?,
                    model_binding = ?, pinned_at = ?, folder_id = ? WHERE id = ?
                """, values: [.text(session.title), .text(session.category), .real(session.updatedAt),
                    .integer(session.memoryEnabled ? 1 : 0), .text(session.modelBinding), .real(pin),
                    .text(session.hasFolderField ? session.folderID : local.folderID), .text(session.id)])
            return .updated
        }
        // 旧协议没有分组/取消置顶的单独版本，继续保留本机已有意见。
        let folder = local.folderID ?? (session.hasFolderField ? session.folderID : nil)
        guard folder != local.folderID || pin != local.pinnedAt else { return .unchanged }
        try NivoSQLiteWrite.execute(database, sql: "UPDATE sessions SET folder_id = ?, pinned_at = ? WHERE id = ?",
            values: [.text(folder), .real(pin), .text(session.id)])
        return .updated
    }

    private static func insert(_ session: Session, pin: Double?, database: OpaquePointer) throws {
        try NivoSQLiteWrite.execute(database, sql: """
            INSERT INTO sessions (id, title, category, model_id, created_at, updated_at,
                remote_origin_device_id, memory_enabled, model_binding, pinned_at, folder_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values: [.text(session.id), .text(session.title), .text(session.category), .text(session.modelID),
                .real(session.createdAt), .real(session.updatedAt), .text(session.sourceDeviceID),
                .integer(session.memoryEnabled ? 1 : 0), .text(session.modelBinding), .real(pin),
                .text(session.hasFolderField ? session.folderID : nil)])
    }

    /// 沿用已有置顶合并规则；现有协议无法排序取消置顶与另一设备的置顶操作。
    private static func resolvePin(remote: Double?, local: Double?) -> Double? {
        guard let remote, remote > 0 else { return local }
        return max(remote, local ?? remote)
    }

    private static func wasDeleted(_ session: Session, database: OpaquePointer) throws -> Bool {
        try isSessionDeleted(id: session.id, updatedAt: session.updatedAt, database: database)
    }

    /// 会话文件同样严格读取删除标记，查询失败不能当作允许重建目录。
    static func isSessionDeleted(id: String, updatedAt: Double, database: OpaquePointer) throws -> Bool {
        guard !id.isEmpty, updatedAt.isFinite else { throw NivoCloudChatSQLError.invalidRecord }
        let deletedAt = try NivoSQLiteWrite.readRow(database,
            sql: "SELECT deleted_at FROM deleted_session_tombstones WHERE session_id = ?", values: [.text(id)]) {
                sqlite3_column_double($0, 0)
            }
        guard let deletedAt else { return false }
        return updatedAt <= deletedAt + 5
    }
}
