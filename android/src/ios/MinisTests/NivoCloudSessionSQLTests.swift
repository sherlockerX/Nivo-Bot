import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 真实SQLite故障注入验证会话元数据、消息补入与接收重试边界。
final class NivoCloudSessionSQLTests: XCTestCase {
    func testBackfillFailureRollsBackExistingTitleFolderPinAndRevision() throws {
        try fixture { database in
            try NivoCloudSessionSQL.merge(session(at: 1, title: "原始", folder: "old", pin: 1), database: database)
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_message BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoCloudSessionSQL.merge(session(at: 2, title: "新标题", folder: "new", pin: 2),
                backfill: [message()], database: database))
            XCTAssertEqual(try text(database, "SELECT title FROM sessions"), "原始")
            XCTAssertEqual(try text(database, "SELECT folder_id FROM sessions"), "old")
            XCTAssertEqual(try number(database, "SELECT updated_at FROM sessions"), 1)
            XCTAssertEqual(try number(database, "SELECT pinned_at FROM sessions"), 1)
            XCTAssertEqual(try number(database, "SELECT count(*) FROM messages"), 0)
        }
    }

    func testBackfillFailureDoesNotLeaveNewEmptySession() throws {
        try fixture { database in
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_message BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoCloudSessionSQL.merge(session(at: 1), backfill: [message()], database: database))
            XCTAssertEqual(try number(database, "SELECT count(*) FROM sessions"), 0)
            try NivoSQLiteWrite.execute(database, sql: "DROP TRIGGER fail_message")
            XCTAssertEqual(try NivoCloudSessionSQL.merge(session(at: 1), backfill: [message()], database: database), .inserted)
            XCTAssertEqual(try NivoCloudSessionSQL.merge(session(at: 1), backfill: [message()], database: database), .unchanged)
            XCTAssertEqual(try number(database, "SELECT count(*) FROM messages"), 1)
        }
    }

    func testMetadataReadAndWriteFailuresCannotBeAcknowledged() throws {
        try fixture { database in
            try NivoCloudSessionSQL.merge(session(at: 1, title: "原始"), database: database)
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_update BEFORE UPDATE ON sessions BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoCloudSessionSQL.merge(session(at: 2), database: database))
            XCTAssertEqual(try text(database, "SELECT title FROM sessions"), "原始")
            try NivoSQLiteWrite.execute(database, sql: "ALTER TABLE sessions RENAME COLUMN pinned_at TO broken_pin")
            XCTAssertThrowsError(try NivoCloudSessionSQL.merge(session(at: 2), database: database))
            XCTAssertEqual(try number(database, "SELECT count(*) FROM sessions"), 1)
        }
    }

    func testOlderMetadataDoesNotOverwriteTitleButCanFillUnassignedOrganization() throws {
        try fixture { database in
            try NivoCloudSessionSQL.merge(session(at: 5, title: "本机"), database: database)
            XCTAssertEqual(try NivoCloudSessionSQL.merge(session(at: 2, title: "旧标题", folder: "remote", pin: 4), database: database), .updated)
            XCTAssertEqual(try text(database, "SELECT title FROM sessions"), "本机")
            XCTAssertEqual(try number(database, "SELECT updated_at FROM sessions"), 5)
            XCTAssertEqual(try text(database, "SELECT folder_id FROM sessions"), "remote")
            XCTAssertEqual(try number(database, "SELECT pinned_at FROM sessions"), 4)
            XCTAssertEqual(try NivoCloudSessionSQL.merge(session(at: 2, folder: "other", pin: 0), database: database), .unchanged)
        }
    }

    func testLegacyFolderOmissionPreservesMembershipAndExplicitClearAppliesWhenNewer() throws {
        try fixture { database in
            try NivoCloudSessionSQL.merge(session(at: 1, folder: "practice", pin: 1), database: database)
            try NivoCloudSessionSQL.merge(session(at: 2, hasFolder: false), database: database)
            XCTAssertEqual(try text(database, "SELECT folder_id FROM sessions"), "practice")
            XCTAssertEqual(try number(database, "SELECT pinned_at FROM sessions"), 1)
            try NivoCloudSessionSQL.merge(session(at: 3), database: database)
            XCTAssertNil(try text(database, "SELECT folder_id FROM sessions"))
            XCTAssertEqual(try text(database, "SELECT model_id FROM sessions"), "local-model")
            XCTAssertEqual(try number(database, "SELECT created_at FROM sessions"), 1)
        }
    }

    func testDeletedSessionCannotBeResurrectedAndFailedTombstoneReadThrows() throws {
        try fixture { database in
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO deleted_session_tombstones VALUES ('chat', 10)")
            XCTAssertEqual(try NivoCloudSessionSQL.merge(session(at: 10), backfill: [message()], database: database), .unchanged)
            XCTAssertEqual(try number(database, "SELECT count(*) FROM sessions"), 0)
            XCTAssertEqual(try NivoCloudSessionSQL.merge(session(at: 16), database: database), .inserted)
            try NivoSQLiteWrite.execute(database, sql: "DELETE FROM sessions")
            try NivoSQLiteWrite.execute(database, sql: "DROP TABLE deleted_session_tombstones")
            XCTAssertThrowsError(try NivoCloudSessionSQL.merge(session(at: 20), database: database))
        }
    }

    func testBackfillOwnerCollisionRollsBackMetadataAndDoesNotOverwriteOtherChat() throws {
        try fixture { database in
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id, updated_at) VALUES ('other', 1)")
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO messages(id, session_id, parts_json, updated_at) VALUES ('message', 'other', 'original', 1)")
            XCTAssertThrowsError(try NivoCloudSessionSQL.merge(session(at: 2), backfill: [message()], database: database)) {
                XCTAssertEqual($0 as? NivoCloudChatSQLError, .messageOwnerChanged)
            }
            XCTAssertEqual(try number(database, "SELECT count(*) FROM sessions"), 1)
            XCTAssertEqual(try text(database, "SELECT parts_json FROM messages"), "original")
        }
    }

    func testReferenceReplayPreservesNewerMetadataAndWriteFailuresPropagate() throws {
        try fixture { database in
            try NivoCloudSessionSQL.mergeReference(session(at: 3, title: "新"), database: database)
            try NivoCloudSessionSQL.mergeReference(session(at: 1, title: "旧"), database: database)
            XCTAssertEqual(try text(database, "SELECT title FROM remote_sessions"), "新")
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_reference BEFORE UPDATE ON remote_sessions BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoCloudSessionSQL.mergeReference(session(at: 4), database: database))
            XCTAssertEqual(try number(database, "SELECT updated_at FROM remote_sessions"), 3)
        }
    }

    func testInvalidTimeAndForeignBackfillAreRejectedBeforeAnyWrite() throws {
        try fixture { database in
            XCTAssertThrowsError(try NivoCloudSessionSQL.merge(session(at: .infinity), database: database))
            let foreign = NivoCloudChatSQL.Message(id: "foreign", sessionID: "other", role: "user", partsJSON: "[]", createdAt: 1,
                usageJSON: nil, reasoning: nil, interruptCount: 0, updatedAt: 1, partFlags: 0)
            XCTAssertThrowsError(try NivoCloudSessionSQL.merge(session(at: 1), backfill: [foreign], database: database))
            XCTAssertEqual(try number(database, "SELECT count(*) FROM sessions"), 0)
            XCTAssertThrowsError(try NivoCloudChatSQL.mergeMessageInTransaction(message(), database: database))
        }
    }

    private func session(at updatedAt: Double, title: String = "标题", folder: String? = nil,
                         pin: Double? = nil, hasFolder: Bool = true) -> NivoCloudSessionSQL.Session {
        .init(id: "chat", title: title, category: nil, modelID: "local-model", createdAt: 1,
            updatedAt: updatedAt, sourceDeviceID: "fixture-device", memoryEnabled: false, modelBinding: nil,
            rawPinnedAt: pin, folderID: folder, hasFolderField: hasFolder)
    }

    private func message() -> NivoCloudChatSQL.Message {
        .init(id: "message", sessionID: "chat", role: "user", partsJSON: "[]", createdAt: 1,
            usageJSON: nil, reasoning: nil, interruptCount: 0, updatedAt: 1, partFlags: 0)
    }

    private func fixture(_ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        let schema = [
            "CREATE TABLE sessions(id TEXT PRIMARY KEY, title TEXT, category TEXT, model_id TEXT, created_at REAL, updated_at REAL, remote_origin_device_id TEXT, memory_enabled INTEGER, model_binding TEXT, pinned_at REAL, folder_id TEXT)",
            "CREATE TABLE messages(id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT, parts_json TEXT, created_at REAL, token_usage TEXT, sort_order INTEGER, reasoning_content TEXT, stream_interrupt_count INTEGER, updated_at REAL, part_flags INTEGER, model_id TEXT, model_display_name TEXT, provider_type TEXT, provider_instance_id TEXT)",
            "CREATE TABLE deleted_session_tombstones(session_id TEXT PRIMARY KEY, deleted_at REAL)",
            "CREATE TABLE deleted_record_tombstones(record_type TEXT, record_id TEXT, deleted_at REAL, PRIMARY KEY(record_type, record_id))",
            "CREATE TABLE remote_sessions(id TEXT, device_id TEXT, title TEXT, category TEXT, model_id TEXT, created_at REAL, updated_at REAL, PRIMARY KEY(id, device_id))",
        ]
        for sql in schema { try NivoSQLiteWrite.execute(database, sql: sql) }
        try body(database)
    }

    private func text(_ database: OpaquePointer, _ sql: String) throws -> String? {
        try NivoSQLiteWrite.readRow(database, sql: sql) { sqlite3_column_text($0, 0).map { String(cString: $0) } } ?? nil
    }

    private func number(_ database: OpaquePointer, _ sql: String) throws -> Double {
        try XCTUnwrap(try NivoSQLiteWrite.readRow(database, sql: sql) { sqlite3_column_double($0, 0) })
    }
}
