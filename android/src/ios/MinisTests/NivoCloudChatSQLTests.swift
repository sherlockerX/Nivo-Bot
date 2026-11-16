import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 在真实SQLite连接上验证聊天入站的会话归属和分组解散事务。
final class NivoCloudChatSQLTests: XCTestCase {
    func testMessageWithSameIdFromAnotherSessionIsRejected() throws {
        try withDatabase { database in
            try schema(database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id) VALUES ('first')")
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id) VALUES ('second')")
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO messages(id, session_id, parts_json, created_at, updated_at, sort_order) VALUES ('m', 'first', 'old', 1, 1, 0)")
            let message = NivoCloudChatSQL.Message(id: "m", sessionID: "second", role: "user",
                partsJSON: "new", createdAt: 2, usageJSON: nil, reasoning: nil,
                interruptCount: 0, updatedAt: 2, partFlags: 1)
            XCTAssertThrowsError(try NivoCloudChatSQL.mergeMessage(message, database: database)) {
                XCTAssertEqual($0 as? NivoCloudChatSQLError, .messageOwnerChanged)
            }
            XCTAssertEqual(try text(database, "SELECT session_id FROM messages WHERE id='m'"), "first")
            XCTAssertEqual(try text(database, "SELECT parts_json FROM messages WHERE id='m'"), "old")
        }
    }

    func testMessageInsertFailureRollsBackSortShiftAndRows() throws {
        try withDatabase { database in
            try schema(database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id) VALUES ('chat')")
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO messages(id, session_id, parts_json, created_at, updated_at, sort_order) VALUES ('later', 'chat', 'later', 3, 3, 0)")
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_message BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            let message = NivoCloudChatSQL.Message(id: "middle", sessionID: "chat", role: "user",
                partsJSON: "middle", createdAt: 2, usageJSON: nil, reasoning: nil,
                interruptCount: 0, updatedAt: 2, partFlags: 1)
            XCTAssertThrowsError(try NivoCloudChatSQL.mergeMessage(message, database: database))
            XCTAssertEqual(try number(database, "SELECT sort_order FROM messages WHERE id='later'"), 0)
            XCTAssertEqual(try number(database, "SELECT count(*) FROM messages"), 1)
        }
    }

    func testFolderDeletionFailureRollsBackMemberDetachment() throws {
        try withDatabase { database in
            try schema(database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO folders(id, name, updated_at) VALUES ('f', '工作', 1)")
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id, folder_id) VALUES ('chat', 'f')")
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_folder BEFORE DELETE ON folders BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoCloudChatSQL.deleteFolder(id: "f", at: 2, database: database))
            XCTAssertEqual(try text(database, "SELECT folder_id FROM sessions WHERE id='chat'"), "f")
            XCTAssertEqual(try number(database, "SELECT count(*) FROM folders"), 1)
            XCTAssertEqual(try number(database, "SELECT count(*) FROM deleted_record_tombstones"), 0)
        }
    }

    func testFolderMergeWriteFailureLeavesExistingState() throws {
        try withDatabase { database in
            try schema(database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO folders(id, name, updated_at) VALUES ('f', '旧', 1)")
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_folder BEFORE UPDATE ON folders BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            let folder = NivoCloudChatSQL.Folder(id: "f", name: "新", icon: nil, color: nil, origin: "manual",
                sortIndex: 0, pinnedAt: nil, description: nil, createdAt: 1, updatedAt: 2)
            XCTAssertThrowsError(try NivoCloudChatSQL.mergeFolder(folder, database: database))
            XCTAssertEqual(try text(database, "SELECT name FROM folders WHERE id='f'"), "旧")
            XCTAssertEqual(try number(database, "SELECT updated_at FROM folders WHERE id='f'"), 1)
        }
    }

    func testFolderDeletionAndReplayPreserveSessionsAndOtherGroups() throws {
        try withDatabase { database in
            try schema(database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO folders(id, name) VALUES ('f', '工作'), ('other', '生活')")
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id, folder_id) VALUES ('chat', 'f'), ('other-chat', 'other')")
            try NivoCloudChatSQL.deleteFolder(id: "f", at: 10, database: database)
            try NivoCloudChatSQL.deleteFolder(id: "f", at: 5, database: database)
            XCTAssertNil(try text(database, "SELECT folder_id FROM sessions WHERE id='chat'"))
            XCTAssertEqual(try text(database, "SELECT folder_id FROM sessions WHERE id='other-chat'"), "other")
            XCTAssertEqual(try number(database, "SELECT count(*) FROM sessions"), 2)
            XCTAssertEqual(try number(database, "SELECT count(*) FROM folders"), 1)
            XCTAssertEqual(try number(database, "SELECT deleted_at FROM deleted_record_tombstones WHERE record_id='f'"), 10)
        }
    }

    func testFolderTombstoneFailureRollsBackBothDeletionAndMembership() throws {
        try withDatabase { database in
            try schema(database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO folders(id, name) VALUES ('f', '工作')")
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id, folder_id) VALUES ('chat', 'f')")
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_marker BEFORE INSERT ON deleted_record_tombstones BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoCloudChatSQL.deleteFolder(id: "f", at: 2, database: database))
            XCTAssertEqual(try text(database, "SELECT folder_id FROM sessions WHERE id='chat'"), "f")
            XCTAssertEqual(try number(database, "SELECT count(*) FROM folders"), 1)
        }
    }

    func testDeletedFolderCannotBeResurrectedByStaleSyncButExplicitRestoreCanRecoverIt() throws {
        try withDatabase { database in
            try schema(database)
            let folder = NivoCloudChatSQL.Folder(id: "f", name: "工作", icon: nil, color: nil, origin: "manual",
                sortIndex: 0, pinnedAt: nil, description: nil, createdAt: 1, updatedAt: 2)
            try NivoCloudChatSQL.deleteFolder(id: "f", at: 3, database: database)
            XCTAssertFalse(try NivoCloudChatSQL.mergeFolder(folder, database: database))
            XCTAssertEqual(try number(database, "SELECT count(*) FROM folders"), 0)
            XCTAssertTrue(try NivoCloudChatSQL.mergeFolder(folder, database: database, respectTombstones: false))
            XCTAssertEqual(try text(database, "SELECT name FROM folders"), "工作")
        }
    }

    func testMessageMissingParentThrowsAndCanBeReplayedAfterParentArrives() throws {
        try withDatabase { database in
            try schema(database)
            let message = row("m", createdAt: 1)
            XCTAssertThrowsError(try NivoCloudChatSQL.mergeMessage(message, database: database)) {
                XCTAssertEqual($0 as? NivoCloudChatSQLError, .missingSession)
            }
            XCTAssertEqual(try number(database, "SELECT count(*) FROM messages"), 0)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id) VALUES ('chat')")
            XCTAssertTrue(try NivoCloudChatSQL.mergeMessage(message, database: database))
            XCTAssertFalse(try NivoCloudChatSQL.mergeMessage(message, database: database))
            XCTAssertEqual(try number(database, "SELECT count(*) FROM messages"), 1)
        }
    }

    func testMessageOrderingReplayAndNewerEditPreserveAttribution() throws {
        try withDatabase { database in
            try schema(database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id) VALUES ('chat')")
            var first = row("a", createdAt: 1)
            first.modelID = "measured"
            first.providerID = "original-provider"
            try NivoCloudChatSQL.mergeMessage(row("c", createdAt: 3), database: database)
            try NivoCloudChatSQL.mergeMessage(first, database: database)
            try NivoCloudChatSQL.mergeMessage(row("b", createdAt: 2), database: database)
            let order = try NivoSQLiteWrite.readRows(database, sql: "SELECT id FROM messages ORDER BY sort_order") {
                String(cString: sqlite3_column_text($0, 0))
            }
            XCTAssertEqual(order, ["a", "b", "c"])
            let edit = row("a", createdAt: 1, updatedAt: 9)
            XCTAssertTrue(try NivoCloudChatSQL.mergeMessage(edit, database: database))
            XCTAssertFalse(try NivoCloudChatSQL.mergeMessage(first, database: database))
            XCTAssertEqual(try text(database, "SELECT model_id FROM messages WHERE id='a'"), "measured")
            XCTAssertEqual(try text(database, "SELECT provider_instance_id FROM messages WHERE id='a'"), "original-provider")
            XCTAssertEqual(try number(database, "SELECT updated_at FROM messages WHERE id='a'"), 9)
            XCTAssertEqual(try number(database, "SELECT sort_order FROM messages WHERE id='a'"), 0)
        }
    }

    func testMessageWriteAndReadFailuresAreNotAcknowledged() throws {
        try withDatabase { database in
            try schema(database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id) VALUES ('chat')")
            try NivoCloudChatSQL.mergeMessage(row("m", createdAt: 1), database: database)
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_update BEFORE UPDATE ON messages BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoCloudChatSQL.mergeMessage(row("m", createdAt: 1, updatedAt: 2), database: database))
            XCTAssertEqual(try number(database, "SELECT updated_at FROM messages WHERE id='m'"), 1)
            try NivoSQLiteWrite.execute(database, sql: "DROP TABLE deleted_session_tombstones")
            XCTAssertThrowsError(try NivoCloudChatSQL.mergeMessage(row("other", createdAt: 2), database: database))
            XCTAssertEqual(try number(database, "SELECT count(*) FROM messages"), 1)
        }
    }

    func testDeletedParentAndMessageRejectStaleResurrection() throws {
        try withDatabase { database in
            try schema(database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO deleted_session_tombstones VALUES ('chat', 2)")
            XCTAssertFalse(try NivoCloudChatSQL.mergeMessage(row("old", createdAt: 1), database: database))
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id) VALUES ('chat')")
            try NivoSQLiteWrite.execute(database, sql: "DELETE FROM deleted_session_tombstones")
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO deleted_record_tombstones VALUES ('Message', 'old', 2)")
            XCTAssertFalse(try NivoCloudChatSQL.mergeMessage(row("old", createdAt: 1), database: database))
            XCTAssertEqual(try number(database, "SELECT count(*) FROM messages"), 0)
        }
    }

    private func row(_ id: String, createdAt: Double, updatedAt: Double? = nil) -> NivoCloudChatSQL.Message {
        .init(id: id, sessionID: "chat", role: "user", partsJSON: "[]", createdAt: createdAt,
            usageJSON: nil, reasoning: nil, interruptCount: 0, updatedAt: updatedAt ?? createdAt, partFlags: 0)
    }

    func testMarkerUpdateFailurePreservesOriginalContextAndAnchors() throws {
        try withDatabase { database in
            try schema(database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id) VALUES ('chat')")
            try NivoCloudChatSQL.mergeMarker(marker(createdAt: 1), database: database)
            try NivoSQLiteWrite.execute(database, sql: "CREATE TRIGGER fail_marker BEFORE UPDATE ON compact_markers BEGIN SELECT RAISE(ABORT, 'fixture'); END")
            XCTAssertThrowsError(try NivoCloudChatSQL.mergeMarker(marker(createdAt: 2), database: database))
            XCTAssertEqual(try text(database, "SELECT summary FROM compact_markers"), "context-1.0")
            XCTAssertEqual(try text(database, "SELECT last_compacted_message_id FROM compact_markers"), "anchor")
            XCTAssertEqual(try number(database, "SELECT created_at FROM compact_markers"), 1)
        }
    }

    func testMarkerOwnerConflictIsRejectedEvenWhenLocalIsNewer() throws {
        try withDatabase { database in
            try schema(database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id) VALUES ('chat'), ('other')")
            try NivoCloudChatSQL.mergeMarker(marker(createdAt: 2), database: database)
            XCTAssertThrowsError(try NivoCloudChatSQL.mergeMarker(marker(createdAt: 1, sessionID: "other"), database: database)) {
                XCTAssertEqual($0 as? NivoCloudChatSQLError, .messageOwnerChanged)
            }
            XCTAssertEqual(try text(database, "SELECT session_id FROM compact_markers"), "chat")
            XCTAssertEqual(try text(database, "SELECT summary FROM compact_markers"), "context-2.0")
        }
    }

    func testMarkerReplaysAfterParentAndOnlyNewerContextReplacesLocal() throws {
        try withDatabase { database in
            try schema(database)
            XCTAssertThrowsError(try NivoCloudChatSQL.mergeMarker(marker(createdAt: 1), database: database)) {
                XCTAssertEqual($0 as? NivoCloudChatSQLError, .missingSession)
            }
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO sessions(id) VALUES ('chat')")
            XCTAssertTrue(try NivoCloudChatSQL.mergeMarker(marker(createdAt: 1), database: database))
            XCTAssertTrue(try NivoCloudChatSQL.mergeMarker(marker(createdAt: 2), database: database))
            XCTAssertFalse(try NivoCloudChatSQL.mergeMarker(marker(createdAt: 1), database: database))
            XCTAssertFalse(try NivoCloudChatSQL.mergeMarker(marker(createdAt: 2), database: database))
            XCTAssertEqual(try text(database, "SELECT summary FROM compact_markers"), "context-2.0")
            XCTAssertEqual(try number(database, "SELECT count(*) FROM compact_markers"), 1)
        }
    }

    func testMarkerRespectsDeletedParentAndDeletedContext() throws {
        try withDatabase { database in
            try schema(database)
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO deleted_session_tombstones VALUES ('chat', 2)")
            XCTAssertFalse(try NivoCloudChatSQL.mergeMarker(marker(createdAt: 1), database: database))
            try NivoSQLiteWrite.execute(database, sql: "DELETE FROM deleted_session_tombstones")
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO deleted_record_tombstones VALUES ('CompactMarker', 'marker', 2)")
            XCTAssertFalse(try NivoCloudChatSQL.mergeMarker(marker(createdAt: 1), database: database))
            XCTAssertEqual(try number(database, "SELECT count(*) FROM compact_markers"), 0)
        }
    }

    private func marker(createdAt: Double, sessionID: String = "chat") -> NivoCloudChatSQL.Marker {
        .init(id: "marker", sessionID: sessionID, summary: "context-\(createdAt)", firstKeptSortOrder: 2,
            compactedCount: 2, createdAt: createdAt, uiBoundarySortOrder: nil,
            boundaryMessageID: nil, firstKeptMessageID: nil, lastCompactedMessageID: "anchor", version: 2)
    }

    private func withDatabase(_ body: (OpaquePointer) throws -> Void) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        try body(try XCTUnwrap(database))
    }

    private func schema(_ database: OpaquePointer) throws {
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE sessions(id TEXT PRIMARY KEY, folder_id TEXT)")
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE messages(id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT, parts_json TEXT, created_at REAL, token_usage TEXT, sort_order INTEGER, reasoning_content TEXT, stream_interrupt_count INTEGER, updated_at REAL, part_flags INTEGER, model_id TEXT, model_display_name TEXT, provider_type TEXT, provider_instance_id TEXT)")
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE folders(id TEXT PRIMARY KEY, name TEXT, icon TEXT, color TEXT, origin TEXT, sort_index INTEGER, pinned_at REAL, description TEXT, created_at REAL, updated_at REAL)")
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE deleted_session_tombstones(session_id TEXT PRIMARY KEY, deleted_at REAL)")
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE deleted_record_tombstones(record_type TEXT, record_id TEXT, deleted_at REAL, PRIMARY KEY(record_type, record_id))")
        try NivoSQLiteWrite.execute(database, sql: "CREATE TABLE compact_markers(id TEXT PRIMARY KEY, session_id TEXT NOT NULL, summary TEXT, first_kept_sort_order INTEGER, compacted_count INTEGER, created_at REAL, ui_boundary_sort_order INTEGER, boundary_message_id TEXT, first_kept_message_id TEXT, last_compacted_message_id TEXT, version INTEGER)")
    }

    private func text(_ database: OpaquePointer, _ sql: String) throws -> String? {
        try NivoSQLiteWrite.readRow(database, sql: sql) { statement in
            guard let value = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: value)
        } ?? nil
    }

    private func number(_ database: OpaquePointer, _ sql: String) throws -> Double {
        try XCTUnwrap(try NivoSQLiteWrite.readRow(database, sql: sql) { sqlite3_column_double($0, 0) })
    }
}
