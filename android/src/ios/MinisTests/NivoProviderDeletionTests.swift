import XCTest
@testable import Minis

/// 真实文件与故障注入验证删除顺序，不将适配器替身当作Apple Keychain测试。
final class NivoProviderDeletionTests: XCTestCase {
    @MainActor
    func testPersistenceFailureRetainsCredentialAndDurableIntent() async throws {
        let fixture = try fixture()
        fixture.failsPersistence = true
        do { try await fixture.deletion.run(fixture.plan, using: fixture.operations); XCTFail("应传播写盘错误") }
        catch { XCTAssertEqual(error as? CocoaError, CocoaError(.fileWriteUnknown)) }
        XCTAssertTrue(fixture.hasCredential)
        XCTAssertNotNil(try fixture.deletion.pending())
    }

    @MainActor
    func testRestartRetriesPendingDeletionBeforeCleaningCredential() async throws {
        let fixture = try fixture()
        fixture.failsPersistence = true
        do { try await fixture.deletion.run(fixture.plan, using: fixture.operations); XCTFail("应传播写盘错误") }
        catch {}
        fixture.failsPersistence = false
        let restarted = NivoProviderDeletion(journalURL: fixture.deletion.journalURL)
        try await restarted.recover(using: fixture.operations)
        XCTAssertTrue(fixture.isPersisted)
        XCTAssertTrue(fixture.isSynchronized)
        XCTAssertFalse(fixture.hasCredential)
        XCTAssertNil(try restarted.pending())
    }

    @MainActor
    func testSynchronizationFailureRetainsStageAndRetriesWithoutRepeatingConfiguration() async throws {
        let fixture = try fixture()
        fixture.failsSync = true
        do { try await fixture.deletion.run(fixture.plan, using: fixture.operations); XCTFail("应传播队列错误") }
        catch {}
        XCTAssertTrue(fixture.hasCredential)
        XCTAssertEqual(try fixture.deletion.pending()?.phase, .committed)
        fixture.failsSync = false
        try await fixture.deletion.recover(using: fixture.operations)
        XCTAssertEqual(fixture.persistenceCount, 1)
        XCTAssertNil(try fixture.deletion.pending())
    }

    @MainActor
    func testCleanupFailureKeepsReplayMaterial() async throws {
        let fixture = try fixture()
        fixture.failsCleanup = true
        do { try await fixture.deletion.run(fixture.plan, using: fixture.operations); XCTFail("应传播清理错误") }
        catch {}
        XCTAssertTrue(fixture.isSynchronized)
        XCTAssertNotNil(fixture.stage)
        XCTAssertEqual(try fixture.deletion.pending()?.phase, .synchronized)
        fixture.failsCleanup = false
        try await fixture.deletion.recover(using: fixture.operations)
        XCTAssertFalse(fixture.hasCredential)
    }

    @MainActor
    func testDiscardCanRetryAfterStageAlreadyRemoved() async throws {
        let fixture = try fixture()
        fixture.failsDiscard = true
        do { try await fixture.deletion.run(fixture.plan, using: fixture.operations); XCTFail("应传播暂存清理错误") }
        catch {}
        XCTAssertNil(fixture.stage)
        XCTAssertEqual(try fixture.deletion.pending()?.phase, .cleaned)
        fixture.failsDiscard = false
        try await fixture.deletion.recover(using: fixture.operations)
        XCTAssertNil(try fixture.deletion.pending())
    }

    @MainActor
    func testPrepareFailureAbortsOnRestartWithoutRemovingCredential() async throws {
        let fixture = try fixture()
        fixture.failsPrepare = true
        do { try await fixture.deletion.run(fixture.plan, using: fixture.operations); XCTFail("应传播暂存错误") }
        catch {}
        try await fixture.deletion.recover(using: fixture.operations)
        XCTAssertTrue(fixture.hasCredential)
        XCTAssertFalse(fixture.isPersisted)
        XCTAssertNil(try fixture.deletion.pending())
    }

    @MainActor
    func testPendingDeletionCannotBeOverwritten() async throws {
        let fixture = try fixture()
        fixture.failsPersistence = true
        do { try await fixture.deletion.run(fixture.plan, using: fixture.operations); XCTFail("应传播写盘错误") }
        catch {}
        let original = try Data(contentsOf: fixture.deletion.journalURL)
        do { try await fixture.deletion.run(fixture.plan, using: fixture.operations); XCTFail("应保留未完成日志") }
        catch { XCTAssertEqual(error as? NivoProviderDeletion.Failure, .pendingRecovery) }
        XCTAssertEqual(try Data(contentsOf: fixture.deletion.journalURL), original)
    }

