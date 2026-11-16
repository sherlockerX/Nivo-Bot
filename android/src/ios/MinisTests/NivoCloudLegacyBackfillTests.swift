import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 旧参考表回填在真实SQLite中注入失败，完成标记必须和导入结果共同提交。
final class NivoCloudLegacyBackfillTests: XCTestCase {
    func testMessageFailureRollsBackSessionsAndCompletionThenRetriesOnce() throws {
        try fixture { database in
            try seed(database)
            try execute(database, "CREATE TRIGGER fail_message BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try run(database))
            XCTAssertEqual(try count(database, "sessions"), 0)
            XCTAssertFalse(try NivoCloudLegacyBackfill.isComplete(database: database))
            XCTAssertEqual(try count(database, "remote_messages"), 1)
            try execute(database, "DROP TRIGGER fail_message")
            let result = try run(database)
            XCTAssertEqual(result.sessions, 1)
            XCTAssertEqual(result.messages, 1)
            XCTAssertTrue(try NivoCloudLegacyBackfill.isComplete(database: database))
            XCTAssertTrue(try run(database).alreadyCompleted)
            XCTAssertEqual(try count(database, "messages"), 1)
        }
    }

    func testSessionAndMessageTombstonesPreventResurrection() throws {
        try fixture { database in
            try seed(database)
            try execute(database, "INSERT INTO deleted_session_tombstones VALUES ('chat', 10)")
            let result = try run(database)
            XCTAssertEqual(result.sessions, 0)
            XCTAssertEqual(result.messages, 0)
            XCTAssertEqual(try count(database, "sessions"), 0)
        }
        try fixture { database in
            try seed(database)
            try execute(database, "INSERT INTO deleted_record_tombstones VALUES ('Message', 'message', 10)")
            let result = try run(database)
            XCTAssertEqual(result.sessions, 1)
            XCTAssertEqual(result.messages, 0)
        }
    }

    func testExistingLocalMetadataAndMessagesAreNeverReplacedByReferenceCopies() throws {
        try fixture { database in
            try seed(database)
            try execute(database, "INSERT INTO sessions(id, title, updated_at) VALUES ('chat', 'local title', 1)")
            try execute(database, "INSERT INTO messages(id, session_id, role, parts_json, created_at, updated_at) VALUES ('message', 'chat', 'user', 'local body', 1, 1)")
            let result = try run(database)
            XCTAssertEqual(result.sessions, 0)
            XCTAssertEqual(result.messages, 0)
            XCTAssertEqual(try text(database, "SELECT title FROM sessions"), "local title")
            XCTAssertEqual(try text(database, "SELECT parts_json FROM messages"), "local body")
        }
    }

    func testMissingParentDoesNotMarkMigrationComplete() throws {
        try fixture { database in
            try seed(database)
            try execute(database, "DELETE FROM remote_sessions")
            XCTAssertThrowsError(try run(database)) {
                XCTAssertEqual($0 as? NivoCloudChatSQLError, .missingSession)
            }
            XCTAssertFalse(try NivoCloudLegacyBackfill.isComplete(database: database))
            XCTAssertEqual(try count(database, "messages"), 0)
        }
    }

    func testBodyValidationFailureRollsBackAllImportedSessions() throws {
        try fixture { database in
            try seed(database)
            try execute(database, "UPDATE remote_messages SET parts_json = 'broken'")
            XCTAssertThrowsError(try run(database))
            XCTAssertEqual(try count(database, "sessions"), 0)
            XCTAssertFalse(try NivoCloudLegacyBackfill.isComplete(database: database))
        }
    }

    func testDeletedMalformedMessageDoesNotBlockRemainingMigration() throws {
        try fixture { database in
            try seed(database)
            try execute(database, "UPDATE remote_messages SET parts_json = 'broken'")
            try execute(database, "INSERT INTO deleted_record_tombstones VALUES ('Message', 'message', 10)")
            let result = try run(database)
            XCTAssertEqual(result.sessions, 1)
            XCTAssertEqual(result.messages, 0)
            XCTAssertTrue(try NivoCloudLegacyBackfill.isComplete(database: database))
        }
    }

    func testReadAndCompletionWriteFailuresRemainRetryable() throws {
        try fixture { database in
            try seed(database)
            try execute(database, "ALTER TABLE remote_messages RENAME COLUMN parts_json TO broken_body")
            XCTAssertThrowsError(try run(database))
            XCTAssertEqual(try count(database, "sessions"), 0)
            XCTAssertFalse(try NivoCloudLegacyBackfill.isComplete(database: database))
        }
        try fixture { database in
            try seed(database)
            _ = try NivoCloudLegacyBackfill.isComplete(database: database)
            try execute(database, "CREATE TRIGGER fail_marker BEFORE INSERT ON nivo_chat_migrations BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try run(database))
            XCTAssertEqual(try count(database, "sessions"), 0)
            XCTAssertEqual(try count(database, "messages"), 0)
            XCTAssertFalse(try NivoCloudLegacyBackfill.isComplete(database: database))
        }
    }

    func testConflictingMessageOwnerRollsBackNewParent() throws {
        try fixture { database in
            try seed(database)
            try execute(database, "INSERT INTO sessions(id, updated_at) VALUES ('other', 1)")
            try execute(database, "INSERT INTO messages(id, session_id, parts_json, updated_at) VALUES ('message', 'other', 'original', 1)")
            XCTAssertThrowsError(try run(database)) {
                XCTAssertEqual($0 as? NivoCloudChatSQLError, .messageOwnerChanged)
            }
            XCTAssertEqual(try count(database, "sessions"), 1)
            XCTAssertEqual(try text(database, "SELECT parts_json FROM messages"), "original")
        }
    }

    func testChangedSessionSetCannotWriteOutsideAcquiredScope() throws {
        try fixture { database in
            try seed(database)
            XCTAssertEqual(try NivoCloudLegacyBackfill.pendingSessionIDs(database: database), ["chat"])
            XCTAssertThrowsError(try NivoCloudLegacyBackfill.run(database: database, expectedSessionIDs: [], validateBody: validate))
            XCTAssertEqual(try count(database, "sessions"), 0)
            XCTAssertFalse(try NivoCloudLegacyBackfill.isComplete(database: database))
        }
    }

    func testMultipleReferenceDevicesChooseNewestSessionWithoutDuplicatingMessage() throws {
        try fixture { database in
            try seed(database)
            try execute(database, "INSERT INTO remote_sessions VALUES ('chat', 'new-device', 'new title', NULL, 'model', 1, 20)")
            try execute(database, "INSERT INTO remote_messages SELECT id, 'new-device', session_id, role, parts_json, created_at, token_usage, sort_order, reasoning_content, stream_interrupt_count FROM remote_messages")
            let result = try run(database)
            XCTAssertEqual(result.sessions, 1)
            XCTAssertEqual(result.messages, 1)
            XCTAssertEqual(try text(database, "SELECT title FROM sessions"), "new title")
            XCTAssertEqual(try text(database, "SELECT remote_origin_device_id FROM sessions"), "new-device")
        }
    }

    func testInvalidScalarDoesNotLeavePartialImport() throws {
        try fixture { database in
            try seed(database)
            try execute(database, "UPDATE remote_sessions SET updated_at = 'not a date'")
            XCTAssertThrowsError(try run(database))
            XCTAssertEqual(try count(database, "sessions"), 0)
            XCTAssertFalse(try NivoCloudLegacyBackfill.isComplete(database: database))
        }
    }

    func testNewestMessageReferenceWinsAcrossDevices() throws {
        try fixture { database in
            try seed(database)
            try NivoCloudReferenceSQL.prepare(database: database)
            try execute(database, "UPDATE remote_messages SET updated_at = 10")
            try execute(database, "INSERT INTO remote_messages SELECT id, 'second', session_id, role, '[\"new\"]', created_at, token_usage, sort_order, reasoning_content, stream_interrupt_count, 20 FROM remote_messages")
            _ = try run(database)
            XCTAssertEqual(try text(database, "SELECT parts_json FROM messages"), "[\"new\"]")
        }
    }

    private func run(_ database: OpaquePointer) throws -> NivoCloudLegacyBackfill.Result {
        try NivoCloudLegacyBackfill.run(database: database, expectedSessionIDs: ["chat", "other"], validateBody: validate)
    }

    /// 此便携测试验证正文校验失败的事务边界，宿主仍使用真实ContentPart解码器。
    private func validate(role: String, body: String, usage: String?) throws -> Int {
        guard role == "user" || role == "assistant" else { throw NivoCloudChatSQLError.invalidRecord }
        _ = try JSONSerialization.jsonObject(with: Data(body.utf8))
        if let usage { _ = try JSONSerialization.jsonObject(with: Data(usage.utf8)) }
        return 0
    }

    private func seed(_ database: OpaquePointer) throws {
        try execute(database, "INSERT INTO remote_sessions VALUES ('chat', 'device', 'reference title', NULL, 'model', 1, 2)")
        try execute(database, "INSERT INTO remote_messages VALUES ('message', 'device', 'chat', 'user', '[]', 1, NULL, 0, NULL, 0)")
    }

    private func fixture(_ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        let schema = [
            "CREATE TABLE sessions(id TEXT PRIMARY KEY, title TEXT, category TEXT, model_id TEXT, created_at REAL, updated_at REAL, remote_origin_device_id TEXT, memory_enabled INTEGER, model_binding TEXT, pinned_at REAL, folder_id TEXT)",
            "CREATE TABLE messages(id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT, parts_json TEXT, created_at REAL, token_usage TEXT, sort_order INTEGER, reasoning_content TEXT, stream_interrupt_count INTEGER, updated_at REAL, part_flags INTEGER, model_id TEXT, model_display_name TEXT, provider_type TEXT, provider_instance_id TEXT)",
            "CREATE TABLE remote_sessions(id TEXT, device_id TEXT, title TEXT, category TEXT, model_id TEXT, created_at REAL, updated_at REAL, PRIMARY KEY(id, device_id))",
            "CREATE TABLE remote_messages(id TEXT, device_id TEXT, session_id TEXT, role TEXT, parts_json TEXT, created_at REAL, token_usage TEXT, sort_order INTEGER, reasoning_content TEXT, stream_interrupt_count INTEGER, PRIMARY KEY(id, device_id))",
            "CREATE TABLE deleted_session_tombstones(session_id TEXT PRIMARY KEY, deleted_at REAL)",
            "CREATE TABLE deleted_record_tombstones(record_type TEXT, record_id TEXT, deleted_at REAL, PRIMARY KEY(record_type, record_id))",
        ]
        for sql in schema { try execute(database, sql) }
        try body(database)
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        try NivoSQLiteWrite.execute(database, sql: sql)
    }

    private func count(_ database: OpaquePointer, _ table: String) throws -> Int {
        try XCTUnwrap(try NivoSQLiteWrite.readRow(database, sql: "SELECT count(*) FROM \(table)") { Int(sqlite3_column_int64($0, 0)) })
    }

    private func text(_ database: OpaquePointer, _ sql: String) throws -> String? {
        try NivoSQLiteWrite.readRow(database, sql: sql) { sqlite3_column_text($0, 0).map { String(cString: $0) } } ?? nil
    }
}
