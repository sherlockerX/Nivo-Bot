import Foundation

/// 将提供商删除、关联记录、旧协议快照和恢复回执放入同一SQLite事务。
enum NivoProviderDeletionSyncSQL {
    /// 本地防复活标记不受上传开关影响；回执已确认时不覆盖后续排队操作。
    static func confirm(_ journal: NivoProviderDeletion.Journal, database: OpaquePointer,
                        zoneName: String, legacyRecordTypes: [String] = ["ProviderConfig", "ProviderConfigV2"],
                        shouldUpload: (String) -> Bool) throws {
        try journal.validate()
        guard journal.phase == .committed, !zoneName.isEmpty,
              Set(legacyRecordTypes).isSubset(of: ["ProviderConfig", "ProviderConfigV2"]) else {
            throw NivoProviderDeletion.Failure.invalidJournal
        }
        try NivoSQLiteWrite.transaction(database) {
            let hasReceipt = try NivoSQLiteWrite.readRow(database, sql: """
                SELECT 1 FROM deleted_record_tombstones
                WHERE record_type = 'ProviderDeletionTransaction' AND record_id = ?
                """, values: [.text(journal.identifier.uuidString)]) { _ in true } ?? false
            guard !hasReceipt else { return }
            let plan = journal.plan
            try recordDeletions(plan, database: database, zoneName: zoneName, shouldUpload: shouldUpload)
            if shouldUpload("ProviderModelGroupV3") {
                for id in plan.updatedGroupIDs {
                    try enqueue(database, type: "ProviderModelGroupV3", id: id, operation: "upsert", zone: zoneName, date: plan.deletedAt)
                }
            }
            for type in Set(legacyRecordTypes).sorted() where shouldUpload(type) {
                try enqueue(database, type: type, id: "provider-config", operation: "upsert", zone: zoneName, date: plan.deletedAt)
            }
            try recordReceipt(database, type: "ProviderDeletionTransaction", id: journal.identifier.uuidString, date: plan.deletedAt)
        }
    }

    private static func recordDeletions(_ plan: NivoProviderDeletion.Plan, database: OpaquePointer,
                                        zoneName: String, shouldUpload: (String) -> Bool) throws {
        let deletedRecords: [(String, [String])] = [
            ("ProviderInstanceV3", [plan.instanceID]),
            ("ProviderModelEntryV3", Array(Set(plan.entryIDs + plan.entryUUIDs)).sorted()),
            ("ProviderModelGroupV3", plan.groupIDs),
            ("ProviderThinkingRuleV3", plan.ruleIDs)
        ]
        for (type, identifiers) in deletedRecords {
            for id in identifiers {
                try recordReceipt(database, type: type, id: id, date: plan.deletedAt)
                if shouldUpload(type) {
                    try enqueue(database, type: type, id: id, operation: "delete", zone: zoneName, date: plan.deletedAt)
                }
            }
        }
    }

    private static func recordReceipt(_ database: OpaquePointer, type: String, id: String, date: Date) throws {
        try NivoSQLiteWrite.execute(database, sql: """
            INSERT INTO deleted_record_tombstones(record_type, record_id, deleted_at) VALUES (?, ?, ?)
            ON CONFLICT(record_type, record_id) DO UPDATE SET deleted_at = MAX(deleted_at, excluded.deleted_at)
            """, values: [.text(type), .text(id), .real(date.timeIntervalSince1970)])
    }

    private static func enqueue(_ database: OpaquePointer, type: String, id: String, operation: String,
                                zone: String, date: Date) throws {
        try NivoSQLiteWrite.execute(database, sql: """
            INSERT OR REPLACE INTO sync_dirty_records
                (record_type, record_id, zone_name, operation, priority, created_at)
            VALUES (?, ?, ?, ?, 0, ?)
            """, values: [.text(type), .text(id), .text(zone), .text(operation), .real(date.timeIntervalSince1970)])
    }
}
