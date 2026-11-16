import XCTest
import Security
@testable import Minis

/// 这些用例直接调用Apple Security，仅可在Apple宿主运行。
final class NivoCredentialDeletionKeychainTests: XCTestCase {
    func testSelectedCleanupRemovesBothCopiesAndPreservesOtherCredential() throws {
        let journal = try fixture(accounts: ["manual-oauth-token"])
        try save("manual-fixture", account: "manual-oauth-token", sync: true, journal: journal)
        try save("legacy-fixture", account: "manual-oauth-token", sync: false, journal: journal)
        try save("oauth-fixture", account: "oauth-token", sync: true, journal: journal)
        try NivoProviderDeletionKeychain.prepare(journal)
        try NivoProviderDeletionKeychain.cleanup(journal)
        try NivoProviderDeletionKeychain.cleanup(journal)
        XCTAssertNil(try read(account: "manual-oauth-token", sync: true, journal: journal))
        XCTAssertNil(try read(account: "manual-oauth-token", sync: false, journal: journal))
        XCTAssertEqual(try read(account: "oauth-token", sync: true, journal: journal), Data("oauth-fixture".utf8))
    }

    func testChangedCredentialIsKeptAndCleanupRecordsTerminalPreservation() throws {
        let journal = try fixture(accounts: ["oauth-token"])
        try save("original-fixture", account: "oauth-token", sync: true, journal: journal)
        try NivoProviderDeletionKeychain.prepare(journal)
        try save("new-fixture", account: "oauth-token", sync: true, journal: journal)
        try NivoProviderDeletionKeychain.cleanup(journal)
        XCTAssertEqual(try NivoProviderDeletionKeychain.outcome(journal).preservedAccounts, ["oauth-token"])
        XCTAssertEqual(try read(account: "oauth-token", sync: true, journal: journal), Data("new-fixture".utf8))
        XCTAssertTrue(try NivoProviderDeletionKeychain.contains(journal.identifier))
        // 后来值即使再次变回原字节，持久终结回执也禁止重试取得新所有权。
        try save("original-fixture", account: "oauth-token", sync: true, journal: journal)
        try NivoProviderDeletionKeychain.cleanup(journal)
        XCTAssertEqual(try read(account: "oauth-token", sync: true, journal: journal), Data("original-fixture".utf8))
        XCTAssertEqual(try NivoProviderDeletionKeychain.outcome(journal).preservedAccounts, ["oauth-token"])
    }

    func testCredentialAppearingAfterEmptySnapshotIsKept() throws {
        let journal = try fixture(accounts: ["api-key"])
        try NivoProviderDeletionKeychain.prepare(journal)
        try save("new-fixture", account: "api-key", sync: false, journal: journal)
        try NivoProviderDeletionKeychain.cleanup(journal)
        XCTAssertEqual(try NivoProviderDeletionKeychain.outcome(journal).preservedAccounts, ["api-key"])
        XCTAssertEqual(try read(account: "api-key", sync: false, journal: journal), Data("new-fixture".utf8))
    }

    func testCompletedDeletionNeverDeletesReplacementOnRepeatedCleanup() throws {
        let journal = try fixture(accounts: ["oauth-token"])
        try save("same-fixture", account: "oauth-token", sync: true, journal: journal)
        try NivoProviderDeletionKeychain.prepare(journal)
        try NivoProviderDeletionKeychain.cleanup(journal)
        try save("same-fixture", account: "oauth-token", sync: true, journal: journal)
        try NivoProviderDeletionKeychain.cleanup(journal)
        XCTAssertEqual(try read(account: "oauth-token", sync: true, journal: journal), Data("same-fixture".utf8))
        XCTAssertEqual(try NivoProviderDeletionKeychain.outcome(journal).preservedAccounts, ["oauth-token"])
    }

