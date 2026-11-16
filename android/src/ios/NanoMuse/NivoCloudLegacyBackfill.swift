import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif

/// 将旧参考副本补入权威聊天库；数据和完成标记共享事务，失败保留原始参考记录。
enum NivoCloudLegacyBackfill {
    /// 已有本机记录不被参考副本覆盖，计数仅包含本次真正插入的行。
    struct Result: Equatable, Sendable {
        var sessions = 0
        var messages = 0
        var alreadyCompleted = false
    }

    typealias BodyValidator = (_ role: String, _ body: String, _ usage: String?) throws -> Int
    private static let MIGRATION_ID = "remote_reference_backfill_v2"

    /// 标记属于当前数据库，整库恢复后重新判断，不沿用旧UserDefaults里的成功标志。
    static func isComplete(database: OpaquePointer) throws -> Bool {
        try NivoSQLiteWrite.execute(database, sql: """
            CREATE TABLE IF NOT EXISTS nivo_chat_migrations (
                id TEXT PRIMARY KEY NOT NULL, completed_at REAL NOT NULL
            )
            """)
        return try NivoSQLiteWrite.readRow(database,
            sql: "SELECT id FROM nivo_chat_migrations WHERE id = ?", values: [.text(MIGRATION_ID)]) { _ in true } ?? false
    }

    /// 宿主先为全部目标会话取得编辑占位，查询失败不能当作没有待回填数据。
    static func pendingSessionIDs(database: OpaquePointer) throws -> Set<String> {
        if try isComplete(database: database) { return [] }
        return Set(try NivoSQLiteWrite.readRows(database, sql: """
            SELECT id FROM remote_sessions UNION SELECT session_id FROM remote_messages
            """) { try requiredText($0, 0) })
    }

    /// 事务内重新核对目标集合，异步等待期间新增的会话不能越过宿主占位。
    static func run(database: OpaquePointer, expectedSessionIDs: Set<String>,
                    validateBody: BodyValidator) throws -> Result {
        try NivoSQLiteWrite.transaction(database) {
            if try isComplete(database: database) { return Result(alreadyCompleted: true) }
            let pending = try pendingSessionIDs(database: database)
            guard pending.isSubset(of: expectedSessionIDs) else { throw NivoCloudChatSQLError.invalidRecord }
            try NivoCloudReferenceSQL.prepareInTransaction(database: database)
            var result = Result()
            result.sessions = try importSessions(database: database)
            result.messages = try importMessages(database: database, validateBody: validateBody)
            try NivoSQLiteWrite.execute(database,
                sql: "INSERT INTO nivo_chat_migrations(id, completed_at) VALUES (?, ?)",
                values: [.text(MIGRATION_ID), .real(Date().timeIntervalSince1970)])
            return result
        }
    }

    private static func importSessions(database: OpaquePointer) throws -> Int {
        var inserted = 0
        try NivoSQLiteWrite.forEachRow(database, sql: """
            SELECT id, device_id, title, category, model_id, created_at, updated_at
            FROM remote_sessions ORDER BY id, updated_at DESC, device_id
            """) { statement in
                let identifier = try requiredText(statement, 0)
                let exists = try NivoSQLiteWrite.readRow(database,
                    sql: "SELECT id FROM sessions WHERE id = ?", values: [.text(identifier)]) { _ in true } ?? false
                guard !exists else { return }
                let session = NivoCloudSessionSQL.Session(id: identifier, title: optionalText(statement, 2),
                    category: optionalText(statement, 3), modelID: try requiredText(statement, 4),
                    createdAt: try requiredNumber(statement, 5), updatedAt: try requiredNumber(statement, 6),
                    sourceDeviceID: try requiredText(statement, 1), memoryEnabled: true, modelBinding: nil,
                    rawPinnedAt: nil, folderID: nil, hasFolderField: false)
                if try NivoCloudSessionSQL.mergeInTransaction(session, database: database) == .inserted { inserted += 1 }
            }
        return inserted
    }

    private static func importMessages(database: OpaquePointer, validateBody: BodyValidator) throws -> Int {
        var inserted = 0
        try NivoSQLiteWrite.forEachRow(database, sql: """
            SELECT id, session_id, role, parts_json, created_at, token_usage,
                reasoning_content, stream_interrupt_count, COALESCE(updated_at, created_at)
            FROM remote_messages ORDER BY session_id, id, COALESCE(updated_at, created_at) DESC, device_id
            """) { statement in
                let identifier = try requiredText(statement, 0)
                let sessionID = try requiredText(statement, 1)
                if try hasLocalMessage(id: identifier, sessionID: sessionID, database: database) { return }
                let createdAt = try requiredNumber(statement, 4)
                let updatedAt = try requiredNumber(statement, 8)
                if try NivoCloudChatSQL.isMessageDeleted(id: identifier, sessionID: sessionID,
                    updatedAt: updatedAt, database: database) { return }
                let role = try requiredText(statement, 2)
                let body = try requiredText(statement, 3)
                let usage = optionalText(statement, 5)
                guard sqlite3_column_type(statement, 7) == SQLITE_INTEGER else { throw NivoCloudChatSQLError.invalidRecord }
                let message = NivoCloudChatSQL.Message(id: identifier, sessionID: sessionID, role: role, partsJSON: body,
                    createdAt: createdAt, usageJSON: usage, reasoning: optionalText(statement, 6),
                    interruptCount: Int(sqlite3_column_int64(statement, 7)), updatedAt: updatedAt,
                    partFlags: try validateBody(role, body, usage))
                if try NivoCloudChatSQL.mergeMessageInTransaction(message, database: database) { inserted += 1 }
            }
        return inserted
    }

    private static func hasLocalMessage(id: String, sessionID: String, database: OpaquePointer) throws -> Bool {
        let owner = try NivoSQLiteWrite.readRow(database,
            sql: "SELECT session_id FROM messages WHERE id = ?", values: [.text(id)]) { try requiredText($0, 0) }
        if let owner, owner != sessionID { throw NivoCloudChatSQLError.messageOwnerChanged }
        return owner != nil
    }

    private static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func requiredText(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let value = optionalText(statement, column), !value.isEmpty else { throw NivoCloudChatSQLError.invalidRecord }
        return value
    }

    private static func requiredNumber(_ statement: OpaquePointer, _ column: Int32) throws -> Double {
        let type = sqlite3_column_type(statement, column)
        let value = sqlite3_column_double(statement, column)
        guard (type == SQLITE_FLOAT || type == SQLITE_INTEGER), value.isFinite else { throw NivoCloudChatSQLError.invalidRecord }
        return value
    }
}
