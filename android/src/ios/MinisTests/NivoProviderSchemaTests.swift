import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 执行生产迁移代码，验证首次安装、历史补列、失败回滚和版本边界。
final class NivoProviderSchemaTests: XCTestCase {
    func testFirstMigrationIncludesAllTablesAndHistoryColumnsBeforeReopen() throws {
        try withDatabase { database in
            try NivoProviderSchema.migrate(database)
            XCTAssertEqual(try integer(database, "PRAGMA user_version"), 2)
            XCTAssertEqual(try integer(database, "SELECT count(*) FROM sqlite_master WHERE type='table'"), 8)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO provider_model_groups (id,name,strategy,fallback_strategy,member_entry_ids_json,updated_at) VALUES ('group','fixture','fallback','limited','[]',1)")
            let history = try NivoSQLiteWrite.readRow(database,
                sql: "SELECT added_members_json, removed_members_json FROM provider_model_groups") {
                    (String(cString: sqlite3_column_text($0, 0)), String(cString: sqlite3_column_text($0, 1)))
                }
            XCTAssertEqual(history?.0, "{}")
            XCTAssertEqual(history?.1, "{}")
        }
    }

    func testSecondMigrationKeepsExistingData() throws {
        try withDatabase { database in
            try NivoProviderSchema.migrate(database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO provider_local_kv VALUES ('legacyUuidMap','keep')")
            try NivoProviderSchema.migrate(database)
            XCTAssertEqual(try integer(database, "SELECT count(*) FROM provider_local_kv WHERE value='keep'"), 1)
        }
    }

    func testExistingVersionTwoRepairsMissingHistoricalColumnsWithoutDroppingRows() throws {
        try withDatabase { database in
            try createLegacyFixture(database)
            try NivoSQLiteWrite.execute(database, sql: "PRAGMA user_version=2")
            try NivoProviderSchema.migrate(database)
            XCTAssertEqual(try integer(database, "SELECT count(*) FROM provider_model_groups WHERE id='keep' AND added_members_json='{}' AND removed_members_json='{}'"), 1)
            XCTAssertEqual(try integer(database, "SELECT azure_mode FROM provider_instances WHERE id='keep'"), 0)
        }
    }

    func testMigrationFailureRollsBackNewTablesAndDoesNotStampVersion() throws {
        try withDatabase { database in
            try NivoSQLiteWrite.execute(database, sql: "CREATE VIEW provider_model_groups AS SELECT 'invalid' AS id")
            XCTAssertThrowsError(try NivoProviderSchema.migrate(database))
            XCTAssertEqual(try integer(database, "PRAGMA user_version"), 0)
            XCTAssertEqual(try integer(database, "SELECT count(*) FROM sqlite_master WHERE type='table'"), 0)
            XCTAssertEqual(try integer(database, "SELECT count(*) FROM provider_model_groups"), 1)
        }
    }

    func testLegacyRepairFailureRollsBackEarlierAddedColumns() throws {
        try withDatabase { database in
            try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE provider_instances(id TEXT PRIMARY KEY)")
            try NivoSQLiteWrite.execute(database, sql: "PRAGMA user_version=1")
            XCTAssertThrowsError(try NivoProviderSchema.migrate(database))
            XCTAssertEqual(try integer(database, "PRAGMA user_version"), 1)
            let columns = try NivoSQLiteWrite.readRows(database, sql: "PRAGMA table_info(provider_instances)") {
                String(cString: sqlite3_column_text($0, 1))
            }
            XCTAssertEqual(columns, ["id"])
        }
    }

    func testFutureVersionIsNotDowngraded() throws {
        try withDatabase { database in
            try NivoProviderSchema.migrate(database)
            try NivoSQLiteWrite.execute(database, sql: "PRAGMA user_version=99")
            try NivoProviderSchema.migrate(database)
            XCTAssertEqual(try integer(database, "PRAGMA user_version"), 99)
        }
    }

    private func createLegacyFixture(_ database: OpaquePointer) throws {
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE provider_instances(id TEXT PRIMARY KEY)")
        try NivoSQLiteWrite.execute(database, sql: "INSERT INTO provider_instances VALUES ('keep')")
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE provider_model_groups(id TEXT PRIMARY KEY)")
        try NivoSQLiteWrite.execute(database, sql: "INSERT INTO provider_model_groups VALUES ('keep')")
    }

    private func integer(_ database: OpaquePointer, _ sql: String) throws -> Int64? {
        try NivoSQLiteWrite.readRow(database, sql: sql) { sqlite3_column_int64($0, 0) }
    }

    private func withDatabase(_ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open(":memory:", &pointer)
        guard result == SQLITE_OK, let database = pointer else { throw NivoPersonalBackupError.invalidPackage }
        defer { sqlite3_close(database) }
        try body(database)
    }
}
