import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 长时间未打开应用后恢复，不能因清理过期墓碑而丢失事务幂等保护。
final class NivoSyncReceiptRetentionTests: XCTestCase {
    func testPruningKeepsTransactionReceiptsAndRecentTombstones() throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE deleted_record_tombstones(record_type TEXT, record_id TEXT, deleted_at REAL)")
        for type in ["RelayConversation", "ProviderDeletionTransaction", "EnvVarTransaction", "ProviderInstanceV3"] {
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO deleted_record_tombstones VALUES (?, 'old', 1)", values: [.text(type)])
        }
        try NivoSQLiteWrite.execute(database, sql: "INSERT INTO deleted_record_tombstones VALUES ('ProviderInstanceV3', 'recent', 100)")
        try NivoSyncReceiptRetention.prune(database: database, before: Date(timeIntervalSince1970: 50))
        let types = try NivoSQLiteWrite.readRows(database, sql: "SELECT record_type FROM deleted_record_tombstones ORDER BY record_type") {
            String(cString: sqlite3_column_text($0, 0))
        }
        XCTAssertEqual(types, ["EnvVarTransaction", "ProviderDeletionTransaction", "ProviderInstanceV3", "RelayConversation"])
    }
}
