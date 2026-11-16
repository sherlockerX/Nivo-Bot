import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 在真实SQLite中注入错误，验证预留ID重试、标题保护与删除后的防复活。
final class NivoRelayChatSQLTests: XCTestCase {
    func testReservedSessionReplaysWithSameIdentity() throws {
        try fixture { database in
            XCTAssertEqual(try NivoRelayChatSQL.ensure(request(), database: database), .inserted)
            XCTAssertEqual(try NivoRelayChatSQL.ensure(request(), database: database), .unchanged)
            XCTAssertEqual(try count(database), 1)
        }
    }

    func testCreationFailureLeavesNoSessionAndRetryUsesReservedID() throws {
        try fixture { database in
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_create BEFORE INSERT ON sessions BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoRelayChatSQL.ensure(request(), database: database))
            XCTAssertEqual(try count(database), 0)
            try NivoSQLiteWrite.execute(database, sql: "DROP TRIGGER fail_create")
            XCTAssertEqual(try NivoRelayChatSQL.ensure(request(), database: database), .inserted)
        }
    }

    func testMissingExistingMappingAndDeletedReservationCannotRecreate() throws {
        try fixture { database in
            XCTAssertEqual(try NivoRelayChatSQL.ensure(request(mayCreate: false), database: database), .missing)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO deleted_session_tombstones VALUES ('reserved', 1)")
            XCTAssertEqual(try NivoRelayChatSQL.ensure(request(), database: database), .missing)
            XCTAssertEqual(try count(database), 0)
        }
    }

    func testFailedDirtyRecordRollsBackTitle() throws {
        try fixture { database in
            _ = try NivoRelayChatSQL.ensure(request(), database: database)
            XCTAssertThrowsError(try NivoRelayChatSQL.ensure(request(title: "new", at: 3, mayCreate: false), database: database) {
                throw CocoaError(.fileWriteUnknown)
            })
            let title = try NivoSQLiteWrite.readRow(database, sql: "SELECT title FROM sessions") { String(cString: sqlite3_column_text($0, 0)) }
            XCTAssertEqual(title, "old")
        }
    }

    func testRemoteRenameUsesTitleChangeInsteadOfLocalMessageActivity() throws {
        try fixture { database in
            _ = try NivoRelayChatSQL.ensure(request(at: 10), database: database)
            XCTAssertEqual(try NivoRelayChatSQL.ensure(request(title: "remote", at: 2, mayCreate: false), database: database), .updated)
            let saved = try NivoSQLiteWrite.readRow(database, sql: "SELECT title, updated_at FROM sessions") {
                (String(cString: sqlite3_column_text($0, 0)), sqlite3_column_double($0, 1))
            }
            XCTAssertEqual(saved?.0, "remote")
            XCTAssertEqual(saved?.1, 10)
        }
    }

    func testRemoteClearedTitleAndInitialAdoptionHaveDifferentRules() throws {
        try fixture { database in
            _ = try NivoRelayChatSQL.ensure(request(at: 10), database: database)
            XCTAssertEqual(try NivoRelayChatSQL.ensure(request(title: "remote", at: 12, mayCreate: false, onlyIfUntitled: true), database: database), .unchanged)
            XCTAssertEqual(try NivoRelayChatSQL.ensure(request(title: nil, at: 2, mayCreate: false), database: database), .updated)
            let isNull = try NivoSQLiteWrite.readRow(database, sql: "SELECT title FROM sessions") {
                sqlite3_column_type($0, 0) == SQLITE_NULL
            }
            XCTAssertEqual(isNull, true)
        }
    }

    func testReservationCannotReuseUnrelatedLocalSource() throws {
        try fixture { database in
            _ = try NivoRelayChatSQL.ensure(request(), database: database)
            try NivoSQLiteWrite.execute(database, sql: "UPDATE sessions SET source = 'local'")
            XCTAssertThrowsError(try NivoRelayChatSQL.ensure(request(), database: database))
        }
    }

    private func request(title: String? = "old", at time: Double = 2, mayCreate: Bool = true,
                         onlyIfUntitled: Bool = false) -> NivoRelayChatSQL.Session {
        .init(id: "reserved", title: title, modelID: "model", createdAt: 1, updatedAt: time,
            memoryEnabled: false, mayCreate: mayCreate, updatesTitle: true, onlyIfUntitled: onlyIfUntitled)
    }

    private func fixture(_ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE sessions(id TEXT PRIMARY KEY, title TEXT, model_id TEXT, created_at REAL, updated_at REAL, source TEXT, memory_enabled INTEGER)")
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE deleted_session_tombstones(session_id TEXT PRIMARY KEY, deleted_at REAL)")
        try body(database)
    }

    private func count(_ database: OpaquePointer) throws -> Int32? {
        try NivoSQLiteWrite.readRow(database, sql: "SELECT COUNT(*) FROM sessions") { sqlite3_column_int($0, 0) }
    }
}