    @MainActor
    func testCorruptJournalIsPreserved() async throws {
        let fixture = try fixture()
        let invalid = Data("{broken".utf8)
        try invalid.write(to: fixture.deletion.journalURL)
        do { try await fixture.deletion.recover(using: fixture.operations); XCTFail("应拒绝损坏日志") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.deletion.journalURL), invalid)
        XCTAssertTrue(fixture.hasCredential)
    }

    @MainActor
    func testInvalidPlanIsRejectedBeforeStaging() async throws {
        let fixture = try fixture()
        var plan = fixture.plan
        plan.entryIDs = ["duplicate", "duplicate"]
        do { try await fixture.deletion.run(plan, using: fixture.operations); XCTFail("应拒绝重复标识") }
        catch { XCTAssertEqual(error as? NivoProviderDeletion.Failure, .invalidJournal) }
        XCTAssertNil(fixture.stage)
        XCTAssertNil(try fixture.deletion.pending())
    }

    @MainActor
    func testMissingCommittedStageStopsRecovery() async throws {
        let fixture = try fixture()
        fixture.failsSync = true
        do { try await fixture.deletion.run(fixture.plan, using: fixture.operations); XCTFail("应传播队列错误") }
        catch {}
        fixture.stage = nil
        do { try await fixture.deletion.recover(using: fixture.operations); XCTFail("应拒绝缺少核对材料") }
        catch { XCTAssertEqual(error as? NivoProviderDeletion.Failure, .missingStage) }
        XCTAssertTrue(fixture.hasCredential)
        XCTAssertNotNil(try fixture.deletion.pending())
    }

    @MainActor
    func testMissingStageAfterPersistenceWasAttemptedCannotCancelDeletion() async throws {
        let fixture = try fixture()
        fixture.failsPersistence = true
        do { try await fixture.deletion.run(fixture.plan, using: fixture.operations); XCTFail("应传播写盘错误") }
        catch {}
        XCTAssertEqual(try fixture.deletion.pending()?.phase, .staged)
        fixture.stage = nil
        do { try await fixture.deletion.recover(using: fixture.operations); XCTFail("不能撤销可能已提交的删除") }
        catch { XCTAssertEqual(error as? NivoProviderDeletion.Failure, .missingStage) }
        XCTAssertEqual(try fixture.deletion.pending()?.phase, .staged)
        XCTAssertTrue(fixture.hasCredential)
    }

    @MainActor
    func testCacheReadFailureKeepsJournalUntilSuccessfulReload() async throws {
        let fixture = try fixture()
        fixture.failsReload = true
        do { try await fixture.deletion.run(fixture.plan, using: fixture.operations); XCTFail("缓存尚未确认不能结束恢复") }
        catch { XCTAssertEqual(error as? CocoaError, CocoaError(.fileReadUnknown)) }
        XCTAssertEqual(try fixture.deletion.pending()?.phase, .cleaned)
        XCTAssertNotNil(fixture.stage)
        fixture.failsReload = false
        try await fixture.deletion.recover(using: fixture.operations)
        XCTAssertEqual(fixture.reloadCount, 1)
        XCTAssertEqual(fixture.persistenceCount, 1)
        XCTAssertNil(try fixture.deletion.pending())
    }

    @MainActor
    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pd-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return Fixture(journalURL: directory.appendingPathComponent("delete.json"))
    }

    /// 注入跨存储失败，不访问正式账户或系统秘密。
    @MainActor
    private final class Fixture {
        let deletion: NivoProviderDeletion
        let plan = NivoProviderDeletion.Plan(instanceID: "fixture", entryIDs: ["entry"], groupIDs: ["group"],
            updatedGroupIDs: ["remaining"], ruleIDs: ["rule"], deletedAt: Date(timeIntervalSince1970: 10))
        var stage: UUID?
        var hasCredential = true
        var isPersisted = false
        var isSynchronized = false
        var failsPersistence = false
        var failsSync = false
        var failsCleanup = false
        var failsDiscard = false
        var failsPrepare = false
        var failsReload = false
        var persistenceCount = 0
        var reloadCount = 0

        init(journalURL: URL) { deletion = NivoProviderDeletion(journalURL: journalURL) }

        var operations: NivoProviderDeletion.Operations {
            .init(prepare: { journal in
                if self.failsPrepare { throw CocoaError(.fileWriteUnknown) }
                self.stage = journal.identifier
            }, containsStage: { self.stage == $0 }, persist: { _ in
                if self.failsPersistence { throw CocoaError(.fileWriteUnknown) }
                self.isPersisted = true
                self.persistenceCount += 1
            }, synchronize: { _ in
                if self.failsSync { throw CocoaError(.fileWriteUnknown) }
                self.isSynchronized = true
            }, cleanup: { _ in
                if self.failsCleanup { throw CocoaError(.fileWriteUnknown) }
                self.hasCredential = false
            }, reload: {
                if self.failsReload { throw CocoaError(.fileReadUnknown) }
                self.reloadCount += 1
            }, discard: { _ in
                self.stage = nil
                if self.failsDiscard { throw CocoaError(.fileWriteUnknown) }
            })
        }
    }
}
