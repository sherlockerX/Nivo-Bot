import XCTest
@testable import Minis

/// 草稿所有权必须跨页面退出和清理失败保留，已有实例永远不取得清理所有权。
@MainActor
final class NivoOAuthDraftTests: XCTestCase {
    private func location() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("drafts.json")
    }

    func testFailedConfigurationAndClosedFormRemainRecoverableAfterRestart() async throws {
        let url = try location()
        let drafts = NivoOAuthDraftRegistry(fileURL: url)
        try drafts.begin(instanceID: "new-instance", isExisting: false)
        XCTAssertEqual(try drafts.pendingIDs(), [])
        drafts.abandon(instanceID: "new-instance")
        XCTAssertEqual(try drafts.pendingIDs(), ["new-instance"])
        XCTAssertEqual(try NivoOAuthDraftRegistry(fileURL: url).pendingIDs(), ["new-instance"])
    }

    func testExistingInstanceNeverBecomesDisposableDraft() async throws {
        let drafts = NivoOAuthDraftRegistry(fileURL: try location())
        try drafts.begin(instanceID: "existing-instance", isExisting: true)
        drafts.abandon(instanceID: "existing-instance")
        XCTAssertEqual(try drafts.pendingIDs(), [])
    }

    func testCleanupFailureDoesNotForgetDraft() async throws {
        let url = try location()
        let drafts = NivoOAuthDraftRegistry(fileURL: url)
        try drafts.begin(instanceID: "new-instance", isExisting: false)
        drafts.abandon(instanceID: "new-instance")
        do {
            try await drafts.clean(instanceID: "new-instance", isInstalled: { false }) {
                throw CocoaError(.fileWriteNoPermission)
            }
            XCTFail("清理失败必须向宿主传播")
        } catch {}
        XCTAssertEqual(try NivoOAuthDraftRegistry(fileURL: url).pendingIDs(), ["new-instance"])
    }

    func testSuccessfulSaveBeforeDraftAcknowledgmentPreservesInstalledCredential() async throws {
        let drafts = NivoOAuthDraftRegistry(fileURL: try location())
        try drafts.begin(instanceID: "new-instance", isExisting: false)
        drafts.abandon(instanceID: "new-instance")
        var didDelete = false
        try await drafts.clean(instanceID: "new-instance", isInstalled: { true }) { didDelete = true }
        XCTAssertFalse(didDelete)
        XCTAssertEqual(try drafts.pendingIDs(), [])
    }

    func testOnlyConfirmedDeletionReleasesDraft() async throws {
        let drafts = NivoOAuthDraftRegistry(fileURL: try location())
        try drafts.begin(instanceID: "new-instance", isExisting: false)
        drafts.abandon(instanceID: "new-instance")
        var didDelete = false
        try await drafts.clean(instanceID: "new-instance", isInstalled: { false }) { didDelete = true }
        XCTAssertTrue(didDelete)
        XCTAssertEqual(try drafts.pendingIDs(), [])
    }

    func testPreservedCredentialOutcomeEndsDraftWithoutAnotherCleanupAfterRestart() async throws {
        let url = try location()
        let drafts = NivoOAuthDraftRegistry(fileURL: url)
        try drafts.begin(instanceID: "new-instance", isExisting: false)
        drafts.abandon(instanceID: "new-instance")
        var cleanupCount = 0
        var reportedOutcome: NivoCredentialDeletion.Outcome?
        try await drafts.clean(instanceID: "new-instance", isInstalled: { false }) {
            cleanupCount += 1
            reportedOutcome = .init(preservedAccounts: ["oauth-token"])
            // 保留是终结结果，宿主记录提示后正常结束闭包，让登记原子移除。
        }
        XCTAssertEqual(reportedOutcome?.preservedAccounts, ["oauth-token"])
        let restarted = NivoOAuthDraftRegistry(fileURL: url)
        XCTAssertEqual(try restarted.pendingIDs(), [])
        try await restarted.clean(instanceID: "new-instance", isInstalled: { false }) {
            cleanupCount += 1
        }
        XCTAssertEqual(cleanupCount, 1, "不能重新拍摄快照并删除已经保留的新凭证")
    }

    func testCommittedDraftIsNotRecoveredOnRestart() async throws {
        let url = try location()
        let drafts = NivoOAuthDraftRegistry(fileURL: url)
        try drafts.begin(instanceID: "new-instance", isExisting: false)
        try drafts.complete(instanceID: "new-instance")
        XCTAssertEqual(try NivoOAuthDraftRegistry(fileURL: url).pendingIDs(), [])
    }

    func testActiveFormCannotBeCleanedByRecovery() async throws {
        let drafts = NivoOAuthDraftRegistry(fileURL: try location())
        try drafts.begin(instanceID: "new-instance", isExisting: false)
        var didDelete = false
        try await drafts.clean(instanceID: "new-instance", isInstalled: { false }) { didDelete = true }
        XCTAssertFalse(didDelete)
        drafts.abandon(instanceID: "new-instance")
        XCTAssertEqual(try drafts.pendingIDs(), ["new-instance"])
    }

    func testCorruptRegistryDoesNotPermitUntrackedLogin() async throws {
        let url = try location()
        try Data("invalid registry".utf8).write(to: url)
        let drafts = NivoOAuthDraftRegistry(fileURL: url)
        XCTAssertThrowsError(try drafts.begin(instanceID: "new-instance", isExisting: false))
        XCTAssertThrowsError(try drafts.pendingIDs())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "invalid registry")
    }

    func testUnregisteredInstanceIsNeverDeleted() async throws {
        let drafts = NivoOAuthDraftRegistry(fileURL: try location())
        var didDelete = false
        try await drafts.clean(instanceID: "existing-instance", isInstalled: { false }) { didDelete = true }
        XCTAssertFalse(didDelete)
    }

    func testCancelDuringKimiSuccessDelayReportsPersistedCredentialExactlyOnce() async throws {
        var completion = NivoOAuthLoginCompletion()
        completion.didPersist()
        XCTAssertEqual(completion.finish(), true)
        XCTAssertNil(completion.finish())
    }

    func testDismissBeforeKimiPersistenceReportsNoCredentialExactlyOnce() async throws {
        var completion = NivoOAuthLoginCompletion()
        XCTAssertEqual(completion.finish(), false)
        XCTAssertNil(completion.finish())
    }

    func testDismissDuringSaveKeepsDraftActiveUntilCommitIsConfirmed() async throws {
        let drafts = NivoOAuthDraftRegistry(fileURL: try location())
        try drafts.begin(instanceID: "new-instance", isExisting: false)
        let gate = OAuthDraftSubmissionGate()
        let saving = Task<Void, Never> {
            await gate.wait()
            try? drafts.complete(instanceID: "new-instance")
        }
        await gate.waitUntilSuspended()
        let leaving = await startAbandoning(drafts, after: saving)
        var didDelete = false
        try await drafts.clean(instanceID: "new-instance", isInstalled: { false }) { didDelete = true }
        XCTAssertFalse(didDelete)
        XCTAssertEqual(try drafts.pendingIDs(), [])
        gate.release()
        await leaving.value
        XCTAssertEqual(try drafts.pendingIDs(), [])
    }

    func testDismissDuringRollbackBecomesRecoverableOnlyAfterRollbackFinishes() async throws {
        let drafts = NivoOAuthDraftRegistry(fileURL: try location())
        try drafts.begin(instanceID: "new-instance", isExisting: false)
        let gate = OAuthDraftSubmissionGate()
        let saving = Task<Void, Never> { await gate.wait() }
        await gate.waitUntilSuspended()
        let leaving = await startAbandoning(drafts, after: saving)
        XCTAssertEqual(try drafts.pendingIDs(), [])
        gate.release()
        await leaving.value
        XCTAssertEqual(try drafts.pendingIDs(), ["new-instance"])
    }

    func testCancelledSubmissionStillWaitsForItsRollbackBeforeCleanup() async throws {
        let drafts = NivoOAuthDraftRegistry(fileURL: try location())
        try drafts.begin(instanceID: "new-instance", isExisting: false)
        let gate = OAuthDraftSubmissionGate()
        let saving = Task<Void, Never> { await gate.wait() }
        await gate.waitUntilSuspended()
        saving.cancel()
        let leaving = await startAbandoning(drafts, after: saving)
        XCTAssertEqual(try drafts.pendingIDs(), [])
        gate.release()
        await leaving.value
        XCTAssertEqual(try drafts.pendingIDs(), ["new-instance"])
    }

    private func startAbandoning(_ drafts: NivoOAuthDraftRegistry,
                                 after saving: Task<Void, Never>) async -> Task<Void, Never> {
        var leaving: Task<Void, Never>?
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            leaving = Task {
                started.resume()
                await drafts.abandon(instanceID: "new-instance", after: saving)
            }
        }
        return leaving!
    }
}

/// 测试明确控制提交或回滚的完成时刻，不依赖计时或真实存储速度。
@MainActor
private final class OAuthDraftSubmissionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    /// 挂起保存任务，直到测试显式确认提交或回滚结束。
    func wait() async {
        await withCheckedContinuation { pending in
            continuation = pending
            observers.forEach { $0.resume() }
            observers.removeAll()
        }
    }

    /// 确保保存任务已经进入等待，再触发表单关闭。
    func waitUntilSuspended() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    /// 允许保存任务结束，随后草稿才可转交清理。
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
