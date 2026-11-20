import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 使用系统SQLite和真实WAL文件验证在线快照，不以JSON或内存镜像替代数据库。
final class NivoSQLiteSnapshotTests: XCTestCase {
    /// 新快照不能接管同名旧辅助文件，否则封存清理可能误删不属于本次捕获的材料。
    func testCaptureRejectsPreexistingCompanionsWithoutTouchingThem() throws {
        let root = try directory()
        try withDatabase(root.appendingPathComponent("source.db")) { database in
            try execute(database, "PRAGMA journal_mode=WAL; CREATE TABLE items(value TEXT); INSERT INTO items VALUES('original');")
            for suffix in ["-wal", "-shm"] {
                let saved = root.appendingPathComponent("saved" + suffix + ".db")
                let companion = URL(fileURLWithPath: saved.path + suffix)
                let original = Data("preexisting-material".utf8)
                try original.write(to: companion)
                XCTAssertThrowsError(try NivoSQLiteSnapshot.capture(from: database, to: saved))
                XCTAssertEqual(try Data(contentsOf: companion), original)
                XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
            }
            let saved = root.appendingPathComponent("directory.db")
            let companion = URL(fileURLWithPath: saved.path + "-shm")
            try FileManager.default.createDirectory(at: companion, withIntermediateDirectories: false)
            XCTAssertThrowsError(try NivoSQLiteSnapshot.capture(from: database, to: saved))
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: companion.path)[.type] as? FileAttributeType,
                           .typeDirectory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
            #if !os(Windows)
            // 悬空链接的fileExists为false，仍不能被当成本次可创建的路径。
            let linkedSnapshot = root.appendingPathComponent("linked.db")
            let linkedCompanion = URL(fileURLWithPath: linkedSnapshot.path + "-wal")
            try FileManager.default.createSymbolicLink(at: linkedCompanion,
                withDestinationURL: root.appendingPathComponent("absent-target"))
            XCTAssertThrowsError(try NivoSQLiteSnapshot.capture(from: database, to: linkedSnapshot))
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: linkedCompanion.path)[.type] as? FileAttributeType,
                           .typeSymbolicLink)
            XCTAssertFalse(FileManager.default.fileExists(atPath: linkedSnapshot.path))
            #endif
            XCTAssertEqual(try scalar(database, "SELECT value FROM items"), "original")
        }
    }

    /// 旧版只读校验产生的辅助文件不在日志清单中，升级恢复仍须完整读取这份快照。
    func testLegacyWALValidationCompanionsRemainRecoverable() throws {
        let root = try directory()
        let rollback = root.appendingPathComponent("rollback-legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
        let saved = rollback.appendingPathComponent("providers.db")
        let live = root.appendingPathComponent("live.db")
        try withDatabase(saved) { database in
            try execute(database, "PRAGMA journal_mode=WAL; CREATE TABLE items(value TEXT); INSERT INTO items VALUES('original');")
        }
        let sidecar = saved.appendingPathExtension("sqlite-path-of")
        try Data(live.path.utf8).write(to: sidecar)
        let names = [saved.lastPathComponent, sidecar.lastPathComponent].sorted()
        try NivoSQLiteSnapshot.validate(saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path + "-wal"))
        let entries = try NivoBackupRollbackFiles.entries(in: rollback, expectedNames: names)
        XCTAssertEqual(entries.count, 1)
        try NivoSQLiteSnapshot.restore(from: saved, to: live)
        try withDatabase(live) { database in
            XCTAssertEqual(try scalar(database, "SELECT value FROM items"), "original")
        }
        XCTAssertEqual(try NivoBackupRollbackFiles.entries(in: rollback, expectedNames: names).count, 1)
    }

    /// 兼容旧清单不能通过删除WAL实现，其中尚未合入主文件的已提交数据必须恢复。
    func testLegacyWALCompanionsRetainCommittedRowsDuringRecovery() throws {
        let root = try directory()
        let rollback = root.appendingPathComponent("rollback-legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
        let saved = rollback.appendingPathComponent("providers.db")
        let live = root.appendingPathComponent("live.db")
        let sidecar = saved.appendingPathExtension("sqlite-path-of")
        try Data(live.path.utf8).write(to: sidecar)
        let names = [saved.lastPathComponent, sidecar.lastPathComponent].sorted()
        try withDatabase(saved) { database in
            try execute(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE items(value TEXT); INSERT INTO items VALUES('base'); PRAGMA wal_checkpoint(TRUNCATE); INSERT INTO items VALUES('wal-only');")
            XCTAssertGreaterThan(try Data(contentsOf: URL(fileURLWithPath: saved.path + "-wal")).count, 32)
            XCTAssertEqual(try NivoBackupRollbackFiles.entries(in: rollback, expectedNames: names).count, 1)
            try NivoSQLiteSnapshot.restore(from: saved, to: live)
            try withDatabase(live) { restored in
                XCTAssertEqual(try scalar(restored, "SELECT COUNT(*) FROM items"), "2")
                XCTAssertEqual(try scalar(restored, "SELECT value FROM items WHERE value='wal-only'"), "wal-only")
            }
            let unexpected = rollback.appendingPathComponent("other.db-wal")
            try Data().write(to: unexpected)
            XCTAssertThrowsError(try NivoBackupRollbackFiles.entries(in: rollback, expectedNames: names))
            try FileManager.default.removeItem(at: unexpected)
            XCTAssertThrowsError(try NivoBackupRollbackFiles.entries(in: rollback, expectedNames: names + ["missing"]))
            try FileManager.default.removeItem(at: sidecar)
            XCTAssertThrowsError(try NivoBackupRollbackFiles.entries(in: rollback, expectedNames: names))
        }
    }

    /// 非WAL快照不能借辅助文件规则隐藏清单外内容。
    func testSealedSnapshotRejectsUnregisteredWALCompanion() throws {
        let root = try directory()
        let rollback = root.appendingPathComponent("rollback-sealed", isDirectory: true)
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
        let saved = rollback.appendingPathComponent("providers.db")
        let live = root.appendingPathComponent("live.db")
        try withDatabase(saved) { try execute($0, "CREATE TABLE items(value TEXT);") }
        let sidecar = saved.appendingPathExtension("sqlite-path-of")
        try Data(live.path.utf8).write(to: sidecar)
        try Data().write(to: URL(fileURLWithPath: saved.path + "-wal"))
        XCTAssertThrowsError(try NivoBackupRollbackFiles.entries(in: rollback,
            expectedNames: [saved.lastPathComponent, sidecar.lastPathComponent]))
    }

    func testLegacyWALCompanionCannotBeDirectoryOrSymbolicLink() throws {
        let root = try directory()
        let rollback = root.appendingPathComponent("rollback-legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
        let saved = rollback.appendingPathComponent("providers.db")
        try withDatabase(saved) {
            try execute($0, "PRAGMA journal_mode=WAL; CREATE TABLE items(value TEXT); PRAGMA wal_checkpoint(TRUNCATE);")
        }
        // Apple的SQLite可能在关闭后保留空辅助文件；只清理本测试已checkpoint且关闭的夹具。
        for suffix in ["-wal", "-shm"] {
            let fixture = URL(fileURLWithPath: saved.path + suffix)
            if FileManager.default.fileExists(atPath: fixture.path) { try FileManager.default.removeItem(at: fixture) }
        }
        let sidecar = saved.appendingPathExtension("sqlite-path-of")
        try Data(root.appendingPathComponent("live.db").path.utf8).write(to: sidecar)
        let names = [saved.lastPathComponent, sidecar.lastPathComponent]
        let companion = URL(fileURLWithPath: saved.path + "-wal")
        try FileManager.default.createDirectory(at: companion, withIntermediateDirectories: false)
        XCTAssertThrowsError(try NivoBackupRollbackFiles.entries(in: rollback, expectedNames: names))
        try FileManager.default.removeItem(at: companion)
        #if !os(Windows)
        // Windows普通进程不能创建符号链接；Apple平台实际执行这一边界，目录检查在所有平台运行。
        let outside = root.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: companion, withDestinationURL: outside)
        XCTAssertThrowsError(try NivoBackupRollbackFiles.entries(in: rollback, expectedNames: names))
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
        #endif
    }

    /// 串起新增配置实际使用的快照、日志、写入和清理边界，保留真实文件与SQLite。
    @MainActor
    func testFreshProviderSaveCommitsThroughWALSnapshotAndRecoveryJournal() async throws {
        let root = try directory()
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let rollback = support.appendingPathComponent("rollback-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
        let live = root.appendingPathComponent("provider-config.db")
        let saved = rollback.appendingPathComponent("providers-provider-config.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(live.path, &database), SQLITE_OK)
        let connection = try XCTUnwrap(database)
        defer { sqlite3_close(connection) }
        try execute(connection, "PRAGMA journal_mode=WAL; CREATE TABLE providers(id TEXT PRIMARY KEY);")
        try NivoSQLiteSnapshot.capture(from: connection, to: saved)
        try Data(live.path.utf8).write(to: saved.appendingPathExtension("sqlite-path-of"))
        let names = try FileManager.default.contentsOfDirectory(atPath: rollback.path).sorted()
        _ = try NivoBackupRollbackFiles.entries(in: rollback, expectedNames: names)
        let markerFile = support.appendingPathComponent("in-progress.json")
        let marker = NivoBackupRecoveryState.Marker(backupId: "provider-json-provider", startedAt: Date(),
            categories: ["providers"], runId: "provider", snapshotNames: names,
            credentialRestore: .init(identifier: UUID(), targets: []),
            providerSetupQueue: .init(changes: []))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: markerFile, options: .atomic)
        try await NivoProviderImportCommit.run(writeCredentials: {}, persist: {
            try self.execute(connection, "INSERT INTO providers VALUES('custom');")
        }, finish: {
            let persisted = try XCTUnwrap(NivoBackupRecoveryState.read(markerFile).marker)
            XCTAssertEqual(persisted.runId, "provider")
            try NivoBackupRollbackFiles.finish(marker: markerFile, root: rollback)
        }, isPending: { NivoBackupRecoveryState.read(markerFile).requiresRecovery }, rollback: {
            try NivoSQLiteSnapshot.restore(from: saved, into: connection)
        })
        XCTAssertEqual(try scalar(connection, "SELECT id FROM providers"), "custom")
        XCTAssertFalse(NivoBackupRecoveryState.read(markerFile).requiresRecovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollback.path))
    }

    /// 提供商使用WAL库；快照从准备到恢复都必须匹配同一份完整目录清单。
    func testProviderWALSnapshotKeepsRecoveryManifestStableAcrossValidation() throws {
        let root = try directory()
        let rollback = root.appendingPathComponent("rollback-provider", isDirectory: true)
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
        let saved = rollback.appendingPathComponent("providers-provider-config.db")
        let live = root.appendingPathComponent("provider-config.db")
        try withDatabase(live) { database in
            try execute(database, "PRAGMA journal_mode=WAL; CREATE TABLE items(value TEXT); INSERT INTO items VALUES('original');")
            try NivoSQLiteSnapshot.capture(from: database, to: saved)
            XCTAssertEqual(try scalar(database, "PRAGMA journal_mode"), "wal")
            let sidecar = saved.appendingPathExtension("sqlite-path-of")
            try Data(live.path.utf8).write(to: sidecar)
            let names = try FileManager.default.contentsOfDirectory(atPath: rollback.path).sorted()
            XCTAssertEqual(names, [saved.lastPathComponent, sidecar.lastPathComponent].sorted())
            let prepared = try NivoBackupRollbackFiles.entries(in: rollback, expectedNames: names)
            XCTAssertEqual(prepared.count, 1)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rollback.path).sorted(), names)
            let recovered = try NivoBackupRollbackFiles.entries(in: rollback, expectedNames: names)
            XCTAssertEqual(recovered.first?.kind, .sqlite)
            try execute(database, "UPDATE items SET value='changed';")
            try NivoSQLiteSnapshot.restore(from: saved, into: database)
            XCTAssertEqual(try scalar(database, "SELECT value FROM items"), "original")
            XCTAssertEqual(try scalar(database, "PRAGMA journal_mode"), "wal")
        }
    }

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
