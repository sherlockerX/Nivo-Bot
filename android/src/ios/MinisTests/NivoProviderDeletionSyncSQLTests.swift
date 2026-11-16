import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 在真实SQLite数据库注入末尾队列和回执错误，验证不能只确认部分删除。
final class NivoProviderDeletionSyncSQLTests: XCTestCase {
    func testQueuesAllDeletedIdentitiesAndUpdatedGroupTogether() throws {
        try fixture { database in
            try NivoProviderDeletionSyncSQL.confirm(journal(), database: database, zoneName: "fixture", shouldUpload: { _ in true })
            XCTAssertEqual(try count(database, "sync_dirty_records"), 8)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 6)
            XCTAssertEqual(try operation(database, type: "ProviderModelEntryV3", id: "entry-uuid"), "delete")
            XCTAssertEqual(try operation(database, type: "ProviderModelEntryV3", id: "provider/model"), "delete")
            XCTAssertEqual(try operation(database, type: "ProviderModelGroupV3", id: "remaining-group"), "upsert")
        }
    }

    func testLateQueueFailureRollsBackAllRowsAndCanRetry() throws {
        try fixture { database in
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_queue BEFORE INSERT ON sync_dirty_records WHEN NEW.record_type='ProviderConfigV2' BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoProviderDeletionSyncSQL.confirm(journal(), database: database, zoneName: "fixture", shouldUpload: { _ in true }))
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 0)
            try NivoSQLiteWrite.execute(database, sql: "DROP TRIGGER fail_queue")
            try NivoProviderDeletionSyncSQL.confirm(journal(), database: database, zoneName: "fixture", shouldUpload: { _ in true })
            XCTAssertEqual(try count(database, "sync_dirty_records"), 8)
        }
    }

    func testReceiptFailureRollsBackDeletionQueue() throws {
        try fixture { database in
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_receipt BEFORE INSERT ON deleted_record_tombstones WHEN NEW.record_type='ProviderDeletionTransaction' BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoProviderDeletionSyncSQL.confirm(journal(), database: database, zoneName: "fixture", shouldUpload: { _ in true }))
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 0)
        }
    }

    func testReplayDoesNotOverwriteLaterQueueOperation() throws {
        try fixture { database in
            let receipt = journal()
            try NivoProviderDeletionSyncSQL.confirm(receipt, database: database, zoneName: "fixture", shouldUpload: { _ in true })
            try NivoSQLiteWrite.execute(database, sql: "UPDATE sync_dirty_records SET operation='upsert' WHERE record_type='ProviderInstanceV3'")
            try NivoProviderDeletionSyncSQL.confirm(receipt, database: database, zoneName: "fixture", shouldUpload: { _ in true })
            XCTAssertEqual(try operation(database, type: "ProviderInstanceV3", id: "provider"), "upsert")
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 6)
        }
    }

    func testDisabledUploadStillProtectsDeletionLocally() throws {
        try fixture { database in
            try NivoProviderDeletionSyncSQL.confirm(journal(), database: database, zoneName: "fixture", shouldUpload: { _ in false })
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 6)
        }
    }

    func testV2OnlyDoesNotLeaveUnconsumedLegacyQueue() throws {
        try fixture { database in
            try NivoProviderDeletionSyncSQL.confirm(journal(), database: database, zoneName: "fixture",
                legacyRecordTypes: ["ProviderConfigV2"], shouldUpload: { _ in true })
            XCTAssertNil(try operation(database, type: "ProviderConfig", id: "provider-config"))
            XCTAssertEqual(try operation(database, type: "ProviderConfigV2", id: "provider-config"), "upsert")
            XCTAssertEqual(try count(database, "sync_dirty_records"), 7)
        }
    }

    func testUncommittedJournalCannotBeAcknowledged() throws {
        try fixture { database in
            var uncommitted = journal()
            uncommitted.phase = .staged
            XCTAssertThrowsError(try NivoProviderDeletionSyncSQL.confirm(uncommitted, database: database, zoneName: "fixture", shouldUpload: { _ in true }))
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 0)
        }
    }

    private func journal() -> NivoProviderDeletion.Journal {
        .init(identifier: UUID(), phase: .committed, plan: .init(instanceID: "provider", entryIDs: ["provider/model"],
            entryUUIDs: ["entry-uuid"], groupIDs: ["removed-group"], updatedGroupIDs: ["remaining-group"],
            ruleIDs: ["rule"], deletedAt: Date(timeIntervalSince1970: 100)))
    }

    private func operation(_ database: OpaquePointer, type: String, id: String) throws -> String? {
        try NivoSQLiteWrite.readRow(database, sql: "SELECT operation FROM sync_dirty_records WHERE record_type=? AND record_id=?",
            values: [.text(type), .text(id)]) { String(cString: sqlite3_column_text($0, 0)) }
    }

    private func count(_ database: OpaquePointer, _ table: String) throws -> Int {
        try NivoSQLiteWrite.readRow(database, sql: "SELECT COUNT(*) FROM \(table)") { Int(sqlite3_column_int($0, 0)) } ?? 0
    }

    private func fixture(_ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE deleted_record_tombstones(record_type TEXT, record_id TEXT, deleted_at REAL, PRIMARY KEY(record_type,record_id))")
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE sync_dirty_records(record_type TEXT, record_id TEXT, zone_name TEXT, operation TEXT, priority INTEGER, created_at REAL, PRIMARY KEY(record_type,record_id))")
        try body(database)
    }
}
