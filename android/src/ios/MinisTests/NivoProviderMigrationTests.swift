import XCTest
@testable import Minis

/// 使用真实日志文件验证中断阶段，配置和凭证适配器仅注入故障。
@MainActor
final class NivoProviderMigrationTests: XCTestCase {
    func testRetryUsesOriginalIdentifiers() throws {
        let journal = try fixture()
        let original = try journal.prepare(targets: ["geminiOAuth": "fixture-original"])
        let retried = try journal.prepare(targets: ["geminiOAuth": "fixture-new"])
        XCTAssertEqual(retried, original)
    }

    func testCorruptedJournalIsRetainedAndNotRegenerated() throws {
        let journal = try fixture()
        let corrupt = Data("{incomplete".utf8)
        try corrupt.write(to: journal.fileURL)
        XCTAssertThrowsError(try journal.prepare(targets: [:]))
        XCTAssertEqual(try Data(contentsOf: journal.fileURL), corrupt)
    }

    func testInvalidMappingIsRejectedBeforePersistence() throws {
        let journal = try fixture()
        XCTAssertThrowsError(try journal.prepare(targets: ["unexpected-slot": "fixture"]))
        XCTAssertNil(try journal.read())
        XCTAssertThrowsError(try journal.prepare(targets: ["geminiOAuth": "same", "openAIOAuth": "same"]))
    }

    func testConfigurationFailureKeepsSourcesAndPendingPlan() async throws {
        let journal = try fixture()
        let plan = try journal.prepare(targets: ["geminiOAuth": "fixture"])
        var prepared = false
        do {
            try await NivoProviderMigrationTransaction.run(journal: journal, plan: plan,
                prepareCredentials: { prepared = true },
                persistConfiguration: { throw CocoaError(.fileWriteUnknown) },
                verifyCredentials: { XCTFail("保存失败不得继续确认") },
                cleanupLegacy: { XCTFail("保存失败不得删除旧凭证") })
            XCTFail("写盘错误必须传播")
        } catch {}
        XCTAssertTrue(prepared)
        XCTAssertEqual(try journal.read()?.phase, .prepared)
    }

    func testCredentialFailurePreventsConfigurationAndCleanup() async throws {
        let journal = try fixture()
        let plan = try journal.prepare(targets: [:])
        do {
            try await NivoProviderMigrationTransaction.run(journal: journal, plan: plan,
                prepareCredentials: { throw NivoOAuthPersistenceError.verificationFailed },
                persistConfiguration: { XCTFail() }, verifyCredentials: { XCTFail() }, cleanupLegacy: { XCTFail() })
            XCTFail("凭证失败必须传播")
        } catch {}
        XCTAssertEqual(try journal.read()?.phase, .prepared)
    }

    func testPostCommitCredentialConflictDoesNotDeleteLegacyValue() async throws {
        let journal = try fixture()
        let plan = try journal.prepare(targets: [:])
        do {
            try await NivoProviderMigrationTransaction.run(journal: journal, plan: plan,
                prepareCredentials: {}, persistConfiguration: {},
                verifyCredentials: { throw NivoOAuthPersistenceError.conflictingCredential },
                cleanupLegacy: { XCTFail() })
            XCTFail("凭证冲突必须传播")
        } catch {}
        XCTAssertEqual(try journal.read()?.phase, .prepared)
    }

    func testCleanupFailureResumesBeforeMarkingComplete() async throws {
        let journal = try fixture()
        let plan = try journal.prepare(targets: ["openAIOAuth": "fixture"])
        do {
            try await NivoProviderMigrationTransaction.run(journal: journal, plan: plan,
                prepareCredentials: {}, persistConfiguration: {}, verifyCredentials: {},
                cleanupLegacy: { throw CocoaError(.fileWriteUnknown) })
            XCTFail("清理失败不能标记完成")
        } catch {}
        let pending = try XCTUnwrap(journal.read())
        XCTAssertEqual(pending.phase, .configurationSaved)
        var order: [String] = []
        try await NivoProviderMigrationTransaction.run(journal: journal, plan: pending,
            prepareCredentials: { order.append("credentials") }, persistConfiguration: { order.append("configuration") },
            verifyCredentials: { order.append("verify") }, cleanupLegacy: { order.append("cleanup") })
        XCTAssertEqual(order, ["credentials", "configuration", "verify", "cleanup"])
        XCTAssertEqual(try journal.read()?.phase, .completed)
        XCTAssertEqual(try journal.read()?.targets, plan.targets)
    }

    func testCompletedJournalDoesNotRepeatMutation() async throws {
        let journal = try fixture()
        let plan = try journal.prepare(targets: [:])
        let done = try journal.advance(plan, to: .completed)
        try await NivoProviderMigrationTransaction.run(journal: journal, plan: done,
            prepareCredentials: { XCTFail() }, persistConfiguration: { XCTFail() },
            verifyCredentials: { XCTFail() }, cleanupLegacy: { XCTFail() })
    }

    func testChangedJournalRejectsLateCompletion() throws {
        let journal = try fixture()
        let plan = try journal.prepare(targets: [:])
        _ = try journal.advance(plan, to: .configurationSaved)
        XCTAssertThrowsError(try journal.advance(plan, to: .completed))
        XCTAssertEqual(try journal.read()?.phase, .configurationSaved)
    }

    func testStalePlanCannotWriteCredentialsBeforeCheckingJournal() async throws {
        let journal = try fixture()
        let original = try journal.prepare(targets: [:])
        _ = try journal.advance(original, to: .configurationSaved)
        var touchedCredentials = false
        do {
            try await NivoProviderMigrationTransaction.run(journal: journal, plan: original,
                prepareCredentials: { touchedCredentials = true }, persistConfiguration: {},
                verifyCredentials: {}, cleanupLegacy: {})
            XCTFail("旧计划必须被拒绝")
        } catch {}
        XCTAssertFalse(touchedCredentials)
    }

    private func fixture() throws -> NivoProviderMigrationJournal {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return NivoProviderMigrationJournal(fileURL: root.appendingPathComponent("migration.json"))
    }
}
