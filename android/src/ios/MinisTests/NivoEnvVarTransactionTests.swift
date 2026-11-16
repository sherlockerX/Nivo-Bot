import XCTest
@testable import Minis

/// 使用真实文件验证恢复协议；凭证适配器只注入失败，不代表Apple Keychain验证通过。
final class NivoEnvVarTransactionTests: XCTestCase {
    func testPreparedJournalWithoutStagedCredentialAbortsWithoutChangingMetadata() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try fixture.run(failingAt: .journalSaved))
        XCTAssertNotNil(try fixture.transaction.pending())
        XCTAssertNil(try fixture.transaction.recover(using: fixture.credentials))
        XCTAssertEqual(try NivoEnvVarState.read(fixture.url), [fixture.old])
        XCTAssertNil(try fixture.transaction.pending())
    }

    func testRestartAfterStagingFinishesRenameAndPreservesSecretOutsideJournal() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try fixture.run(failingAt: .credentialStaged))
        let journal = try String(contentsOf: fixture.transaction.journalURL, encoding: .utf8)
        XCTAssertFalse(journal.contains("fixture-secret"))
        let restarted = NivoEnvVarTransaction(fileURL: fixture.url)
        let receipt = try XCTUnwrap(restarted.recover(using: fixture.credentials))
        XCTAssertEqual(try NivoEnvVarState.read(fixture.url), [fixture.new])
        XCTAssertEqual(fixture.vault.values["NEW_NAME"], "fixture-secret")
        XCTAssertNil(fixture.vault.values["OLD_NAME"])
        XCTAssertEqual(receipt.changes, [.init(id: "entry", operation: .upsert)])
        try restarted.finish(identifier: receipt.identifier)
        XCTAssertNil(try restarted.pending())
    }

    func testRestartAfterSecretWriteReplaysMetadataWithoutLosingOldCleanupTarget() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try fixture.run(failingAt: .secretApplied))
        XCTAssertEqual(try NivoEnvVarState.read(fixture.url), [fixture.old])
        XCTAssertNotNil(fixture.vault.values["OLD_NAME"])
        let receipt = try XCTUnwrap(fixture.transaction.recover(using: fixture.credentials))
        XCTAssertEqual(try NivoEnvVarState.read(fixture.url), [fixture.new])
        XCTAssertNil(fixture.vault.values["OLD_NAME"])
        try fixture.transaction.finish(identifier: receipt.identifier)
    }

    func testMetadataCommitBeforeJournalPhaseCanBeRecovered() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try fixture.run(failingAt: .metadataSaved))
        XCTAssertEqual(try NivoEnvVarState.read(fixture.url), [fixture.new])
        XCTAssertNotNil(fixture.vault.values["OLD_NAME"])
        XCTAssertNotNil(try fixture.transaction.recover(using: fixture.credentials))
        XCTAssertNil(fixture.vault.values["OLD_NAME"])
    }

    func testFailedDeletionCleanupRetainsReceiptUntilRetry() throws {
        let fixture = try fixture()
        fixture.vault.failsCleanup = true
        XCTAssertThrowsError(try fixture.transaction.run(after: [], writeKey: nil, notifySync: true,
            prepare: fixture.stage, using: fixture.credentials))
        XCTAssertEqual(try NivoEnvVarState.read(fixture.url), [])
        XCTAssertNotNil(fixture.vault.values["OLD_NAME"])
        XCTAssertEqual(try fixture.transaction.pending()?.phase, .committed)
        fixture.vault.failsCleanup = false
        let receipt = try XCTUnwrap(fixture.transaction.recover(using: fixture.credentials))
        XCTAssertEqual(receipt.changes, [.init(id: "entry", operation: .delete)])
        XCTAssertNil(fixture.vault.values["OLD_NAME"])
        try fixture.transaction.finish(identifier: receipt.identifier)
    }

    func testSyncFailureKeepsReceiptAndPreventsNextMutation() throws {
        let fixture = try fixture()
        let receipt = try XCTUnwrap(fixture.run())
        XCTAssertEqual(receipt.phase, .awaitingSync)
        XCTAssertThrowsError(try fixture.transaction.requireSettled())
        XCTAssertThrowsError(try fixture.run())
        XCTAssertThrowsError(try fixture.transaction.finish(identifier: UUID()))
        XCTAssertNotNil(try fixture.transaction.recover(using: fixture.credentials))
        try fixture.transaction.finish(identifier: receipt.identifier)
        XCTAssertNoThrow(try fixture.transaction.requireSettled())
    }

    func testDiscardFailureCanRetryAfterStageHasAlreadyBeenRemoved() throws {
        let fixture = try fixture()
        fixture.vault.failsDiscardAfterRemoving = true
        XCTAssertThrowsError(try fixture.run())
        XCTAssertEqual(try fixture.transaction.pending()?.phase, .awaitingSync)
        fixture.vault.failsDiscardAfterRemoving = false
        XCTAssertNotNil(try fixture.transaction.recover(using: fixture.credentials))
    }

    func testRemoteChangeDoesNotEchoOrLeaveReceiptAfterRecovery() throws {
        let fixture = try fixture()
        XCTAssertNil(try fixture.transaction.run(after: [fixture.new], writeKey: "NEW_NAME", notifySync: false,
            prepare: fixture.stage, using: fixture.credentials))
        XCTAssertNil(try fixture.transaction.pending())
        XCTAssertEqual(try NivoEnvVarState.read(fixture.url), [fixture.new])
    }

    func testUnexpectedMetadataIsPreservedAndRecoveryRefusesToOverwriteIt() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try fixture.run(failingAt: .credentialStaged))
        let other = [EnvVarEntry(id: "other", key: "OTHER")]
        try NivoEnvVarState.save(other, to: fixture.url)
        XCTAssertThrowsError(try fixture.transaction.recover(using: fixture.credentials))
        XCTAssertEqual(try NivoEnvVarState.read(fixture.url), other)
        XCTAssertNotNil(try fixture.transaction.pending())
    }

    func testCorruptJournalCannotBeTreatedAsMissingOrOverwritten() throws {
        let fixture = try fixture()
        let corrupt = Data("{invalid".utf8)
        try corrupt.write(to: fixture.transaction.journalURL)
        XCTAssertThrowsError(try fixture.transaction.pending())
        XCTAssertThrowsError(try fixture.run())
        XCTAssertEqual(try Data(contentsOf: fixture.transaction.journalURL), corrupt)
        XCTAssertEqual(try NivoEnvVarState.read(fixture.url), [fixture.old])
    }

    func testMissingStageAfterCommitBlocksCleanupRatherThanForgettingCredentials() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try fixture.run(failingAt: .commitRecorded))
        fixture.vault.staged.removeAll()
        XCTAssertThrowsError(try fixture.transaction.recover(using: fixture.credentials))
        XCTAssertNotNil(fixture.vault.values["OLD_NAME"])
        XCTAssertNotNil(try fixture.transaction.pending())
    }

    func testRenameRejectsUnrelatedCredentialTargetBeforeStaging() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try fixture.transaction.run(after: [fixture.new], writeKey: "UNRELATED", notifySync: true,
            prepare: fixture.stage, using: fixture.credentials))
        XCTAssertTrue(fixture.vault.staged.isEmpty)
        XCTAssertNil(try fixture.transaction.pending())
    }

    /// 旧协议可能先到元数据后到凭证，同一版本补缺失值也需要可恢复的日志。
    func testLegacyMissingSecretCanRecoverWithoutChangingExistingMetadata() throws {
        let fixture = try fixture()
        fixture.vault.values.removeAll()
        XCTAssertThrowsError(try fixture.transaction.run(after: [fixture.old], writeKey: "OLD_NAME", notifySync: false,
            prepare: fixture.stage, using: fixture.credentials,
            checkpoint: { if $0 == .credentialStaged { throw CocoaError(.fileWriteUnknown) } }))
        XCTAssertNotNil(try fixture.transaction.pending())
        XCTAssertNil(try fixture.transaction.recover(using: fixture.credentials))
        XCTAssertEqual(fixture.vault.values["OLD_NAME"], "fixture-secret")
        XCTAssertEqual(try NivoEnvVarState.read(fixture.url), [fixture.old])
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ev-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return try Fixture(url: root.appendingPathComponent("env.json"))
    }

    /// 只保存测试占位值，系统Keychain的权限、同步和匹配行为由Apple宿主测试覆盖。
    private final class Vault {
        var staged: Set<UUID> = []
        var values = ["OLD_NAME": "fixture-secret"]
        var failsCleanup = false
        var failsDiscardAfterRemoving = false
    }

    private final class Fixture {
        let url: URL
        let transaction: NivoEnvVarTransaction
        let vault = Vault()
        let old = EnvVarEntry(id: "entry", key: "OLD_NAME", createdAt: Date(timeIntervalSince1970: 1))
        let new = EnvVarEntry(id: "entry", key: "NEW_NAME", createdAt: Date(timeIntervalSince1970: 1),
                              updatedAt: Date(timeIntervalSince1970: 2))

        init(url: URL) throws {
            self.url = url
            transaction = NivoEnvVarTransaction(fileURL: url)
            try NivoEnvVarState.save([old], to: url)
        }

        var credentials: NivoEnvVarTransaction.Credentials {
            .init(contains: { self.vault.staged.contains($0) }, apply: { journal in
                if let key = journal.writeKey { self.vault.values[key] = "fixture-secret" }
            }, cleanup: { journal in
                if self.vault.failsCleanup { throw CocoaError(.fileWriteUnknown) }
                for key in journal.cleanupKeys { self.vault.values.removeValue(forKey: key) }
            }, discard: { identifier in
                self.vault.staged.remove(identifier)
                if self.vault.failsDiscardAfterRemoving { throw CocoaError(.fileWriteUnknown) }
            })
        }

        func stage(_ journal: NivoEnvVarTransaction.Journal) throws { vault.staged.insert(journal.identifier) }

        func run(failingAt point: NivoEnvVarTransaction.Checkpoint? = nil) throws -> NivoEnvVarTransaction.Journal? {
            try transaction.run(after: [new], writeKey: "NEW_NAME", notifySync: true, prepare: stage,
                using: credentials, checkpoint: { if $0 == point { throw CocoaError(.fileWriteUnknown) } })
        }
    }
}
