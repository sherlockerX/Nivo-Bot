import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif

/// 中继会话先预留稳定本机ID，再严格落库；失败重试不会生成第二个会话。
enum NivoRelayChatSQL {
    /// 已有会话只更新允许的标题，不改模型、记忆、分组或本机创建时间。
    struct Session: Sendable {
        let id: String
        let title: String?
        let modelID: String
        let createdAt: Double
        let updatedAt: Double
        let memoryEnabled: Bool
        let mayCreate: Bool
        let updatesTitle: Bool
        let onlyIfUntitled: Bool
    }

    enum Result: Equatable { case missing, unchanged, inserted, updated }

    private struct Local {
        let title: String?
        let source: String?
        let updatedAt: Double
    }

    /// 元数据变更和同步标记共同提交；删除记录或失效映射不允许重建。
    static func ensure(_ session: Session, database: OpaquePointer,
                       markDirty: () throws -> Void = {}) throws -> Result {
        guard !session.id.isEmpty, !session.modelID.isEmpty, session.createdAt.isFinite,
              session.updatedAt.isFinite else { throw NivoLifeError.corruptStore }
        return try NivoSQLiteWrite.transaction(database) {
            if let local = try read(session.id, database: database) {
                guard !session.mayCreate || local.source == "nanomuse-sync" else {
                    throw NivoLifeError.operationConflict
                }
                return try update(session, local: local, database: database, markDirty: markDirty)
            }
            guard session.mayCreate, try !wasDeleted(session.id, database: database) else { return .missing }
            try NivoSQLiteWrite.execute(database, sql: """
                INSERT INTO sessions (id, title, model_id, created_at, updated_at, source, memory_enabled)
                VALUES (?, ?, ?, ?, ?, 'nanomuse-sync', ?)
                """, values: [.text(session.id), .text(session.title), .text(session.modelID),
                    .real(session.createdAt), .real(session.updatedAt), .integer(session.memoryEnabled ? 1 : 0)])
            return .inserted
        }
    }

    private static func read(_ id: String, database: OpaquePointer) throws -> Local? {
        try NivoSQLiteWrite.readRow(database, sql: "SELECT title, source, updated_at FROM sessions WHERE id = ?",
            values: [.text(id)]) {
                Local(title: sqlite3_column_text($0, 0).map { String(cString: $0) },
                    source: sqlite3_column_text($0, 1).map { String(cString: $0) }, updatedAt: sqlite3_column_double($0, 2))
            }
    }

    private static func update(_ session: Session, local: Local, database: OpaquePointer,
                               markDirty: () throws -> Void) throws -> Result {
        // 中继已按版本选择标题；会话活动时间会被新消息推进，不能据此拒绝远端重命名。
        guard session.updatesTitle, session.title != local.title,
              !session.onlyIfUntitled || local.title == nil else { return .unchanged }
        try NivoSQLiteWrite.execute(database, sql: "UPDATE sessions SET title = ?, updated_at = ? WHERE id = ?",
            values: [.text(session.title), .real(max(local.updatedAt, session.updatedAt)), .text(session.id)])
        try markDirty()
        return .updated
    }

    private static func wasDeleted(_ id: String, database: OpaquePointer) throws -> Bool {
        try NivoSQLiteWrite.readRow(database,
            sql: "SELECT 1 FROM deleted_session_tombstones WHERE session_id = ?", values: [.text(id)]) { _ in true } ?? false
    }
}
