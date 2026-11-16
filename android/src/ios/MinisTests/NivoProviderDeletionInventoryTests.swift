import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 删除版本必须覆盖受影响分组的字段版本，避免回拨时旧组重新出现。
final class NivoProviderDeletionInventoryTests: XCTestCase {
    func testAffectedGroupVersionAdvancesDeletionClock() throws {
        try fixture { database in
            let result = try NivoProviderDeletionInventory.read(database: database, instanceID: "provider", groupIDs: ["affected"])
            XCTAssertGreaterThan(result.lastModified.timeIntervalSince1970, 900)
            XCTAssertLessThan(result.lastModified.timeIntervalSince1970, 901)
            XCTAssertEqual(result.ruleIDs, ["future-rule"])
        }
    }

    func testUnrelatedGroupDoesNotAdvanceDeletionClock() throws {
        try fixture { database in
            let result = try NivoProviderDeletionInventory.read(database: database, instanceID: "provider", groupIDs: [])
            XCTAssertGreaterThan(result.lastModified.timeIntervalSince1970, 300)
            XCTAssertLessThan(result.lastModified.timeIntervalSince1970, 301)
        }
    }

    func testMissingTableCannotBeTreatedAsEmptyInventory() throws {
        try fixture { database in
            try NivoSQLiteWrite.execute(database, sql: "DROP TABLE provider_thinking_rules")
            XCTAssertThrowsError(try NivoProviderDeletionInventory.read(database: database, instanceID: "provider", groupIDs: []))
        }
    }

    private func fixture(_ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        for sql in [
            "CREATE TABLE provider_instances(id TEXT PRIMARY KEY, updated_at REAL)",
            "CREATE TABLE provider_model_entries(id TEXT PRIMARY KEY, provider_instance_id TEXT, updated_at REAL)",
            "CREATE TABLE provider_thinking_rules(id TEXT PRIMARY KEY, instance_id TEXT, updated_at REAL)",
            "CREATE TABLE provider_model_groups(id TEXT PRIMARY KEY, updated_at REAL)",
            "INSERT INTO provider_instances VALUES ('provider', 100)",
            "INSERT INTO provider_model_entries VALUES ('entry', 'provider', 200)",
            "INSERT INTO provider_thinking_rules VALUES ('future-rule', 'provider', 300)",
            "INSERT INTO provider_model_groups VALUES ('affected', 900), ('unrelated', 2000)"
        ] { try NivoSQLiteWrite.execute(database, sql: sql) }
        try body(database)
    }
}
