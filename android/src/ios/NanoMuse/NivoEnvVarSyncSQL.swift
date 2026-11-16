import Foundation

/// 将环境变量变更、删除保护和恢复回执写入同一SQLite事务，防止进程退出丢掉删除请求。
enum NivoEnvVarSyncSQL {
    /// 只在数据库actor内调用；重复回执不能覆盖后来已经排队的编辑。
    static func confirm(_ journal: NivoEnvVarTransaction.Journal, database: OpaquePointer,
                        zoneName: String, shouldUpload: Bool) throws {
        try journal.validate()
        guard journal.phase == .awaitingSync, !zoneName.isEmpty else {
            throw NivoEnvVarTransaction.Failure.invalidJournal
        }
        try NivoSQLiteWrite.transaction(database) {
            let isRecorded = try NivoSQLiteWrite.readRow(database, sql: """
                SELECT 1 FROM deleted_record_tombstones WHERE record_type = 'EnvVarTransaction' AND record_id = ?
                """, values: [.text(journal.identifier.uuidString)]) { _ in true } ?? false
            guard !isRecorded else { return }
            for change in journal.changes {
                if change.operation == .delete {
                    let version = journal.before.first { $0.id == change.id }?.version ?? journal.createdAt
                    try recordReceipt(database, type: "EnvVarItem", id: change.id, date: max(version, journal.createdAt))
                }
                if shouldUpload {
                    try NivoSQLiteWrite.execute(database, sql: """
                        INSERT OR REPLACE INTO sync_dirty_records
                            (record_type, record_id, zone_name, operation, priority, created_at)
                        VALUES ('EnvVarItem', ?, ?, ?, 0, ?)
                        """, values: [.text(change.id), .text(zoneName), .text(change.operation.rawValue),
                                      .real(journal.createdAt.timeIntervalSince1970)])
                }
            }
            try recordReceipt(database, type: "EnvVarTransaction", id: journal.identifier.uuidString, date: journal.createdAt)
        }
    }

    private static func recordReceipt(_ database: OpaquePointer, type: String, id: String, date: Date) throws {
        try NivoSQLiteWrite.execute(database, sql: """
            INSERT INTO deleted_record_tombstones(record_type, record_id, deleted_at) VALUES (?, ?, ?)
            ON CONFLICT(record_type, record_id) DO UPDATE SET deleted_at = MAX(deleted_at, excluded.deleted_at)
            """, values: [.text(type), .text(id), .real(date.timeIntervalSince1970)])
    }
}
