import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 使用系统SQLite和真实WAL文件验证在线快照，不以JSON或内存镜像替代数据库。
final class NivoSQLiteSnapshotTests: XCTestCase {
    func testSnapshotIncludesCommittedWALAndRestoresThroughExistingConnection() throws {
        let root = try directory()
        let live = root.appendingPathComponent("live.db")
        let saved = root.appendingPathComponent("saved.db")
        try withDatabase(live) { database in
            try execute(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE items(value TEXT); INSERT INTO items VALUES('original');")
            XCTAssertTrue(FileManager.default.fileExists(atPath: live.path + "-wal"))
            try NivoSQLiteSnapshot.capture(from: database, to: saved)
            try execute(database, "DELETE FROM items; INSERT INTO items VALUES('imported');")
            try NivoSQLiteSnapshot.restore(from: saved, into: database)
            XCTAssertEqual(try scalar(database, "SELECT value FROM items"), "original")
            try NivoSQLiteSnapshot.validate(saved)
            try execute(database, "INSERT INTO items VALUES('after-restore');")
            XCTAssertEqual(try scalar(database, "SELECT count(*) FROM items"), "2")
        }
    }

    func testSnapshotRestoresAllTablesIncludingLocalRulesAndSettings() throws {
        let root = try directory()
        let saved = root.appendingPathComponent("saved.db")
        let restored = root.appendingPathComponent("new/live.db")
        try withDatabase(root.appendingPathComponent("source.db")) { database in
            try execute(database, "CREATE TABLE provider_instances(id TEXT); CREATE TABLE thinking_rules(rule TEXT); CREATE TABLE local_settings(value TEXT); INSERT INTO provider_instances VALUES('provider'); INSERT INTO thinking_rules VALUES('rule'); INSERT INTO local_settings VALUES('selection');")
            try NivoSQLiteSnapshot.capture(from: database, to: saved)
        }
        try NivoSQLiteSnapshot.restore(from: saved, to: restored)
        try withDatabase(restored) { database in
            XCTAssertEqual(try scalar(database, "SELECT id FROM provider_instances"), "provider")
            XCTAssertEqual(try scalar(database, "SELECT rule FROM thinking_rules"), "rule")
            XCTAssertEqual(try scalar(database, "SELECT value FROM local_settings"), "selection")
        }
    }

    func testCorruptSnapshotDoesNotChangeExistingDatabaseOrCreateMissingDestination() throws {
        let root = try directory()
        let saved = root.appendingPathComponent("corrupt.db")
        try Data("not-a-database".utf8).write(to: saved)
        try withDatabase(root.appendingPathComponent("live.db")) { database in
            try execute(database, "CREATE TABLE items(value TEXT); INSERT INTO items VALUES('keep');")
            XCTAssertThrowsError(try NivoSQLiteSnapshot.restore(from: saved, into: database))
            XCTAssertEqual(try scalar(database, "SELECT value FROM items"), "keep")
        }
        let absent = root.appendingPathComponent("missing.db")
        XCTAssertThrowsError(try NivoSQLiteSnapshot.restore(from: saved, to: absent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        XCTAssertEqual(try Data(contentsOf: saved), Data("not-a-database".utf8))
    }

    func testBusyDestinationFailsWithoutPartialRestoreAndCanRetry() throws {
        let root = try directory()
        let live = root.appendingPathComponent("live.db")
        let saved = root.appendingPathComponent("saved.db")
        try withDatabase(live) { database in
            try execute(database, "PRAGMA journal_mode=WAL; CREATE TABLE items(value TEXT); INSERT INTO items VALUES('original');")
            try NivoSQLiteSnapshot.capture(from: database, to: saved)
            try execute(database, "UPDATE items SET value='changed';")
            try withDatabase(live) { blocker in
                try execute(blocker, "BEGIN IMMEDIATE;")
                defer { _ = sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil) }
                XCTAssertThrowsError(try NivoSQLiteSnapshot.restore(from: saved, into: database))
                XCTAssertEqual(try scalar(database, "SELECT value FROM items"), "changed")
            }
            try NivoSQLiteSnapshot.restore(from: saved, into: database)
            XCTAssertEqual(try scalar(database, "SELECT value FROM items"), "original")
        }
    }

    func testEmptySnapshotCannotEraseLiveDatabase() throws {
        let root = try directory()
        let saved = root.appendingPathComponent("empty.db")
        try Data().write(to: saved)
        XCTAssertThrowsError(try NivoSQLiteSnapshot.validate(saved))
        try withDatabase(root.appendingPathComponent("live.db")) { database in
            try execute(database, "CREATE TABLE items(value TEXT); INSERT INTO items VALUES('keep');")
            XCTAssertThrowsError(try NivoSQLiteSnapshot.restore(from: saved, into: database))
            XCTAssertEqual(try scalar(database, "SELECT value FROM items"), "keep")
        }
        let absent = root.appendingPathComponent("missing.db")
        XCTAssertThrowsError(try NivoSQLiteSnapshot.restore(from: saved, to: absent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
    }

    func testActiveSourceTransactionCannotBecomeRollbackEvidence() throws {
        let root = try directory()
        let saved = root.appendingPathComponent("saved.db")
        try withDatabase(root.appendingPathComponent("live.db")) { database in
            try execute(database, "CREATE TABLE items(value TEXT); BEGIN IMMEDIATE; INSERT INTO items VALUES('uncommitted');")
            defer { _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
            XCTAssertThrowsError(try NivoSQLiteSnapshot.capture(from: database, to: saved))
            XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        }
    }

    func testSnapshotCannotOverwriteExistingFileOrItself() throws {
        let root = try directory()
        let live = root.appendingPathComponent("live.db")
        let saved = root.appendingPathComponent("saved.db")
        try Data("existing".utf8).write(to: saved)
        try withDatabase(live) { database in
            try execute(database, "CREATE TABLE items(value TEXT); INSERT INTO items VALUES('keep');")
            XCTAssertThrowsError(try NivoSQLiteSnapshot.capture(from: database, to: saved))
            XCTAssertThrowsError(try NivoSQLiteSnapshot.capture(from: database, to: live))
            XCTAssertThrowsError(try NivoSQLiteSnapshot.restore(from: live, into: database))
            XCTAssertEqual(try scalar(database, "SELECT value FROM items"), "keep")
        }
        XCTAssertEqual(try Data(contentsOf: saved), Data("existing".utf8))
    }

    func testRecoveryManifestRecognizesDatabaseAndRejectsCorruptSnapshotBeforeReturningActions() throws {
        let root = try directory()
        let rollback = root.appendingPathComponent("rollback-test")
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
        let saved = rollback.appendingPathComponent("providers.db")
        let live = root.appendingPathComponent("live.db")
        try withDatabase(live) { database in
            try execute(database, "CREATE TABLE items(value TEXT);")
            try NivoSQLiteSnapshot.capture(from: database, to: saved)
        }
        let sidecar = saved.appendingPathExtension("sqlite-path-of")
        try Data(live.path.utf8).write(to: sidecar)
        let entries = try NivoBackupRollbackFiles.entries(in: rollback, expectedNames: [saved.lastPathComponent, sidecar.lastPathComponent])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, .sqlite)
        try Data("corrupt".utf8).write(to: saved)
        XCTAssertThrowsError(try NivoBackupRollbackFiles.entries(in: rollback, expectedNames: nil))
    }

    func testStrictTransactionRollsBackDeleteWhenLaterRowViolatesForeignKey() throws {
        let root = try directory()
        try withDatabase(root.appendingPathComponent("strict.db")) { database in
            try execute(database, "PRAGMA foreign_keys=ON; CREATE TABLE providers(id TEXT PRIMARY KEY); CREATE TABLE entries(provider_id TEXT REFERENCES providers(id)); INSERT INTO providers VALUES('keep');")
            XCTAssertThrowsError(try NivoSQLiteWrite.transaction(database) {
                try NivoSQLiteWrite.execute(database, sql: "DELETE FROM providers")
                try NivoSQLiteWrite.execute(database, sql: "INSERT INTO entries VALUES(?)", values: [.text("missing")])
            })
            XCTAssertEqual(try scalar(database, "SELECT id FROM providers"), "keep")
            XCTAssertEqual(sqlite3_get_autocommit(database), 1)
        }
    }

    func testStrictTransactionRollsBackWhenDeferredConstraintFailsAtCommit() throws {
        let root = try directory()
        try withDatabase(root.appendingPathComponent("commit.db")) { database in
            try execute(database, "PRAGMA foreign_keys=ON; CREATE TABLE providers(id TEXT PRIMARY KEY); CREATE TABLE entries(provider_id TEXT REFERENCES providers(id) DEFERRABLE INITIALLY DEFERRED);")
            XCTAssertThrowsError(try NivoSQLiteWrite.transaction(database) {
                try NivoSQLiteWrite.execute(database, sql: "INSERT INTO entries VALUES(?)", values: [.text("missing")])
            })
            XCTAssertEqual(try scalar(database, "SELECT count(*) FROM entries"), "0")
            XCTAssertEqual(sqlite3_get_autocommit(database), 1)
        }
    }

    func testStrictTransactionRejectsNestedBeginAndDoesNotCommitOuterWork() throws {
        let root = try directory()
        try withDatabase(root.appendingPathComponent("nested.db")) { database in
            try execute(database, "CREATE TABLE items(value TEXT); BEGIN IMMEDIATE; INSERT INTO items VALUES('uncommitted');")
            XCTAssertThrowsError(try NivoSQLiteWrite.transaction(database) {
                try NivoSQLiteWrite.execute(database, sql: "DELETE FROM items")
            })
            XCTAssertEqual(sqlite3_get_autocommit(database), 0)
            try execute(database, "ROLLBACK")
            XCTAssertEqual(try scalar(database, "SELECT count(*) FROM items"), "0")
        }
    }

    func testStrictWriteRejectsPrepareAndBindingFailuresWithoutPartialTransaction() throws {
        let root = try directory()
        try withDatabase(root.appendingPathComponent("binding.db")) { database in
            try execute(database, "CREATE TABLE items(value TEXT); INSERT INTO items VALUES('keep');")
            XCTAssertThrowsError(try NivoSQLiteWrite.transaction(database) {
                try NivoSQLiteWrite.execute(database, sql: "DELETE FROM items")
                try NivoSQLiteWrite.execute(database, sql: "INSERT INTO nonexistent VALUES('bad')")
            })
            XCTAssertThrowsError(try NivoSQLiteWrite.execute(database, sql: "INSERT INTO items VALUES(?)"))
            // SQLite长度限制触发真实bind失败，不能退化成插入NULL。
            let priorLimit = sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 128)
            XCTAssertThrowsError(try NivoSQLiteWrite.execute(database, sql: "INSERT INTO items VALUES(?)",
                                                            values: [.text(String(repeating: "x", count: 256))]))
            _ = sqlite3_limit(database, SQLITE_LIMIT_LENGTH, priorLimit)
            XCTAssertEqual(try scalar(database, "SELECT value FROM items"), "keep")
        }
    }

    func testStrictTransactionCommitsUnicodeNullAndNumericValues() throws {
        let root = try directory()
        try withDatabase(root.appendingPathComponent("values.db")) { database in
            try execute(database, "CREATE TABLE items(value TEXT, optional TEXT, count INTEGER, amount REAL)")
            try NivoSQLiteWrite.transaction(database) {
                try NivoSQLiteWrite.execute(database, sql: "INSERT INTO items VALUES(?, ?, ?, ?)",
                                            values: [.text("中文模型"), .text(nil), .integer(42), .real(1.5)])
            }
            XCTAssertEqual(try scalar(database, "SELECT value FROM items"), "中文模型")
            XCTAssertEqual(try scalar(database, "SELECT optional IS NULL FROM items"), "1")
            XCTAssertEqual(try scalar(database, "SELECT count FROM items"), "42")
            XCTAssertEqual(try scalar(database, "SELECT amount FROM items"), "1.5")
        }
    }

    func testStrictRowReadDistinguishesMissingRecordFromBrokenSchema() throws {
        let root = try directory()
        try withDatabase(root.appendingPathComponent("read.db")) { database in
            try execute(database, "CREATE TABLE items(id TEXT PRIMARY KEY, stamp REAL); INSERT INTO items VALUES('existing', 3.5)")
            let existing = try NivoSQLiteWrite.readRow(database, sql: "SELECT stamp FROM items WHERE id=?",
                values: [.text("existing")]) { sqlite3_column_double($0, 0) }
            let missing = try NivoSQLiteWrite.readRow(database, sql: "SELECT stamp FROM items WHERE id=?",
                values: [.text("absent")]) { sqlite3_column_double($0, 0) }
            XCTAssertEqual(existing, 3.5)
            XCTAssertNil(missing)
            XCTAssertThrowsError(try NivoSQLiteWrite.readRow(database,
                sql: "SELECT stamp FROM absent_table") { sqlite3_column_double($0, 0) })
        }
    }

    func testStrictRowReadRejectsBindingFailureInsteadOfReturningMissing() throws {
        let root = try directory()
        try withDatabase(root.appendingPathComponent("read-bind.db")) { database in
            XCTAssertThrowsError(try NivoSQLiteWrite.readRow(database, sql: "SELECT ?") { sqlite3_column_int($0, 0) })
            let priorLimit = sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 128)
            defer { _ = sqlite3_limit(database, SQLITE_LIMIT_LENGTH, priorLimit) }
            XCTAssertThrowsError(try NivoSQLiteWrite.readRow(database, sql: "SELECT ?",
                values: [.text(String(repeating: "x", count: 256))]) { sqlite3_column_int($0, 0) })
        }
    }

    func testStrictSingleRowReadRejectsMultipleRows() throws {
        let root = try directory()
        try withDatabase(root.appendingPathComponent("read-count.db")) { database in
            XCTAssertThrowsError(try NivoSQLiteWrite.readRow(database,
                sql: "SELECT 1 UNION ALL SELECT 2") { sqlite3_column_int($0, 0) })
            XCTAssertThrowsError(try NivoSQLiteWrite.execute(database, sql: ""))
        }
    }

    func testStrictRowsReadReturnsOrderedValuesAndSuccessfulEmptyResult() throws {
        let root = try directory()
        try withDatabase(root.appendingPathComponent("rows.db")) { database in
            try execute(database, "CREATE TABLE items(id INTEGER, title TEXT); INSERT INTO items VALUES(2, '模型乙'), (1, '模型甲')")
            let rows = try NivoSQLiteWrite.readRows(database, sql: "SELECT title FROM items WHERE id > ? ORDER BY id",
                values: [.integer(0)]) { String(cString: sqlite3_column_text($0, 0)) }
            let empty = try NivoSQLiteWrite.readRows(database, sql: "SELECT id FROM items WHERE id > ?",
                values: [.integer(3)]) { sqlite3_column_int($0, 0) }
            XCTAssertEqual(rows, ["模型甲", "模型乙"])
            XCTAssertEqual(empty, [])
        }
    }

    func testStrictRowsReadThrowsOnSecondRowSQLErrorInsteadOfReturningPartialData() throws {
        let root = try directory()
        try withDatabase(root.appendingPathComponent("rows-error.db")) { database in
            try execute(database, "CREATE TABLE items(id INTEGER); INSERT INTO items VALUES(1), (2)")
            var decoded = 0
            XCTAssertThrowsError(try NivoSQLiteWrite.readRows(database,
                sql: "SELECT CASE WHEN id=1 THEN 1 ELSE abs(-9223372036854775808) END FROM items") { statement in
                    decoded += 1
                    return sqlite3_column_int(statement, 0)
                })
            XCTAssertEqual(decoded, 1)
            XCTAssertEqual(try scalar(database, "SELECT COUNT(*) FROM items"), "2")
        }
    }

    func testStrictRowsReadPropagatesDecoderFailureAndFinalizesStatement() throws {
        let root = try directory()
        try withDatabase(root.appendingPathComponent("rows-decode.db")) { database in
            try execute(database, "CREATE TABLE items(id INTEGER); INSERT INTO items VALUES(1), (2)")
            XCTAssertThrowsError(try NivoSQLiteWrite.readRows(database, sql: "SELECT id FROM items") { statement -> Int32 in
                let value = sqlite3_column_int(statement, 0)
                if value == 2 { throw CocoaError(.coderReadCorrupt) }
                return value
            })
            XCTAssertNil(sqlite3_next_stmt(database, nil))
            try NivoSQLiteWrite.execute(database, sql: "INSERT INTO items VALUES(?)", values: [.integer(3)])
            XCTAssertEqual(try scalar(database, "SELECT COUNT(*) FROM items"), "3")
        }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-snapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func withDatabase(_ path: URL, body: (OpaquePointer) throws -> Void) throws {
        var connection: OpaquePointer?
        let code = sqlite3_open_v2(path.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        defer { if let connection { sqlite3_close(connection) } }
        guard code == SQLITE_OK, let connection else { throw NivoSQLiteSnapshotError.sqlite(operation: "test_open", code: code) }
        try body(connection)
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        let code = sqlite3_exec(database, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw NivoSQLiteSnapshotError.sqlite(operation: "test_exec", code: code) }
    }

    private func scalar(_ database: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw NivoSQLiteSnapshotError.sqlite(operation: "test_read", code: sqlite3_errcode(database))
        }
        return String(cString: value)
    }
}
