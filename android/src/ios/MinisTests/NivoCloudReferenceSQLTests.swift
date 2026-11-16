import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 旧协议参考副本使用真实SQLite，覆盖乱序消息、故障回滚和删除重放。
final class NivoCloudReferenceSQLTests: XCTestCase {
    func testMessageWriteFailureRollsBackPlaceholderAndSchemaThenRetries() throws {
        try fixture { database in
            try execute(database, "CREATE TRIGGER fail_message BEFORE INSERT ON remote_messages BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try merge(database))
            XCTAssertEqual(try count(database, "remote_sessions"), 0)
            try execute(database, "DROP TRIGGER fail_message")
            try merge(database)
            XCTAssertEqual(try count(database, "remote_sessions"), 1)
            XCTAssertEqual(try count(database, "remote_messages"), 1)
        }
    }

    func testOlderReplayCannotReplaceNewerReference() throws {
        try fixture { database in
            try merge(database, body: "new", version: 20)
            try merge(database, body: "old", version: 10)
            XCTAssertEqual(try text(database, "SELECT parts_json FROM remote_messages"), "new")
            try merge(database, body: "latest", version: 30)
            XCTAssertEqual(try text(database, "SELECT parts_json FROM remote_messages"), "latest")
            XCTAssertEqual(try count(database, "remote_messages"), 1)
        }
    }

    func testLegacyRowsUseCreationDateUntilVersionIsAvailable() throws {
        try fixture { database in
            try execute(database, "INSERT INTO remote_messages VALUES ('message', 'device', 'chat', 'user', 'legacy', 5, NULL, 0, NULL, 0)")
            try merge(database, body: "older", version: 4)
            XCTAssertEqual(try text(database, "SELECT parts_json FROM remote_messages"), "legacy")
            try merge(database, body: "newer", version: 6)
            XCTAssertEqual(try text(database, "SELECT parts_json FROM remote_messages"), "newer")
        }
    }

    func testMessageCannotChangeOwnerAcrossDevices() throws {
        try fixture { database in
            try merge(database)
            XCTAssertThrowsError(try merge(database, sessionID: "other", deviceID: "second")) {
                XCTAssertEqual($0 as? NivoCloudChatSQLError, .messageOwnerChanged)
            }
            XCTAssertEqual(try count(database, "remote_sessions"), 1)
        }
    }

    func testDeletedReferenceCannotCreatePlaceholderOrReappear() throws {
        try fixture { database in
            try execute(database, "INSERT INTO deleted_record_tombstones VALUES ('Message', 'message', 30)")
            try merge(database)
            XCTAssertEqual(try count(database, "remote_sessions"), 0)
            XCTAssertEqual(try count(database, "remote_messages"), 0)
        }
    }

    func testReferenceSessionDeletionIsAtomicAndDeviceScoped() throws {
        try fixture { database in
            try merge(database)
            try merge(database, deviceID: "second")
            try execute(database, "INSERT INTO remote_media VALUES ('media', 'device', 'chat')")
            try execute(database, "CREATE TRIGGER fail_parent BEFORE DELETE ON remote_sessions BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoCloudReferenceSQL.deleteSession(id: "chat", deviceID: "device", database: database))
            XCTAssertEqual(try count(database, "remote_messages"), 2)
            XCTAssertEqual(try count(database, "remote_media"), 1)
            try execute(database, "DROP TRIGGER fail_parent")
            try NivoCloudReferenceSQL.deleteSession(id: "chat", deviceID: "device", database: database)
            XCTAssertEqual(try text(database, "SELECT device_id FROM remote_messages"), "second")
            XCTAssertEqual(try count(database, "remote_media"), 0)
        }
    }

    func testMessageDeletionAcceptsCurrentAndLegacyCompositeNames() throws {
        for name in ["Message:message", "Message:chat:message"] {
            try fixture { database in
                try merge(database)
                try execute(database, "INSERT INTO messages VALUES ('message', 'chat', 20)")
                let identity = try NivoCloudReferenceSQL.MessageIdentity(recordName: name)
                XCTAssertTrue(try NivoCloudReferenceSQL.deleteMessage(identity, deviceID: "device",
                    expectedSessionID: "chat", preservingSessions: [], database: database, deletedAt: 30))
                XCTAssertEqual(try count(database, "remote_messages"), 0)
                XCTAssertEqual(try count(database, "messages"), 0)
                XCTAssertEqual(try text(database, "SELECT record_type FROM deleted_record_tombstones"), "Message")
                try merge(database)
                XCTAssertEqual(try count(database, "remote_messages"), 0)
            }
        }
    }

    func testCurrentMessageNamePreservesLocalCopyDuringWholeSessionDeletion() throws {
        try fixture { database in
            try merge(database)
            try execute(database, "INSERT INTO messages VALUES ('message', 'chat', 20)")
            let identity = try NivoCloudReferenceSQL.MessageIdentity(recordName: "Message:message")
            XCTAssertFalse(try NivoCloudReferenceSQL.deleteMessage(identity, deviceID: "device",
                expectedSessionID: "chat", preservingSessions: ["chat"], database: database, deletedAt: 30))
            XCTAssertEqual(try count(database, "messages"), 1)
            XCTAssertEqual(try count(database, "remote_messages"), 0)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 0)
        }
    }

    func testLocalDeleteFailureRollsBackReferenceAndTombstone() throws {
        try fixture { database in
            try merge(database)
            try execute(database, "INSERT INTO messages VALUES ('message', 'chat', 20)")
            try execute(database, "CREATE TRIGGER fail_local BEFORE DELETE ON messages BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            let identity = try NivoCloudReferenceSQL.MessageIdentity(recordName: "Message:chat:message")
            XCTAssertThrowsError(try NivoCloudReferenceSQL.deleteMessage(identity, deviceID: "device",
                expectedSessionID: "chat", preservingSessions: [], database: database, deletedAt: 30))
            XCTAssertEqual(try count(database, "remote_messages"), 1)
            XCTAssertEqual(try count(database, "messages"), 1)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 0)
        }
    }

    func testDeletionRejectsConflictingIdentityAndChangedScope() throws {
        try fixture { database in
            try merge(database)
            let identity = try NivoCloudReferenceSQL.MessageIdentity(recordName: "Message:other:message")
            XCTAssertThrowsError(try NivoCloudReferenceSQL.deleteMessage(identity, deviceID: "device",
                expectedSessionID: "chat", preservingSessions: [], database: database, deletedAt: 30))
            let current = try NivoCloudReferenceSQL.MessageIdentity(recordName: "Message:message")
            XCTAssertThrowsError(try NivoCloudReferenceSQL.deleteMessage(current, deviceID: "device",
                expectedSessionID: nil, preservingSessions: [], database: database, deletedAt: 30))
            XCTAssertEqual(try count(database, "remote_messages"), 1)
        }
    }

    func testMissingMessageDeletionStillPreventsDelayedDelivery() throws {
        try fixture { database in
            let identity = try NivoCloudReferenceSQL.MessageIdentity(recordName: "Message:message")
            XCTAssertFalse(try NivoCloudReferenceSQL.deleteMessage(identity, deviceID: "device",
                expectedSessionID: nil, preservingSessions: [], database: database, deletedAt: 30))
            try merge(database)
            XCTAssertEqual(try count(database, "remote_messages"), 0)
        }
    }

    func testInvalidIdentityAndScalarsFailBeforeWriting() throws {
        for name in ["Message:", "Message::message", "Message:chat:", "Other:message"] {
            XCTAssertThrowsError(try NivoCloudReferenceSQL.MessageIdentity(recordName: name))
        }
        try fixture { database in
            XCTAssertThrowsError(try merge(database, version: .nan))
            XCTAssertThrowsError(try merge(database, deviceID: ""))
            XCTAssertEqual(try count(database, "remote_sessions"), 0)
        }
    }

    func testSharedSessionDeletionRollsBackEveryCopyAndMarker() throws {
        try fixture { database in
            try merge(database)
            try execute(database, "INSERT INTO sessions VALUES ('chat', 20)")
            try execute(database, "INSERT INTO messages VALUES ('message', 'chat', 20)")
            try execute(database, "CREATE TRIGGER fail_session BEFORE DELETE ON sessions BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoSQLiteWrite.transaction(database) {
                try NivoCloudReferenceSQL.deleteSessionInTransaction(id: "chat", database: database, deletedAt: 30)
            })
            XCTAssertEqual(try count(database, "sessions"), 1)
            XCTAssertEqual(try count(database, "messages"), 1)
            XCTAssertEqual(try count(database, "remote_messages"), 1)
            XCTAssertEqual(try count(database, "remote_sessions"), 1)
            XCTAssertEqual(try count(database, "deleted_session_tombstones"), 0)
        }
    }

