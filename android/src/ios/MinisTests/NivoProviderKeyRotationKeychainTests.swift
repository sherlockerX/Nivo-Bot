import XCTest
import Security
@testable import Minis

/// 仅在Apple宿主操作随机测试身份，验证真实Keychain版本与恢复暂存。
@MainActor
final class NivoProviderKeyRotationKeychainTests: XCTestCase {
    func testRollbackRestoresOriginalValueAndVersion() throws {
        let owner = UUID().uuidString
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-original", instanceID: owner)
        let original = try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner)
        let receipt = try NivoProviderKeyRotationKeychain.prepare("fixture-new", instanceID: owner, expected: original)
        addTeardownBlock {
            ProviderKeychainHelper.deleteAPIKey(instanceId: owner)
            try NivoProviderKeyRotationKeychain.discard(receipt.identifier)
        }
        try NivoProviderKeyRotationKeychain.apply(receipt)
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerValue(instanceID: owner), Data("fixture-new".utf8))
        try NivoProviderKeyRotationKeychain.rollback(receipt)
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner), original)
        try NivoProviderKeyRotationKeychain.rollback(receipt)
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner), original)
    }

    func testRollbackKeepsLaterSaveOfSameValue() throws {
        let owner = UUID().uuidString
        let receipt = try NivoProviderKeyRotationKeychain.prepare("fixture-new", instanceID: owner, expected: nil)
        addTeardownBlock {
            ProviderKeychainHelper.deleteAPIKey(instanceId: owner)
            try NivoProviderKeyRotationKeychain.discard(receipt.identifier)
        }
        try NivoProviderKeyRotationKeychain.apply(receipt)
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-new", instanceID: owner)
        let later = try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner)
        try NivoProviderKeyRotationKeychain.rollback(receipt)
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner), later)
    }

    func testMissingStageCannotPretendRollbackSucceeded() throws {
        let receipt = NivoProviderKeyRotation.Receipt(identifier: UUID(), instanceID: UUID().uuidString)
        XCTAssertThrowsError(try NivoProviderKeyRotationKeychain.rollback(receipt))
    }

    func testLegacyStageRollbackRestoresOriginalToDeviceOnlyKeychain() throws {
        let owner = makeOwner()
        let stage = try installLegacyStage(owner: owner)
        try NivoProviderKeyRotationKeychain.rollback(stage.receipt)
        let local = try XCTUnwrap(readAttributes(owner: owner, synchronizable: false))
        XCTAssertEqual(local[kSecValueData as String] as? Data, stage.previousSync?.value)
        XCTAssertEqual(local[kSecAttrGeneric as String] as? Data, stage.previousSync?.version)
        XCTAssertEqual(local[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNil(try readAttributes(owner: owner, synchronizable: true))
        try NivoProviderKeyRotationKeychain.rollback(stage.receipt)
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerValue(instanceID: owner), stage.previousSync?.value)
    }

    func testLegacyStageRollbackPreservesNewerLocalValue() throws {
        let owner = makeOwner()
        let stage = try installLegacyStage(owner: owner)
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-newer-local", instanceID: owner)
        let observed = try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner)
        try NivoProviderKeyRotationKeychain.rollback(stage.receipt)
        XCTAssertNil(try readAttributes(owner: owner, synchronizable: true))
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner), observed)
    }

    func testLegacyLocalRollbackRestoresLocalSecretWithoutCreatingSyncEntry() throws {
        let owner = makeOwner()
        try insertUnversioned("fixture-legacy", owner: owner, synchronizable: false)
        ProviderKeychainHelper.stampAPIKeySavedAt(Date(timeIntervalSince1970: 100), instanceId: owner)
        let original = try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner)
        let receipt = try prepare("fixture-new", owner: owner, expected: original)
        try NivoProviderKeyRotationKeychain.apply(receipt)
        XCTAssertNil(try readAttributes(owner: owner, synchronizable: true))
        XCTAssertEqual(try readAttributes(owner: owner, synchronizable: false)?[kSecValueData as String] as? Data,
            Data("fixture-new".utf8))
        try NivoProviderKeyRotationKeychain.rollback(receipt)
        XCTAssertNil(try readAttributes(owner: owner, synchronizable: true))
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner), original)
        XCTAssertEqual(try readAttributes(owner: owner, synchronizable: false)?[kSecValueData as String] as? Data,
            Data("fixture-legacy".utf8))
    }

    func testUnversionedSyncRollbackPreservesLegacyTimestampAndComment() throws {
        let owner = makeOwner()
        try insertUnversioned("fixture-old", owner: owner, synchronizable: true, comment: "fixture-prior-comment")
        let timestamp = Date(timeIntervalSince1970: 100)
        ProviderKeychainHelper.stampAPIKeySavedAt(timestamp, instanceId: owner)
        let original = try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner)
        XCTAssertNil(try NivoCredentialSyncKeychain.savedProviderDate(instanceID: owner))
        let receipt = try prepare("fixture-new", owner: owner, expected: original)
        try NivoProviderKeyRotationKeychain.apply(receipt)
        XCTAssertGreaterThan(try XCTUnwrap(NivoCredentialSyncKeychain.savedProviderDate(instanceID: owner)), timestamp)
        try NivoProviderKeyRotationKeychain.rollback(receipt)
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner), original)
        XCTAssertNil(try NivoCredentialSyncKeychain.savedProviderDate(instanceID: owner))
        XCTAssertEqual(ProviderKeychainHelper.apiKeySavedAt(instanceId: owner), timestamp)
        XCTAssertEqual(try readAttributes(owner: owner, synchronizable: true)?[kSecAttrComment as String] as? String,
            "fixture-prior-comment")
    }

    func testUnversionedSyncWithoutCommentCanRotateAndRollback() throws {
        let owner = makeOwner()
        try insertUnversioned("fixture-old", owner: owner, synchronizable: true)
        let original = try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner)
        let receipt = try prepare("fixture-new", owner: owner, expected: original)
        try NivoProviderKeyRotationKeychain.apply(receipt)
        try NivoProviderKeyRotationKeychain.rollback(receipt)
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner), original)
    }

    func testApplyRejectsSameValueSavedAfterPrepare() throws {
        let owner = makeOwner()
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-old", instanceID: owner)
        let receipt = try prepare("fixture-new", owner: owner,
            expected: NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner))
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-old", instanceID: owner)
        let later = try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner)
        XCTAssertThrowsError(try NivoProviderKeyRotationKeychain.apply(receipt))
        try NivoProviderKeyRotationKeychain.rollback(receipt)
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner), later)
    }

    func testApplyRejectsCredentialAppearingAfterAbsentPrepare() throws {
        let owner = makeOwner()
        let receipt = try prepare("fixture-probed", owner: owner, expected: nil)
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-later", instanceID: owner)
        let later = try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner)
        XCTAssertThrowsError(try NivoProviderKeyRotationKeychain.apply(receipt))
        try NivoProviderKeyRotationKeychain.rollback(receipt)
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner), later)
    }

    func testRollbackDoesNotRecreateCredentialDeletedAfterApply() throws {
        let owner = makeOwner()
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-old", instanceID: owner)
        let receipt = try prepare("fixture-new", owner: owner,
            expected: NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner))
        try NivoProviderKeyRotationKeychain.apply(receipt)
        ProviderKeychainHelper.deleteAPIKey(instanceId: owner)
        try NivoProviderKeyRotationKeychain.rollback(receipt)
        XCTAssertNil(try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner))
    }

    func testOrphanCleanupPreservesJournalStageAndLiveCredentials() throws {
        let retainedOwner = makeOwner()
        let orphanOwner = makeOwner()
        let retained = try prepare("fixture-retained", owner: retainedOwner, expected: nil)
        let orphan = try prepare("fixture-orphan", owner: orphanOwner, expected: nil)
        try NivoProviderKeyRotationKeychain.apply(orphan)
        try NivoProviderKeyRotationKeychain.discardOrphans(preserving: retained,
            among: [retained.identifier, orphan.identifier])
        XCTAssertThrowsError(try NivoProviderKeyRotationKeychain.apply(orphan))
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerValue(instanceID: orphanOwner), Data("fixture-orphan".utf8))
        try NivoProviderKeyRotationKeychain.apply(retained)
        try NivoProviderKeyRotationKeychain.rollback(retained)
        XCTAssertNil(try NivoCredentialSyncKeychain.providerSnapshot(instanceID: retainedOwner))
        try NivoProviderKeyRotationKeychain.discardOrphans(preserving: nil, among: [retained.identifier, orphan.identifier])
        XCTAssertThrowsError(try NivoProviderKeyRotationKeychain.rollback(retained))
    }

    /// 测试凭证始终使用随机身份，即使准备失败也回收自己创建的条目。
    private func makeOwner() -> String {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteAPIKey(instanceId: owner) }
        return owner
    }

    /// 暂存登记成功后立即安排独立清理，断言失败不会遗留秘密暂存。
    private func prepare(_ value: String, owner: String,
                         expected: NivoCredentialSyncKeychain.ProviderSnapshot?) throws -> NivoProviderKeyRotation.Receipt {
        let receipt = try NivoProviderKeyRotationKeychain.prepare(value, instanceID: owner, expected: expected)
        addTeardownBlock { try NivoProviderKeyRotationKeychain.discard(receipt.identifier) }
        return receipt
    }

    /// 模拟旧版本中断后留下的同步替换值和无目标字段的暂存，确保升级恢复路径可读。
    private func installLegacyStage(owner: String) throws -> NivoProviderKeyRotation.Stage {
        let receipt = NivoProviderKeyRotation.Receipt(identifier: UUID(), instanceID: owner)
        let oldVersion = try JSONEncoder().encode(NivoProviderKeyRotation.Version(schema: 1, seconds: 100))
        let newVersion = try JSONEncoder().encode(NivoProviderKeyRotation.Version(schema: 1, seconds: 200))
        let previous = NivoProviderKeyRotation.Secret(value: Data("fixture-legacy-original".utf8),
            version: oldVersion, comment: "fixture-original", accessibility: kSecAttrAccessibleAfterFirstUnlock as String)
        let replacement = NivoProviderKeyRotation.Secret(value: Data("fixture-legacy-replacement".utf8),
            version: newVersion, comment: receipt.comment, accessibility: kSecAttrAccessibleAfterFirstUnlock as String)
        let stage = NivoProviderKeyRotation.Stage(receipt: receipt, previousSync: previous,
            previousLocal: nil, replacement: replacement)
        var current = secretQuery(owner: owner, synchronizable: true)
        current[kSecValueData as String] = replacement.value
        current[kSecAttrGeneric as String] = replacement.version
        current[kSecAttrComment as String] = replacement.comment
        current[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let stored = SecItemAdd(current as CFDictionary, nil)
        guard stored == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(stored)) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.nanomuse.app.provider-key-rotation",
            kSecAttrAccount as String: receipt.identifier.uuidString, kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: try JSONEncoder().encode(stage)]
        let staged = SecItemAdd(query as CFDictionary, nil)
        guard staged == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(staged)) }
        addTeardownBlock { try NivoProviderKeyRotationKeychain.discard(receipt.identifier) }
        return stage
    }

    private func insertUnversioned(_ value: String, owner: String, synchronizable: Bool, comment: String? = nil) throws {
        var query = secretQuery(owner: owner, synchronizable: synchronizable)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let comment { query[kSecAttrComment as String] = comment }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private func readAttributes(owner: String, synchronizable: Bool) throws -> [String: Any]? {
        var query = secretQuery(owner: owner, synchronizable: synchronizable)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return try XCTUnwrap(result as? [String: Any])
    }

    private func secretQuery(owner: String, synchronizable: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.nanomuse.app.provider." + owner,
         kSecAttrAccount as String: "api-key", kSecAttrSynchronizable as String: synchronizable]
    }
}
