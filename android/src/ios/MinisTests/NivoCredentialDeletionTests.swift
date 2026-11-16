import XCTest
@testable import Minis

/// 删除失败必须保留原目标与重试能力，不把部分删除报告成成功。
final class NivoCredentialDeletionTests: XCTestCase {
    @MainActor
    func testDraftSettlementFailureKeepsCleanedJournalAndNeverRecapturesCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ds-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let deletion = NivoProviderDeletion(journalURL: directory.appendingPathComponent("delete.json"))
        let registry = NivoOAuthDraftRegistry(fileURL: directory.appendingPathComponent("drafts.json"))
        try registry.begin(instanceID: "fixture", isExisting: false)
        registry.abandon(instanceID: "fixture")
        let plan = NivoProviderDeletion.Plan(instanceID: "fixture", entryIDs: [], groupIDs: [],
            updatedGroupIDs: [], ruleIDs: [], deletedAt: Date(), credentialAccounts: NivoCredentialDeletion.accounts)
        var stage: UUID?
        var preparations = 0
        var cleanups = 0
        var shouldFail = true
        let outcome = NivoCredentialDeletion.Outcome(preservedAccounts: ["oauth-token"])
        let operations = NivoProviderDeletion.Operations(prepare: { stage = $0.identifier; preparations += 1 },
            containsStage: { stage == $0 }, persist: { _ in XCTFail() }, synchronize: { _ in XCTFail() },
            cleanup: { _ in cleanups += 1 }, reload: {}, discard: { _ in stage = nil }, cleanupOutcome: { _ in outcome },
            settle: { journal in
                if shouldFail { throw CocoaError(.fileWriteNoPermission) }
                try registry.complete(instanceID: journal.plan.instanceID)
            })
        do { try await deletion.run(plan, using: operations); XCTFail("登记失败必须保留原清理日志") }
        catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission) }
        XCTAssertEqual(try deletion.pending()?.phase, .cleaned)
        XCTAssertEqual(try registry.pendingIDs(), ["fixture"])
        shouldFail = false
        let recovered = try await deletion.recover(using: operations)
        XCTAssertEqual(recovered, outcome)
        XCTAssertNil(try deletion.pending())
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(cleanups, 1)
        let restarted = NivoOAuthDraftRegistry(fileURL: registry.fileURL)
        XCTAssertTrue(try restarted.pendingIDs().isEmpty)
    }

    @MainActor
    func testFailureRetainsSnapshotAndRetryWaitsForConfirmedDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cd-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let deletion = NivoProviderDeletion(journalURL: directory.appendingPathComponent("delete.json"))
        let plan = NivoProviderDeletion.Plan(instanceID: "fixture", entryIDs: [], groupIDs: [],
            updatedGroupIDs: [], ruleIDs: [], deletedAt: Date(), credentialAccounts: ["oauth-token", "oauth-email"])
        var snapshotCount = 0
        var shouldFail = true
        var completionCount = 0
        var stage: UUID?
        let operations = NivoProviderDeletion.Operations(
            prepare: { stage = $0.identifier; snapshotCount += 1 },
            containsStage: { stage == $0 },
            persist: { _ in XCTFail("独立凭证删除不能修改配置") },
            synchronize: { _ in XCTFail("独立凭证删除不能发布模型删除记录") },
            cleanup: { journal in
                XCTAssertEqual(journal.plan.credentialAccounts, plan.credentialAccounts)
                if shouldFail { throw CocoaError(.fileWriteUnknown) }
            },
            reload: { completionCount += 1 }, discard: { _ in stage = nil })

        do { try await deletion.run(plan, using: operations); XCTFail("删除失败应向调用者传播") }
        catch { XCTAssertEqual(error as? CocoaError, CocoaError(.fileWriteUnknown)) }
        XCTAssertEqual(try deletion.pending()?.plan, plan)
        XCTAssertEqual(completionCount, 0)

        shouldFail = false
        try await deletion.recover(using: operations)
        XCTAssertNil(try deletion.pending())
        XCTAssertEqual(snapshotCount, 1, "重试只能继续原快照，不能捕获后来写入的凭证")
        XCTAssertEqual(completionCount, 1)
    }

    func testOldJournalWithoutCredentialAccountsRemainsFullProviderDeletion() throws {
        let plan = NivoProviderDeletion.Plan(instanceID: "fixture", entryIDs: [], groupIDs: [],
            updatedGroupIDs: [], ruleIDs: [], deletedAt: Date())
        let journal = NivoProviderDeletion.Journal(identifier: UUID(), phase: .prepared, plan: plan)
        let data = try JSONEncoder().encode(journal)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("credentialAccounts"))
        let decoded = try JSONDecoder().decode(NivoProviderDeletion.Journal.self, from: data)
        try decoded.validate()
        XCTAssertNil(decoded.plan.credentialAccounts)
    }

    func testCredentialOnlyJournalRejectsConfigDeletionAndUnknownAccounts() throws {
        var plan = NivoProviderDeletion.Plan(instanceID: "fixture", entryIDs: [], groupIDs: [],
            updatedGroupIDs: [], ruleIDs: [], deletedAt: Date(), credentialAccounts: ["oauth-token"])
        func validate() throws {
            try NivoProviderDeletion.Journal(identifier: UUID(), phase: .prepared, plan: plan).validate()
        }
        try validate()
        plan.entryIDs = ["model"]
        XCTAssertThrowsError(try validate())
        plan.entryIDs = []
        for accounts in [[], ["unknown"], ["oauth-token", "oauth-token"]] {
            plan.credentialAccounts = accounts
            XCTAssertThrowsError(try validate())
        }
    }

    func testChangedCredentialIsPreservedWithoutBlockingRecovery() throws {
        let original = NivoCredentialDeletion.Secret(value: Data("original-fixture".utf8), version: nil)
        let changed = NivoCredentialDeletion.Secret(value: Data("changed-fixture".utf8), version: nil)
        XCTAssertEqual(NivoCredentialDeletion.action(current: changed, expected: original, marker: "deletion"), .preserve)
        XCTAssertEqual(NivoCredentialDeletion.action(current: nil, expected: original, marker: "deletion"), .absent)
        XCTAssertEqual(NivoCredentialDeletion.action(current: original, expected: original, marker: "deletion"), .remove)
    }

    func testRevokedOwnershipPreservesSameValueAfterClaim() {
        let original = NivoCredentialDeletion.Secret(value: Data("same-fixture".utf8), version: nil,
            modifiedAt: Date(timeIntervalSince1970: 10), marker: "original")
        let claimed = NivoCredentialDeletion.Secret(value: original.value, version: nil,
            modifiedAt: Date(timeIntervalSince1970: 11), marker: "deletion")
        let replaced = NivoCredentialDeletion.Secret(value: original.value, version: nil,
            modifiedAt: Date(timeIntervalSince1970: 12), marker: "")
        XCTAssertEqual(NivoCredentialDeletion.action(current: claimed, expected: original, marker: "deletion"), .remove)
        XCTAssertEqual(NivoCredentialDeletion.action(current: replaced, expected: original, marker: "deletion"), .preserve)
    }

    @MainActor
    func testPreservationReceiptSurvivesReloadFailureAndEndsJournalOnRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cr-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let deletion = NivoProviderDeletion(journalURL: directory.appendingPathComponent("delete.json"))
        let plan = NivoProviderDeletion.Plan(instanceID: "fixture", entryIDs: [], groupIDs: [],
            updatedGroupIDs: [], ruleIDs: [], deletedAt: Date(), credentialAccounts: ["oauth-token"])
        let outcome = NivoCredentialDeletion.Outcome(preservedAccounts: ["oauth-token"])
        var stage: UUID?
        var shouldFailReload = true
        var cleanupCount = 0
        let operations = NivoProviderDeletion.Operations(prepare: { stage = $0.identifier },
            containsStage: { stage == $0 }, persist: { _ in XCTFail("不能删除配置") },
            synchronize: { _ in XCTFail("不能删除模型") }, cleanup: { _ in cleanupCount += 1 },
            reload: { if shouldFailReload { throw CocoaError(.fileReadUnknown) } },
            discard: { _ in stage = nil }, cleanupOutcome: { _ in outcome })
        do { try await deletion.run(plan, using: operations); XCTFail("读取失败仍须保留屏障") }
        catch { XCTAssertEqual(error as? CocoaError, CocoaError(.fileReadUnknown)) }
        XCTAssertEqual(try deletion.pending()?.credentialOutcome, outcome)
        shouldFailReload = false
        let result = try await deletion.recover(using: operations)
        XCTAssertEqual(result, outcome)
        XCTAssertEqual(cleanupCount, 1, "终结后的重放不能再次触及新凭证")
        XCTAssertNil(try deletion.pending())
        XCTAssertNil(stage)
    }

    func testOldSnapshotWithoutIdentityCannotDeleteSameValueFromNewWriter() {
        let legacy = NivoCredentialDeletion.Secret(value: Data("same-fixture".utf8), version: nil)
        let current = NivoCredentialDeletion.Secret(value: legacy.value, version: nil,
            modifiedAt: Date(timeIntervalSince1970: 20), marker: "")
        XCTAssertEqual(NivoCredentialDeletion.action(current: current, expected: legacy, marker: "deletion"), .preserve)
    }

    func testReceiptRejectsAccountsOutsideOriginalDeletionScope() {
        let plan = NivoProviderDeletion.Plan(instanceID: "fixture", entryIDs: [], groupIDs: [],
            updatedGroupIDs: [], ruleIDs: [], deletedAt: Date(), credentialAccounts: ["oauth-token"])
        let journal = NivoProviderDeletion.Journal(identifier: UUID(), phase: .cleaned, plan: plan,
            credentialOutcome: .init(preservedAccounts: ["api-key"]))
        XCTAssertThrowsError(try journal.validate())
    }
}
