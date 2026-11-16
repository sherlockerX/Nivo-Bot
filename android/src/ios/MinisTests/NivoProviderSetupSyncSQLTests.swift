import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 新增配置的同步登记必须可确认，失败不能留下一半发送队列。
final class NivoProviderSetupSyncSQLTests: XCTestCase {
    func testRollbackRestoresPriorQueueAndRemovesOnlyOwnedNewRecords() throws {
        try fixture { database in
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sync_dirty_records VALUES ('ProviderInstanceV3', 'provider', 'fixture', 'delete', 2, 1)")
            let receipt = try NivoProviderSetupSyncSQL.prepare(plan, database: database, zoneName: "fixture",
                legacyRecordTypes: ["ProviderConfigV2"], shouldUpload: { _ in true })
            try NivoProviderSetupSyncSQL.confirm(receipt, database: database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sync_dirty_records VALUES ('Unrelated', 'keep', 'fixture', 'upsert', 2, 1)")
            try NivoProviderSetupSyncSQL.rollback(receipt, database: database)
            XCTAssertEqual(try count(database), 2)
            let operation = try NivoSQLiteWrite.readRow(database,
                sql: "SELECT operation FROM sync_dirty_records WHERE record_type='ProviderInstanceV3'") {
                String(cString: sqlite3_column_text($0, 0))
            }
            XCTAssertEqual(operation, "delete")
            try NivoProviderSetupSyncSQL.rollback(receipt, database: database)
            XCTAssertEqual(try count(database), 2)
        }
    }

    func testRollbackPreservesQueueRecordChangedLater() throws {
        try fixture { database in
            let receipt = try NivoProviderSetupSyncSQL.prepare(plan, database: database, zoneName: "fixture",
                legacyRecordTypes: [], shouldUpload: { _ in true })
            try NivoProviderSetupSyncSQL.confirm(receipt, database: database)
            try NivoSQLiteWrite.execute(database, sql: "UPDATE sync_dirty_records SET operation='delete', created_at=9000000000 WHERE record_type='ProviderModelEntryV3'")
            try NivoProviderSetupSyncSQL.rollback(receipt, database: database)
            XCTAssertEqual(try count(database), 1)
        }
    }

    func testPrepareAndConfirmRefuseAnInterveningQueueWrite() throws {
        try fixture { database in
            let receipt = try NivoProviderSetupSyncSQL.prepare(plan, database: database, zoneName: "fixture",
                legacyRecordTypes: [], shouldUpload: { _ in true })
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sync_dirty_records VALUES ('ProviderModelGroupV3', 'group', 'fixture', 'delete', 2, 1)")
            XCTAssertThrowsError(try NivoProviderSetupSyncSQL.confirm(receipt, database: database))
            XCTAssertEqual(try count(database), 1)
        }
    }

    func testEmptiedGroupIsRecordedWithoutInferringRemoteModelDeletion() throws {
        try fixture { database in
            let changed = NivoProviderSetupSyncSQL.Plan(instanceID: "provider", entryIDs: [], groupIDs: ["empty-group"])
            let receipt = try NivoProviderSetupSyncSQL.prepare(changed, database: database, zoneName: "fixture",
                legacyRecordTypes: [], shouldUpload: { _ in true })
            try NivoProviderSetupSyncSQL.confirm(receipt, database: database)
            XCTAssertEqual(try count(database), 2)
            let deletion = try NivoSQLiteWrite.readRow(database,
                sql: "SELECT operation FROM sync_dirty_records WHERE operation='delete'") {
                String(cString: sqlite3_column_text($0, 0))
            }
            XCTAssertNil(deletion)
            try NivoProviderSetupSyncSQL.rollback(receipt, database: database)
            XCTAssertEqual(try count(database), 0)
        }
    }

    func testNewProviderQueuesModelsAndGroupsInOneTransaction() throws {
        try fixture { database in
            try confirm(database)
            XCTAssertEqual(try count(database), 5)
        }
    }

    func testLastRecordFailurePreservesExistingQueueAndRollsBackNewRecords() throws {
        try fixture { database in
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sync_dirty_records VALUES ('Unrelated', 'keep', 'fixture', 'delete', 2, 1)")
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_setup BEFORE INSERT ON sync_dirty_records WHEN NEW.record_type='ProviderConfigV2' BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try confirm(database))
            XCTAssertEqual(try count(database), 1)
            try NivoSQLiteWrite.execute(database, sql: "DROP TRIGGER fail_setup")
            try confirm(database)
            XCTAssertEqual(try count(database), 6)
        }
    }

    func testDisabledProviderUploadDoesNotCreateQueueRows() throws {
        try fixture { database in
            try NivoProviderSetupSyncSQL.confirm(plan, database: database, zoneName: "fixture",
                legacyRecordTypes: ["ProviderConfigV2"], shouldUpload: { _ in false })
            XCTAssertEqual(try count(database), 0)
        }
    }

    func testV2OnlyNeverQueuesInactiveV1() throws {
        try fixture { database in
            try NivoProviderSetupSyncSQL.confirm(plan, database: database, zoneName: "fixture",
                legacyRecordTypes: ["ProviderConfigV2"], shouldUpload: { _ in true })
            XCTAssertEqual(try count(database), 4)
            let hasLegacy = try NivoSQLiteWrite.readRow(database,
                sql: "SELECT 1 FROM sync_dirty_records WHERE record_type='ProviderConfig'") { _ in true } ?? false
            XCTAssertFalse(hasLegacy)
        }
    }

    private var plan: NivoProviderSetupSyncSQL.Plan {
        .init(instanceID: "provider", entryIDs: ["model"], groupIDs: ["group"])
    }

    private func confirm(_ database: OpaquePointer) throws {
        try NivoProviderSetupSyncSQL.confirm(plan, database: database, zoneName: "fixture",
            legacyRecordTypes: ["ProviderConfig", "ProviderConfigV2"], shouldUpload: { _ in true })
    }

    private func count(_ database: OpaquePointer) throws -> Int {
        try NivoSQLiteWrite.readRow(database, sql: "SELECT COUNT(*) FROM sync_dirty_records") { Int(sqlite3_column_int($0, 0)) } ?? 0
    }

    private func fixture(_ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE sync_dirty_records(record_type TEXT, record_id TEXT, zone_name TEXT, operation TEXT, priority INTEGER, created_at REAL, PRIMARY KEY(record_type,record_id))")
        try body(database)
    }
}