    @MainActor
    func testChangedCredentialCompletesPersistentIntentAndDiscardsStage() async throws {
        let journal = try fixture(accounts: ["oauth-token"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ks-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let transaction = NivoProviderDeletion(journalURL: directory.appendingPathComponent("delete.json"))
        var stageID: UUID?
        try save("original-fixture", account: "oauth-token", sync: true, journal: journal)
        let operations = NivoProviderDeletion.Operations(prepare: { prepared in
            stageID = prepared.identifier
            try NivoProviderDeletionKeychain.prepare(prepared)
            try self.save("later-fixture", account: "oauth-token", sync: true, journal: prepared)
        }, containsStage: NivoProviderDeletionKeychain.contains,
            persist: { _ in XCTFail("不能删除配置") }, synchronize: { _ in XCTFail("不能删除模型") },
            cleanup: NivoProviderDeletionKeychain.cleanup, reload: {},
            discard: NivoProviderDeletionKeychain.discard, cleanupOutcome: NivoProviderDeletionKeychain.outcome)
        let outcome = try await transaction.run(journal.plan, using: operations)
        XCTAssertEqual(outcome.preservedAccounts, ["oauth-token"])
        XCTAssertNil(try transaction.pending())
        XCTAssertFalse(try NivoProviderDeletionKeychain.contains(XCTUnwrap(stageID)))
        XCTAssertEqual(try read(account: "oauth-token", sync: true, journal: journal), Data("later-fixture".utf8))
    }

    func testRevokedDeleteMarkerKeepsUnchangedBytes() throws {
        let journal = try fixture(accounts: ["oauth-token"])
        try save("same-fixture", account: "oauth-token", sync: true, journal: journal)
        // 让暂存携带可辨别的旧所有权，再模拟标记被后来写入者清除。
        let match = query(account: "oauth-token", sync: true, journal: journal)
        let marked = SecItemUpdate(match as CFDictionary, [kSecAttrComment as String: "previous-fixture-owner"] as CFDictionary)
        XCTAssertEqual(marked, errSecSuccess)
        try NivoProviderDeletionKeychain.prepare(journal)
        try save("same-fixture", account: "oauth-token", sync: true, journal: journal)
        try NivoProviderDeletionKeychain.cleanup(journal)
        XCTAssertEqual(try NivoProviderDeletionKeychain.outcome(journal).preservedAccounts, ["oauth-token"])
        XCTAssertEqual(try read(account: "oauth-token", sync: true, journal: journal), Data("same-fixture".utf8))
    }

    func testNewTokenKeepsAssociatedMetadataFromOldSignOutIntent() throws {
        let journal = try fixture(accounts: ["oauth-email", "oauth-token"])
        try save("metadata-fixture", account: "oauth-email", sync: true, journal: journal)
        try save("original-fixture", account: "oauth-token", sync: true, journal: journal)
        try NivoProviderDeletionKeychain.prepare(journal)
        try save("later-fixture", account: "oauth-token", sync: true, journal: journal)
        try NivoProviderDeletionKeychain.cleanup(journal)
        XCTAssertEqual(try NivoProviderDeletionKeychain.outcome(journal).preservedAccounts, ["oauth-email", "oauth-token"])
        XCTAssertEqual(try read(account: "oauth-email", sync: true, journal: journal), Data("metadata-fixture".utf8))
        XCTAssertEqual(try read(account: "oauth-token", sync: true, journal: journal), Data("later-fixture".utf8))
    }

    private func fixture(accounts: [String]) throws -> NivoProviderDeletion.Journal {
        let instanceID = UUID().uuidString
        let journal = NivoProviderDeletion.Journal(identifier: UUID(), phase: .synchronized,
            plan: .init(instanceID: instanceID, entryIDs: [], groupIDs: [], updatedGroupIDs: [], ruleIDs: [],
                deletedAt: Date(), credentialAccounts: accounts))
        addTeardownBlock {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "io.github.nanomuse.app.provider." + instanceID,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
            let status = SecItemDelete(query as CFDictionary)
            XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound)
            try NivoProviderDeletionKeychain.discard(journal.identifier)
        }
        return journal
    }

    private func query(account: String, sync: Bool, journal: NivoProviderDeletion.Journal) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.nanomuse.app.provider." + journal.plan.instanceID,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: sync]
    }

    private func save(_ value: String, account: String, sync: Bool, journal: NivoProviderDeletion.Journal) throws {
        let match = query(account: account, sync: sync, journal: journal)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrComment as String: ""]
        let updated = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
        let status = updated == errSecItemNotFound
            ? SecItemAdd(match.merging(attributes) { _, new in new } as CFDictionary, nil) : updated
        guard status == errSecSuccess else { throw NivoOAuthPersistenceError.storage(operation: "test_write", status: status) }
    }

    private func read(account: String, sync: Bool, journal: NivoProviderDeletion.Journal) throws -> Data? {
        var match = query(account: account, sync: sync, journal: journal)
        match[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(match as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NivoOAuthPersistenceError.storage(operation: "test_read", status: status) }
        return result as? Data
    }
}
