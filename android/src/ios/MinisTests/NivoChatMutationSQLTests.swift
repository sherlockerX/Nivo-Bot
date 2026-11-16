import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 在真实SQLite中注入磁盘写入故障，验证页面可依赖完整提交结果。
final class NivoChatMutationSQLTests: XCTestCase {
    func testClearFailureRollsBackMessagesReferencesMarkersAndDirtyRows() throws {
        try fixture { database in
            try execute(database, "CREATE TRIGGER fail_clear BEFORE DELETE ON compact_markers BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try clear(database))
            XCTAssertEqual(try ids(database), ["one", "two", "three"])
            XCTAssertEqual(try count(database, "remote_messages"), 1)
            XCTAssertEqual(try count(database, "compact_markers"), 1)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 0)
            try execute(database, "DROP TRIGGER fail_clear")
            try clear(database)
            XCTAssertEqual(try count(database, "sessions"), 1)
            XCTAssertEqual(try count(database, "messages"), 0)
            XCTAssertEqual(try count(database, "remote_messages"), 0)
            XCTAssertEqual(try count(database, "compact_markers"), 0)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 4)
        }
    }

    func testDisabledUploadStillRetainsDeletionEvidenceAndClearsReferenceOnlyRows() throws {
        try fixture { database in
            try execute(database, "UPDATE remote_messages SET id = 'reference-only', updated_at = 900")
            try NivoChatMutationSQL.clear(sessionID: "chat", database: database, at: 100, markDirty: { _, _, _ in })
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 5)
            XCTAssertEqual(try number(database, "SELECT deleted_at FROM deleted_record_tombstones WHERE record_id='reference-only'"), 900)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
        }
    }

    func testDirtyWriteFailureDoesNotDeleteAnyMessage() throws {
        try fixture { database in
            try execute(database, "CREATE TRIGGER fail_dirty BEFORE INSERT ON sync_dirty_records BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try truncate(database, kept: ["one"]))
            XCTAssertEqual(try ids(database), ["one", "two", "three"])
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 0)
        }
    }

    func testSparseAndDuplicateSortOrderRetainsExactPrefixByIdentity() throws {
        try fixture { database in
            try execute(database, "UPDATE messages SET sort_order=2048 WHERE id IN ('one','two')")
            try execute(database, "UPDATE messages SET sort_order=2703 WHERE id='three'")
            try truncate(database, kept: ["one"])
            XCTAssertEqual(try ids(database), ["one"])
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 3)
        }
    }

    func testChangedDatabaseOrOrderRejectsStaleHistoryWithoutDeleting() throws {
        try fixture { database in
            try execute(database, "UPDATE messages SET sort_order=9 WHERE id='one'")
            XCTAssertThrowsError(try truncate(database, kept: ["one"])) { error in
                XCTAssertEqual(error as? NivoChatMutationError, .staleHistory)
            }
            XCTAssertEqual(try count(database, "messages"), 3)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
        }
    }

    func testDuplicateOrNonPrefixIdentifiersAreRejected() throws {
        try fixture { database in
            XCTAssertThrowsError(try truncate(database, kept: ["two"]))
            XCTAssertThrowsError(try NivoChatMutationSQL.truncate(sessionID: "chat", expectedIDs: ["one", "one"],
                retainedIDs: ["one"], database: database, at: 100, markDirty: { _, _, _ in }))
            XCTAssertEqual(try count(database, "messages"), 3)
        }
    }

    func testRetainedRowRewriteFailureRestoresDeletedSuffixAndMarkers() throws {
        try fixture { database in
            try execute(database, "CREATE TRIGGER fail_rewrite BEFORE UPDATE ON messages BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try truncate(database, kept: ["one"], rewrite: rewrite()))
            XCTAssertEqual(try ids(database), ["one", "two", "three"])
            XCTAssertEqual(try count(database, "compact_markers"), 1)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 0)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
        }
    }

    func testRetainedRewriteCommitsWithSuffixAndAdvancesClock() throws {
        try fixture { database in
            try execute(database, "UPDATE messages SET updated_at=500 WHERE id='one'")
            try truncate(database, kept: ["one"], rewrite: rewrite())
            XCTAssertEqual(try ids(database), ["one"])
            let body = try NivoSQLiteWrite.readRow(database, sql: "SELECT parts_json FROM messages") {
                String(cString: sqlite3_column_text($0, 0))
            }
            XCTAssertEqual(body, "trimmed")
            XCTAssertGreaterThan(try number(database, "SELECT updated_at FROM messages"), 500)
            XCTAssertEqual(try number(database, "SELECT part_flags FROM messages"), 4)
            XCTAssertEqual(try number(database, "SELECT stream_interrupt_count FROM messages"), 0)
        }
    }

    func testNewerRetainedBodyRejectsRewriteAndRestoresSuffix() throws {
        try fixture { database in
            try execute(database, "UPDATE messages SET parts_json='newer' WHERE id='one'")
            XCTAssertThrowsError(try truncate(database, kept: ["one"], rewrite: rewrite())) { error in
                XCTAssertEqual(error as? NivoChatMutationError, .staleHistory)
            }
            XCTAssertEqual(try count(database, "messages"), 3)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
        }
    }

    func testForeignReferencePreventsLocalClearFromDeletingAnotherConversation() throws {
        try fixture { database in
            try execute(database, "UPDATE remote_messages SET session_id='other'")
            XCTAssertThrowsError(try clear(database))
            XCTAssertEqual(try count(database, "messages"), 3)
            XCTAssertEqual(try count(database, "remote_messages"), 1)
        }
    }

    func testRelayDeleteRejectsForeignUppercaseUUIDAndRollsBackLowercase() throws {
        try fixture { database in
            let identifier = UUID().uuidString
            try seed(database, id: identifier.lowercased(), owner: "chat")
            try seed(database, id: identifier, owner: "other")
            XCTAssertThrowsError(try NivoChatMutationSQL.deleteRelayMessage(id: identifier.lowercased(),
                sessionID: "chat", database: database, at: 100))
            XCTAssertEqual(try count(database, "messages"), 5)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 0)
        }
    }

    func testRelayDeleteHandlesBothUUIDCasesAndRepeatedDeletion() throws {
        try fixture { database in
            let identifier = UUID().uuidString
            try seed(database, id: identifier.lowercased(), owner: "chat")
            try seed(database, id: identifier, owner: "chat")
            for _ in 0..<2 {
                try NivoChatMutationSQL.deleteRelayMessage(id: identifier.lowercased(), sessionID: "chat",
                    database: database, at: 100)
            }
            XCTAssertEqual(try count(database, "messages"), 3)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 2)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
        }
    }

    func testBatchSessionDeleteFailureRestoresAllSessionsAndFileRequests() throws {
        try fixture { database in
            try execute(database, "INSERT INTO sessions VALUES ('later-chat',1)")
            try seed(database, id: "other", owner: "later-chat")
            try execute(database, "CREATE TRIGGER fail_parent BEFORE DELETE ON sessions WHEN OLD.id='later-chat' BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoChatMutationSQL.deleteSessions(files: ["chat": ["chat:file"], "later-chat": []],
                database: database, at: 100) { try dirty(database, type: $0, id: $1, operation: $2) })
            XCTAssertEqual(try count(database, "sessions"), 2)
            XCTAssertEqual(try count(database, "messages"), 4)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 0)
            XCTAssertEqual(try count(database, "deleted_session_tombstones"), 0)
            try execute(database, "DROP TRIGGER fail_parent")
            try NivoChatMutationSQL.deleteSessions(files: ["chat": ["chat:file"], "later-chat": []],
                database: database, at: 100) { try dirty(database, type: $0, id: $1, operation: $2) }
            XCTAssertEqual(try count(database, "sessions"), 0)
            XCTAssertEqual(try count(database, "messages"), 0)
            XCTAssertEqual(try count(database, "deleted_session_tombstones"), 2)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 8)
        }
    }

    func testRelayMainClearPreservesSessionAndReplayKeepsNewMessages() throws {
        try fixture { database in
            try relayDelete(database, preservesSession: true)
            XCTAssertEqual(try count(database, "sessions"), 1)
            XCTAssertEqual(try count(database, "messages"), 0)
            XCTAssertEqual(try count(database, "compact_markers"), 0)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
            try seed(database, id: "after-clear", owner: "chat")
            try relayDelete(database, preservesSession: true)
            XCTAssertEqual(try ids(database), ["after-clear"])
            try NivoChatMutationSQL.applyRelayConversationDeletion(sessionID: "chat", conversationID: "relay-chat",
                preservesSession: true, database: database, deletedAt: 101)
            XCTAssertEqual(try count(database, "messages"), 0)
        }
    }

    func testRelayDeletionReceiptFailureRollsBackClear() throws {
        try fixture { database in
            try execute(database, "CREATE TRIGGER fail_receipt BEFORE INSERT ON deleted_record_tombstones WHEN NEW.record_type='RelayConversation' BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try relayDelete(database, preservesSession: true))
            XCTAssertEqual(try ids(database), ["one", "two", "three"])
            XCTAssertEqual(try count(database, "compact_markers"), 1)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 0)
        }
    }

    func testRelaySideDeleteStillRemovesParentAndDoesNotEcho() throws {
        try fixture { database in
            try relayDelete(database, preservesSession: false)
            XCTAssertEqual(try count(database, "sessions"), 0)
            XCTAssertEqual(try count(database, "messages"), 0)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
            try relayDelete(database, preservesSession: false)
        }
    }

    private func relayDelete(_ database: OpaquePointer, preservesSession: Bool) throws {
        try NivoChatMutationSQL.applyRelayConversationDeletion(sessionID: "chat", conversationID: "relay-chat",
            preservesSession: preservesSession, database: database, deletedAt: 100)
    }

    func testSummaryRevertFailureRetainsMarkerAndDoesNotPublishDeletion() throws {
        try fixture { database in
            try execute(database, "CREATE TRIGGER fail_summary BEFORE DELETE ON compact_markers BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try revert(database))
            XCTAssertEqual(try count(database, "compact_markers"), 1)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
            XCTAssertEqual(try count(database, "deleted_record_tombstones"), 0)
        }
    }

    func testSummaryRevertRejectsStaleLatestAndForeignSession() throws {
        try fixture { database in
            try execute(database, "INSERT INTO compact_markers VALUES ('newer','chat',11)")
            XCTAssertThrowsError(try revert(database))
            XCTAssertThrowsError(try NivoChatMutationSQL.revertMarker(id: "newer", sessionID: "other", database: database,
                at: 100, markDirty: { _, _, _ in }))
            XCTAssertEqual(try count(database, "compact_markers"), 2)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 0)
        }
    }

    func testSummaryRevertRecordsDeletionVersionAndPreservesHistory() throws {
        try fixture { database in
            try execute(database, "UPDATE compact_markers SET created_at=500")
            try revert(database)
            XCTAssertEqual(try count(database, "compact_markers"), 0)
            XCTAssertEqual(try ids(database), ["one", "two", "three"])
            XCTAssertEqual(try number(database, "SELECT deleted_at FROM deleted_record_tombstones WHERE record_id='summary'"), 500)
            XCTAssertEqual(try count(database, "sync_dirty_records"), 1)
        }
    }

    private func revert(_ database: OpaquePointer) throws {
        try NivoChatMutationSQL.revertMarker(id: "summary", sessionID: "chat", database: database, at: 100) {
            try dirty(database, type: $0, id: $1, operation: $2)
        }
    }

    private func rewrite() -> NivoChatMutationSQL.Rewrite {
        .init(messageID: "one", expectedJSON: "original", partsJSON: "trimmed", partFlags: 4)
    }

    private func clear(_ database: OpaquePointer) throws {
        try NivoChatMutationSQL.clear(sessionID: "chat", database: database, at: 100) {
            try dirty(database, type: $0, id: $1, operation: $2)
        }
    }

    private func truncate(_ database: OpaquePointer, kept: [String], rewrite: NivoChatMutationSQL.Rewrite? = nil) throws {
        try NivoChatMutationSQL.truncate(sessionID: "chat", expectedIDs: ["one", "two", "three"],
            retainedIDs: kept, rewrite: rewrite, database: database, at: 100) {
                try dirty(database, type: $0, id: $1, operation: $2)
            }
    }

    private func dirty(_ database: OpaquePointer, type: String, id: String, operation: String) throws {
        try NivoSQLiteWrite.execute(database, sql: "INSERT OR REPLACE INTO sync_dirty_records VALUES (?, ?, ?)",
                                   values: [.text(type), .text(id), .text(operation)])
    }

    private func seed(_ database: OpaquePointer, id: String, owner: String) throws {
        try NivoSQLiteWrite.execute(database, sql: """
            INSERT INTO messages VALUES (?, ?, 'original', 1, 1, 1, 0, NULL, 0)
            """, values: [.text(id), .text(owner)])
    }

    private func fixture(_ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        defer { sqlite3_close(database) }
        let schema = [
            "CREATE TABLE sessions(id TEXT PRIMARY KEY, updated_at REAL)",
            "CREATE TABLE messages(id TEXT PRIMARY KEY, session_id TEXT, parts_json TEXT, created_at REAL, updated_at REAL, sort_order INTEGER, part_flags INTEGER, error_info TEXT, stream_interrupt_count INTEGER)",
            "CREATE TABLE remote_messages(id TEXT, device_id TEXT, session_id TEXT, created_at REAL, updated_at REAL, PRIMARY KEY(id,device_id))",
            "CREATE TABLE compact_markers(id TEXT PRIMARY KEY, session_id TEXT, created_at REAL)",
            "CREATE TABLE remote_sessions(id TEXT PRIMARY KEY)",
            "CREATE TABLE remote_media(id TEXT, session_id TEXT)",
            "CREATE TABLE deleted_session_tombstones(session_id TEXT PRIMARY KEY, deleted_at REAL)",
            "CREATE TABLE deleted_record_tombstones(record_type TEXT, record_id TEXT, deleted_at REAL, PRIMARY KEY(record_type,record_id))",
            "CREATE TABLE sync_dirty_records(record_type TEXT, record_id TEXT, operation TEXT, PRIMARY KEY(record_type,record_id))",
            "INSERT INTO sessions VALUES ('chat',1)",
            "INSERT INTO messages VALUES ('one','chat','original',1,1,1,0,'old error',1)",
            "INSERT INTO messages VALUES ('two','chat','later',2,2,2,0,NULL,0)",
            "INSERT INTO messages VALUES ('three','chat','last',3,3,3,0,NULL,0)",
            "INSERT INTO remote_messages VALUES ('two','device','chat',2,200)",
            "INSERT INTO compact_markers VALUES ('summary','chat',10)",
        ]
        for sql in schema { try execute(database, sql) }
        try body(database)
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        try NivoSQLiteWrite.execute(database, sql: sql)
    }

    private func count(_ database: OpaquePointer, _ table: String) throws -> Int {
        Int(try number(database, "SELECT count(*) FROM \(table)"))
    }

    private func number(_ database: OpaquePointer, _ sql: String) throws -> Double {
        try XCTUnwrap(try NivoSQLiteWrite.readRow(database, sql: sql) { sqlite3_column_double($0, 0) })
    }

    private func ids(_ database: OpaquePointer) throws -> [String] {
        try NivoSQLiteWrite.readRows(database, sql: "SELECT id FROM messages ORDER BY sort_order, created_at, id") {
            String(cString: sqlite3_column_text($0, 0))
        }
    }
}
