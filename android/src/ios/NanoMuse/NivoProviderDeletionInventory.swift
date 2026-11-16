import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif

/// 从数据库读取删除所需的标识及版本，不依赖页面是否已经收到最新内容。
enum NivoProviderDeletionInventory {
    /// 保留本版本无法解释的规则ID，清理与同步仍须包含这些规则。
    static func read(database: OpaquePointer, instanceID: String, groupIDs: [String]) throws -> (ruleIDs: [String], lastModified: Date) {
        let ruleIDs = try NivoSQLiteWrite.readRows(database,
            sql: "SELECT id FROM provider_thinking_rules WHERE instance_id = ?", values: [.text(instanceID)]) {
                String(cString: sqlite3_column_text($0, 0))
            }
        let recordTimestamp = try NivoSQLiteWrite.readRow(database, sql: """
            SELECT MAX(version) FROM (
                SELECT updated_at AS version FROM provider_instances WHERE id = ?
                UNION ALL SELECT updated_at FROM provider_model_entries WHERE provider_instance_id = ?
                UNION ALL SELECT updated_at FROM provider_thinking_rules WHERE instance_id = ?)
            """, values: [.text(instanceID), .text(instanceID), .text(instanceID)]) { sqlite3_column_double($0, 0) } ?? 0
        let timestamp = max(recordTimestamp, try groupVersion(database: database, identifiers: groupIDs))
        guard timestamp.isFinite else { throw NivoPersonalBackupError.invalidPackage }
        return (ruleIDs, Date(timeIntervalSince1970: max(timestamp.nextUp, timestamp + 0.001)))
    }

    private static func groupVersion(database: OpaquePointer, identifiers: [String]) throws -> TimeInterval {
        let unique = Array(Set(identifiers)).sorted()
        var latest: TimeInterval = 0
        // 分批绑定避免大量模型组触及旧版SQLite的参数数量上限。
        for offset in stride(from: 0, to: unique.count, by: 400) {
            let batch = Array(unique[offset..<min(offset + 400, unique.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let version = try NivoSQLiteWrite.readRow(database,
                sql: "SELECT MAX(updated_at) FROM provider_model_groups WHERE id IN (\(placeholders))",
                values: batch.map { .text($0) }) { sqlite3_column_double($0, 0) } ?? 0
            guard version.isFinite else { throw NivoPersonalBackupError.invalidPackage }
            latest = max(latest, version)
        }
        return latest
    }
}
