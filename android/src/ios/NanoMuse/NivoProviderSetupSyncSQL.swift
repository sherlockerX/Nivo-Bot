import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif

/// 为已持久化的新提供商登记同步；调用方持有备份日志，队列失败会回滚新增配置。
enum NivoProviderSetupSyncSQL {
    struct Plan: Equatable, Sendable {
        let instanceID: String
        let entryIDs: [String]
        let groupIDs: [String]
    }

    struct Record: Codable, Equatable, Sendable {
        let type: String
        let id: String
        let zone: String
        let operation: String
        let priority: Int64
        let createdAt: Double
    }

    struct Change: Codable, Equatable, Sendable {
        let previous: Record?
        let proposed: Record
    }

    struct Receipt: Codable, Equatable, Sendable {
        let changes: [Change]

        /// 回执仅允许提供商队列记录；不接受任意表名、SQL或聊天记录。
        func validate() throws {
            let types: Set<String> = ["ProviderInstanceV3", "ProviderModelEntryV3", "ProviderModelGroupV3", "ProviderConfig", "ProviderConfigV2"]
            guard changes.count <= 100_000,
                  Set(changes.map { $0.proposed.type + "\0" + $0.proposed.id }).count == changes.count else {
                throw NivoPersonalBackupError.invalidPackage
            }
            for change in changes {
                let proposed = change.proposed
                if let prior = change.previous, prior.type != proposed.type || prior.id != proposed.id {
                    throw NivoPersonalBackupError.invalidPackage
                }
                for record in [change.previous, proposed].compactMap({ $0 }) {
                    guard types.contains(record.type), !record.id.isEmpty, record.id.utf8.count <= 4096,
                          !record.id.contains("\0"), !record.zone.isEmpty, record.zone.utf8.count <= 4096,
                          record.createdAt.isFinite, ["upsert", "delete"].contains(record.operation) else {
                        throw NivoPersonalBackupError.invalidPackage
                    }
                }
            }
        }
    }

    /// 单次提交实例、模型、分组及旧协议整包，不能以部分排队报告成功。
    static func confirm(_ plan: Plan, database: OpaquePointer, zoneName: String,
                        legacyRecordTypes: [String], shouldUpload: (String) -> Bool) throws {
        let receipt = try prepare(plan, database: database, zoneName: zoneName,
            legacyRecordTypes: legacyRecordTypes, shouldUpload: shouldUpload)
        try confirm(receipt, database: database)
    }

    /// 正式配置写入之前读取受影响队列，宿主必须先将此回执加入恢复日志。
    static func prepare(_ plan: Plan, database: OpaquePointer, zoneName: String,
                        legacyRecordTypes: [String], shouldUpload: (String) -> Bool) throws -> Receipt {
        let ids = [plan.instanceID] + plan.entryIDs + plan.groupIDs
        guard !zoneName.isEmpty, ids.count <= 100_000,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") }),
              Set(legacyRecordTypes).isSubset(of: ["ProviderConfig", "ProviderConfigV2"]) else {
            throw NivoPersonalBackupError.invalidPackage
        }
        let records: [(String, [String], String)] = [
            ("ProviderInstanceV3", [plan.instanceID], "upsert"),
            ("ProviderModelEntryV3", plan.entryIDs, "upsert"),
            ("ProviderModelGroupV3", plan.groupIDs, "upsert")
        ] + Set(legacyRecordTypes).sorted().map { ($0, ["provider-config"], "upsert") }
        var changes: [Change] = []
        for (type, identifiers, operation) in records where shouldUpload(type) {
            for id in Set(identifiers).sorted() {
                let prior = try read(database, type: type, id: id)
                let now = Date().timeIntervalSince1970
                let timestamp = prior.map { max(now, max($0.createdAt + 0.001, $0.createdAt.nextUp)) } ?? now
                changes.append(.init(previous: prior, proposed: .init(type: type, id: id, zone: zoneName,
                    operation: operation, priority: 0, createdAt: timestamp)))
            }
        }
        let receipt = Receipt(changes: changes)
        try receipt.validate()
        return receipt
    }

    /// 重新核对准备时的队列基线，期间其他写入不得被静默覆盖。
    static func confirm(_ receipt: Receipt, database: OpaquePointer) throws {
        try receipt.validate()
        try NivoSQLiteWrite.transaction(database) {
            for change in receipt.changes {
                guard try read(database, type: change.proposed.type, id: change.proposed.id) == change.previous else {
                    throw NivoPersonalBackupError.snapshotChanged
                }
                try write(change.proposed, database: database)
            }
        }
    }

    /// 只恢复仍与本次提交完全相同的队列条目，不影响后来修改及其他模块。
    static func rollback(_ receipt: Receipt, database: OpaquePointer) throws {
        try receipt.validate()
        try NivoSQLiteWrite.transaction(database) {
            for change in receipt.changes {
                let proposed = change.proposed
                guard try read(database, type: proposed.type, id: proposed.id) == proposed else { continue }
                if let prior = change.previous { try write(prior, database: database) }
                else {
                    try NivoSQLiteWrite.execute(database,
                        sql: "DELETE FROM sync_dirty_records WHERE record_type=? AND record_id=?",
                        values: [.text(proposed.type), .text(proposed.id)])
                }
            }
        }
    }

    /// 冷启动恢复只打开应用传入的固定数据库，不从日志接受磁盘路径。
    static func rollback(_ receipt: Receipt, databaseURL: URL) throws {
        try receipt.validate()
        guard !receipt.changes.isEmpty else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw NivoPersonalBackupError.invalidPackage }
        var database: OpaquePointer?
        defer { if let database { sqlite3_close(database) } }
        let status = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            throw NivoSQLiteWriteError.sqlite(operation: "provider_queue_open", code: status)
        }
        try rollback(receipt, database: database)
    }

    private static func read(_ database: OpaquePointer, type: String, id: String) throws -> Record? {
        try NivoSQLiteWrite.readRow(database, sql: """
            SELECT zone_name, operation, priority, created_at FROM sync_dirty_records
            WHERE record_type=? AND record_id=?
            """, values: [.text(type), .text(id)]) { row in
            guard let zone = sqlite3_column_text(row, 0), let operation = sqlite3_column_text(row, 1),
                  sqlite3_column_type(row, 2) != SQLITE_NULL, sqlite3_column_type(row, 3) != SQLITE_NULL else {
                throw NivoPersonalBackupError.invalidPackage
            }
            return Record(type: type, id: id, zone: String(cString: zone), operation: String(cString: operation),
                priority: sqlite3_column_int64(row, 2), createdAt: sqlite3_column_double(row, 3))
        }
    }

    private static func write(_ record: Record, database: OpaquePointer) throws {
        try NivoSQLiteWrite.execute(database, sql: """
            INSERT OR REPLACE INTO sync_dirty_records
                (record_type, record_id, zone_name, operation, priority, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, values: [.text(record.type), .text(record.id), .text(record.zone), .text(record.operation),
                .integer(record.priority), .real(record.createdAt)])
    }
}