    func testSharedSessionDeletionPreventsReferenceReplayAndKeepsNewerDeletion() throws {
        try fixture { database in
            try merge(database)
            try execute(database, "INSERT INTO sessions VALUES ('chat', 20)")
            try execute(database, "INSERT INTO messages VALUES ('message', 'chat', 20)")
            XCTAssertTrue(try NivoSQLiteWrite.transaction(database) {
                try NivoCloudReferenceSQL.deleteSessionInTransaction(id: "chat", database: database, deletedAt: 30)
            })
            XCTAssertFalse(try NivoSQLiteWrite.transaction(database) {
                try NivoCloudReferenceSQL.deleteSessionInTransaction(id: "chat", database: database, deletedAt: 10)
            })
            try merge(database)
            XCTAssertEqual(try count(database, "sessions"), 0)
            XCTAssertEqual(try count(database, "messages"), 0)
            XCTAssertEqual(try count(database, "remote_messages"), 0)
            XCTAssertEqual(try count(database, "remote_sessions"), 0)
            XCTAssertTrue(try NivoCloudSessionSQL.isSessionDeleted(id: "chat", updatedAt: 29, database: database))
        }
    }

    private func merge(_ database: OpaquePointer, sessionID: String = "chat", deviceID: String = "device",
                       body: String = "body", version: Double = 20) throws {
        let message = NivoCloudChatSQL.Message(id: "message", sessionID: sessionID, role: "user", partsJSON: body,
            createdAt: 1, usageJSON: nil, reasoning: nil, interruptCount: 0, updatedAt: version, partFlags: 0)
        try NivoCloudReferenceSQL.mergeMessage(message, deviceID: deviceID, sortOrder: 0, database: database)
    }

    private func fixture(_ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        let schema = [
            "CREATE TABLE sessions(id TEXT PRIMARY KEY, updated_at REAL)",
            "CREATE TABLE messages(id TEXT PRIMARY KEY, session_id TEXT, updated_at REAL)",
            "CREATE TABLE compact_markers(id TEXT PRIMARY KEY, session_id TEXT)",
            "CREATE TABLE remote_sessions(id TEXT, device_id TEXT, title TEXT, category TEXT, model_id TEXT, created_at REAL, updated_at REAL, PRIMARY KEY(id, device_id))",
            "CREATE TABLE remote_messages(id TEXT, device_id TEXT, session_id TEXT, role TEXT, parts_json TEXT, created_at REAL, token_usage TEXT, sort_order INTEGER, reasoning_content TEXT, stream_interrupt_count INTEGER, PRIMARY KEY(id, device_id))",
            "CREATE TABLE remote_media(id TEXT, device_id TEXT, session_id TEXT)",
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
