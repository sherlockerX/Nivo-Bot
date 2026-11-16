import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 用真实SQLite触发器注入队列写入失败，验证回执不能提前确认。
final class NivoEnvVarSyncSQLTests: XCTestCase {
    func testDirtyFailureRollsBackDeletionAndReceiptThenCanRetry() throws {
        try fixture { database in
            let journal = journal()
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_dirty BEFORE INSERT ON sync_dirty_records BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoEnvVarSyncSQL.confirm(journal, database: database, zoneName: "fixture", shouldUpload: true))
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 0)
            try NivoSQLiteWrite.execute(database, sql: "DROP TRIGGER fail_dirty")
            try NivoEnvVarSyncSQL.confirm(journal, database: database, zoneName: "fixture", shouldUpload: true)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 2)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 1)
        }
    }

    func testReplayDoesNotReplaceNewerPendingOperation() throws {
        try fixture { database in
            let journal = journal()
            try NivoEnvVarSyncSQL.confirm(journal, database: database, zoneName: "fixture", shouldUpload: true)
            try NivoSQLiteWrite.execute(database, sql: "UPDATE sync_dirty_records SET operation='upsert'")
            try NivoEnvVarSyncSQL.confirm(journal, database: database, zoneName: "fixture", shouldUpload: true)
            let operation = try NivoSQLiteWrite.readRow(database, sql: "SELECT operation FROM sync_dirty_records") {
                String(cString: sqlite3_column_text($0, 0))
            }
            XCTAssertEqual(operation, "upsert")
        }
    }

    func testDisabledUploadRetainsLocalDeletionProtection() throws {
        try fixture { database in
            try NivoEnvVarSyncSQL.confirm(journal(), database: database, zoneName: "fixture", shouldUpload: false)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 2)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
        }
    }

    func testDeletionProtectionCoversFutureDatedOriginal() throws {
        try fixture { database in
            try NivoEnvVarSyncSQL.confirm(journal(), database: database, zoneName: "fixture", shouldUpload: true)
            let timestamp = try NivoSQLiteWrite.readRow(database, sql: "SELECT deleted_at FROM deleted_record_tombstones WHERE record_type='EnvVarItem'") {
                sqlite3_column_double($0, 0)
            }
            XCTAssertEqual(timestamp, 100)
        }
    }

    private func journal() -> NivoEnvVarTransaction.Journal {
        .init(identifier: UUID(), phase: .awaitingSync,
              before: [EnvVarEntry(id: "fixture", key: "FIXTURE", createdAt: Date(timeIntervalSince1970: 100))],
              after: [], writeKey: nil, notifySync: true, createdAt: Date(timeIntervalSince1970: 10))
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
