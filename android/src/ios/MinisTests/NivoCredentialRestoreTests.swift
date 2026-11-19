import XCTest
import Security
@testable import Minis

/// Apple宿主真实Keychain集成用例，全部使用随机测试身份，不访问正式用户凭证。
@MainActor
final class NivoCredentialRestoreTests: XCTestCase {
    /// 探测期间凭证已被编辑，迟到的新密钥不得覆盖它。
    func testProviderKeyProbeRejectsChangedCredential() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteAPIKey(instanceId: owner) }
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-original", instanceID: owner)
        let observed = try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner)
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-newer", instanceID: owner)
        XCTAssertThrowsError(try NivoCredentialSyncKeychain.replaceLocalProvider("fixture-probed", instanceID: owner, expected: observed))
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerValue(instanceID: owner), Data("fixture-newer".utf8))
    }

    /// 原值未变化时原位更新并读回，旧版本随密钥一起推进。
    func testProviderKeyProbeUpdatesOnlyObservedCredential() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteAPIKey(instanceId: owner) }
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-original", instanceID: owner)
        let observed = try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner)
        let version = try XCTUnwrap(NivoCredentialSyncKeychain.savedProviderDate(instanceID: owner))
        try NivoCredentialSyncKeychain.replaceLocalProvider("fixture-probed", instanceID: owner, expected: observed)
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerValue(instanceID: owner), Data("fixture-probed".utf8))
        XCTAssertGreaterThan(try XCTUnwrap(NivoCredentialSyncKeychain.savedProviderDate(instanceID: owner)), version)
    }

    /// 相同值的新版本也使旧探测失效，避免ABA写入覆盖用户后来确认的密钥。
    func testProviderKeyProbeRejectsSameValueWithNewVersion() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteAPIKey(instanceId: owner) }
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-original", instanceID: owner)
        let observed = try NivoCredentialSyncKeychain.providerSnapshot(instanceID: owner)
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-original", instanceID: owner)
        XCTAssertThrowsError(try NivoCredentialSyncKeychain.replaceLocalProvider("fixture-probed", instanceID: owner, expected: observed))
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerValue(instanceID: owner), Data("fixture-original".utf8))
    }

    /// 删除核对材料覆盖附属端点，捕获后更新的OAuth仍保留。
    func testProviderDeletionCleansEndpointAndPreservesUpdatedToken() throws {
        let owner = UUID().uuidString
        let journal = NivoProviderDeletion.Journal(identifier: UUID(), phase: .synchronized,
            plan: .init(instanceID: owner, entryIDs: [], groupIDs: [], updatedGroupIDs: [], ruleIDs: [], deletedAt: Date()))
        addTeardownBlock {
            ProviderKeychainHelper.deleteOAuthString(instanceId: owner, account: "oauth-base-url")
            ProviderKeychainHelper.deleteOAuthToken(instanceId: owner)
            try NivoProviderDeletionKeychain.discard(journal.identifier)
        }
        try ProviderKeychainHelper.saveRawOAuthToken(Data("fixture-original".utf8), instanceId: owner)
        try ProviderKeychainHelper.saveOAuthString("fixture-endpoint", instanceId: owner, account: "oauth-base-url")
        try NivoProviderDeletionKeychain.prepare(journal)
        XCTAssertTrue(try NivoProviderDeletionKeychain.contains(journal.identifier))
        try ProviderKeychainHelper.saveRawOAuthToken(Data("fixture-updated".utf8), instanceId: owner)
        try NivoProviderDeletionKeychain.cleanup(journal)
        XCTAssertEqual(try ProviderKeychainHelper.loadRawOAuthTokenStrict(instanceId: owner), Data("fixture-updated".utf8))
        XCTAssertNil(try ProviderKeychainHelper.loadOAuthStringStrict(instanceId: owner, account: "oauth-base-url"))
        try NivoProviderDeletionKeychain.discard(journal.identifier)
        XCTAssertFalse(try NivoProviderDeletionKeychain.contains(journal.identifier))
    }

    /// 同值密钥获得新版本后属于后续保存，重放旧清理不能删除它。
    func testProviderDeletionPreservesSameValueAPIKeyWithNewVersion() throws {
        let owner = UUID().uuidString
        let journal = NivoProviderDeletion.Journal(identifier: UUID(), phase: .synchronized,
            plan: .init(instanceID: owner, entryIDs: [], groupIDs: [], updatedGroupIDs: [], ruleIDs: [], deletedAt: Date()))
        addTeardownBlock {
            ProviderKeychainHelper.deleteAPIKey(instanceId: owner)
            try NivoProviderDeletionKeychain.discard(journal.identifier)
        }
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-value", instanceID: owner)
        try NivoProviderDeletionKeychain.prepare(journal)
        try NivoCredentialSyncKeychain.saveLocalProvider("fixture-value", instanceID: owner)
        try NivoProviderDeletionKeychain.cleanup(journal)
        XCTAssertEqual(try NivoCredentialSyncKeychain.providerValue(instanceID: owner), Data("fixture-value".utf8))
    }

    /// 分享导入的端点与令牌使用同一插入回执，失败回滚不会留下孤立端点。
    func testImportedProviderEndpointRollsBackWithItsReceipt() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteOAuthString(instanceId: owner, account: "oauth-base-url") }
        let plan = try NivoCredentialRestore.prepare([
            .init(target: .init(kind: .providerBaseURL, owner: owner), data: Data("fixture-endpoint".utf8))
        ])
        _ = try NivoCredentialRestore.apply(plan)
        XCTAssertEqual(try ProviderKeychainHelper.loadOAuthStringStrict(instanceId: owner, account: "oauth-base-url"), "fixture-endpoint")
        try NivoCredentialRestore.rollback(plan.receipt)
        XCTAssertNil(try ProviderKeychainHelper.loadOAuthStringStrict(instanceId: owner, account: "oauth-base-url"))
    }

    /// 用户更新后的端点没有旧插入标记，重放导入回滚必须保留新值。
    func testImportRollbackPreservesEndpointChangedAfterImport() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteOAuthString(instanceId: owner, account: "oauth-base-url") }
        let plan = try NivoCredentialRestore.prepare([
            .init(target: .init(kind: .providerBaseURL, owner: owner), data: Data("fixture-original".utf8))
        ])
        _ = try NivoCredentialRestore.apply(plan)
        try ProviderKeychainHelper.saveOAuthString("fixture-new", instanceId: owner, account: "oauth-base-url")
        try NivoCredentialRestore.rollback(plan.receipt)
        XCTAssertEqual(try ProviderKeychainHelper.loadOAuthStringStrict(instanceId: owner, account: "oauth-base-url"), "fixture-new")
    }

    /// 原位保存覆盖同一本机条目，严格读取返回最终值。
    func testOAuthSaveUpdatesExistingKeychainValue() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteOAuthToken(instanceId: owner) }
        try ProviderKeychainHelper.saveRawOAuthToken(Data("fixture-original".utf8), instanceId: owner)
        try ProviderKeychainHelper.saveRawOAuthToken(Data("fixture-new".utf8), instanceId: owner)
        XCTAssertEqual(try ProviderKeychainHelper.loadRawOAuthTokenStrict(instanceId: owner), Data("fixture-new".utf8))
    }

    /// 无效新值失败不会删除已保存的登录信息。
    func testInvalidOAuthWritePreservesExistingKeychainValue() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteOAuthToken(instanceId: owner) }
        try ProviderKeychainHelper.saveRawOAuthToken(Data("fixture-original".utf8), instanceId: owner)
        XCTAssertThrowsError(try ProviderKeychainHelper.saveRawOAuthToken(Data(), instanceId: owner))
        XCTAssertEqual(try ProviderKeychainHelper.loadRawOAuthTokenStrict(instanceId: owner), Data("fixture-original".utf8))
    }

    /// 损坏的结构化令牌保留原件并抛错，不返回未登录。
    func testStrictOAuthReadRejectsCorruptToken() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteOAuthToken(instanceId: owner) }
        let invalid = Data("{broken".utf8)
        try ProviderKeychainHelper.saveRawOAuthToken(invalid, instanceId: owner)
        XCTAssertThrowsError(try ProviderKeychainHelper.loadOAuthTokenStrict(instanceId: owner, as: ClaudeTokenStorage.self))
        XCTAssertEqual(try ProviderKeychainHelper.loadRawOAuthTokenStrict(instanceId: owner), invalid)
    }

    /// 旧服务发生后续修改时，迟到的清理拒绝删除新值。
    func testLegacyOAuthCleanupRejectsChangedSource() throws {
        let service = "io.github.nanomuse.test." + UUID().uuidString
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token", kSecAttrSynchronizable as String: false]
        addTeardownBlock {
            let status = SecItemDelete(query as CFDictionary)
            XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound)
        }
        let value = Data("fixture-current".utf8)
        let attributes = query.merging([kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { _, new in new }
        XCTAssertEqual(SecItemAdd(attributes as CFDictionary, nil), errSecSuccess)
        XCTAssertThrowsError(try NivoProviderOAuthKeychain.removeLegacy(service: service, account: "token",
            expected: Data("fixture-prior".utf8)))
        XCTAssertEqual(try NivoProviderOAuthKeychain.readLegacy(service: service, account: "token"), value)
        try NivoProviderOAuthKeychain.removeLegacy(service: service, account: "token", expected: value)
        XCTAssertNil(try NivoProviderOAuthKeychain.readLegacy(service: service, account: "token"))
    }

    /// 手动令牌和项目资料同样需要持久化成功才返回。
    func testOAuthStringSaveAndStrictRead() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteOAuthString(instanceId: owner, account: "oauth-gcp-project") }
        try ProviderKeychainHelper.saveOAuthString("fixture-project", instanceId: owner, account: "oauth-gcp-project")
        XCTAssertEqual(try ProviderKeychainHelper.loadOAuthStringStrict(instanceId: owner, account: "oauth-gcp-project"), "fixture-project")
        XCTAssertThrowsError(try ProviderKeychainHelper.saveOAuthString("", instanceId: owner, account: "oauth-gcp-project"))
        XCTAssertEqual(try ProviderKeychainHelper.loadOAuthStringStrict(instanceId: owner, account: "oauth-gcp-project"), "fixture-project")
    }

    /// 旧整包在元数据已存在而凭证尚未到达时补值，重放不覆盖本机后续更新。
    func testLegacyEnvironmentMetadataAndSecretArrivalPreservesExistingValue() throws {
        let (store, url, key) = try environmentFixture()
        let metadata = EnvVarEntry(id: "fixture", key: key, createdAt: Date(timeIntervalSince1970: 1))
        try store.nmMergeLegacyMetadata([metadata])
        XCTAssertNil(try NivoCredentialSyncKeychain.environmentValue(key: key))
        let payload = String(decoding: try JSONSerialization.data(withJSONObject:
            [["key": key, "value": Data("fixture-from-legacy".utf8).base64EncodedString()]]), as: UTF8.self)
        try store.nmMergeLegacyMetadata([metadata], secretsJSON: payload)
        XCTAssertEqual(try NivoCredentialSyncKeychain.environmentValue(key: key), "fixture-from-legacy")
        _ = try NivoCredentialSyncKeychain.saveEnvironment("fixture-newer", key: key, version: Date(timeIntervalSince1970: 30))
        try store.nmMergeLegacyMetadata([metadata], secretsJSON: payload)
        XCTAssertEqual(try NivoCredentialSyncKeychain.environmentValue(key: key), "fixture-newer")
        XCTAssertNil(try NivoEnvVarTransaction(fileURL: url).pending())
    }

    /// 无元数据对应的凭证拒绝写入，避免旧整包先产生无法在界面管理的秘密。
    func testLegacyEnvironmentRejectsOrphanedSecretBeforeWritingKeychain() throws {
        let (store, _, key) = try environmentFixture()
        let payload = String(decoding: try JSONSerialization.data(withJSONObject:
            [["key": key, "value": Data("fixture-orphan".utf8).base64EncodedString()]]), as: UTF8.self)
        XCTAssertThrowsError(try store.nmMergeLegacyMetadata([], secretsJSON: payload))
        XCTAssertNil(try NivoCredentialSyncKeychain.environmentValue(key: key))
    }

    /// 模拟秘密已经写入但元数据尚未提交，重开页面恢复改名及旧名称清理。
    func testEnvironmentInterruptedRenameRecoversWithRealKeychainStage() throws {
        let (store, url, key) = try environmentFixture()
        try store.applyRemoteItem(id: "fixture", key: key, value: "fixture-original", note: "",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 10))
        let candidate = EnvVarEntry(id: "fixture", key: key + "_RENAMED", createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 20))
        let transaction = NivoEnvVarTransaction(fileURL: url)
        XCTAssertThrowsError(try transaction.run(after: [candidate], writeKey: candidate.key, notifySync: false,
            prepare: { try NivoEnvVarKeychainTransaction.prepare($0, value: "fixture-replacement") },
            using: NivoEnvVarKeychainTransaction.credentials,
            checkpoint: { if $0 == .secretApplied { throw CocoaError(.fileWriteUnknown) } }))
        let contents = try String(contentsOf: transaction.journalURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("fixture-replacement"))
        let reloaded = EnvVarStore(fileURL: url, schedulesCleanup: false)
        XCTAssertNotNil(reloaded.loadError)
        reloaded.reloadFromDisk()
        XCTAssertNil(reloaded.loadError)
        XCTAssertEqual(reloaded.entries, [candidate])
        XCTAssertNil(try NivoCredentialSyncKeychain.environmentValue(key: key))
        XCTAssertEqual(try NivoCredentialSyncKeychain.environmentValue(key: candidate.key), "fixture-replacement")
        XCTAssertNil(try transaction.pending())
    }

    /// 删除后的重试仍保留Keychain清理目标，即使元数据已经没有该变量。
    func testEnvironmentDeletionRetriesFailedCleanupAfterMetadataWasRemoved() throws {
        let (store, url, key) = try environmentFixture()
        try store.applyRemoteItem(id: "fixture", key: key, value: "fixture-original", note: "",
            createdAt: Date(), updatedAt: Date())
        let transaction = NivoEnvVarTransaction(fileURL: url)
        var credentials = NivoEnvVarKeychainTransaction.credentials
        credentials.cleanup = { _ in throw CocoaError(.fileWriteUnknown) }
        XCTAssertThrowsError(try transaction.run(after: [], writeKey: nil, notifySync: false,
            prepare: { try NivoEnvVarKeychainTransaction.prepare($0, value: nil) }, using: credentials))
        XCTAssertTrue(try NivoEnvVarState.read(url).isEmpty)
        XCTAssertNotNil(try NivoCredentialSyncKeychain.environmentValue(key: key))
        try store.applyRemoteDeletion(id: "fixture")
        XCTAssertNil(try transaction.pending())
        XCTAssertNil(try NivoCredentialSyncKeychain.environmentValue(key: key))
    }

    /// 等待清理期间出现的新秘密不得被旧删除回执移除。
    func testEnvironmentCleanupPreservesCredentialUpdatedAfterStaging() throws {
        let (store, url, key) = try environmentFixture()
        try store.applyRemoteItem(id: "fixture", key: key, value: "fixture-original", note: "",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 10))
        let transaction = NivoEnvVarTransaction(fileURL: url)
        XCTAssertThrowsError(try transaction.run(after: [], writeKey: nil, notifySync: false,
            prepare: { try NivoEnvVarKeychainTransaction.prepare($0, value: nil) },
            using: NivoEnvVarKeychainTransaction.credentials,
            checkpoint: { if $0 == .commitRecorded { throw CocoaError(.fileWriteUnknown) } }))
        _ = try NivoCredentialSyncKeychain.saveEnvironment("fixture-newer", key: key,
            version: Date(timeIntervalSince1970: 30))
        XCTAssertNil(try transaction.recover(using: NivoEnvVarKeychainTransaction.credentials))
        XCTAssertEqual(try NivoCredentialSyncKeychain.environmentValue(key: key), "fixture-newer")
    }

    /// 注入脚本的配置读取必须报告中断，不能将半份配置或空字典返回给调用方。
    func testEnvironmentShellSnapshotRejectsUnfinishedTransaction() throws {
        let (store, url, key) = try environmentFixture()
        try store.applyRemoteItem(id: "fixture", key: key, value: "fixture-original", note: "",
            createdAt: Date(), updatedAt: Date())
        let transaction = NivoEnvVarTransaction(fileURL: url)
        XCTAssertThrowsError(try transaction.run(after: [], writeKey: nil, notifySync: false,
            prepare: { try NivoEnvVarKeychainTransaction.prepare($0, value: nil) },
            using: NivoEnvVarKeychainTransaction.credentials,
            checkpoint: { if $0 == .credentialStaged { throw CocoaError(.fileWriteUnknown) } }))
        XCTAssertThrowsError(try store.allAsDict())
        XCTAssertNil(try transaction.recover(using: NivoEnvVarKeychainTransaction.credentials))
        XCTAssertEqual(try store.allAsDict(), [:])
    }

    /// 单变量的较旧版本不覆盖值，改名时未提供值会迁移既有凭证。
    func testEnvironmentVersionAndRenamePersistAcrossReload() throws {
        let (store, url, key) = try environmentFixture()
        try store.applyRemoteItem(id: "fixture", key: key, value: "new-fixture", note: "新备注",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 30))
        try store.applyRemoteItem(id: "fixture", key: key, value: "old-fixture", note: "旧备注",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(try NivoCredentialSyncKeychain.environmentValue(key: key), "new-fixture")
        let renamed = key + "_RENAMED"
        try store.applyRemoteItem(id: "fixture", key: renamed, value: nil, note: "改名",
            createdAt: Date(timeIntervalSince1970: 2), updatedAt: Date(timeIntervalSince1970: 40))
        let reloaded = EnvVarStore(fileURL: url, schedulesCleanup: false)
        XCTAssertEqual(reloaded.entries.first?.key, renamed)
        XCTAssertEqual(reloaded.entries.first?.version, Date(timeIntervalSince1970: 40))
        XCTAssertEqual(try NivoCredentialSyncKeychain.environmentValue(key: renamed), "new-fixture")
        XCTAssertNil(try NivoCredentialSyncKeychain.environmentValue(key: key))
    }

    /// 元数据损坏时不新建空档案，也不向Keychain写入当前输入。
    func testCorruptEnvironmentMetadataRejectsCredentialMutation() throws {
        let (store, url, key) = try environmentFixture()
        let original = Data("{corrupt".utf8)
        try original.write(to: url)
        XCTAssertThrowsError(try store.applyRemoteItem(id: "fixture", key: key, value: "fixture-only", note: "",
            createdAt: Date(), updatedAt: Date()))
        XCTAssertNil(try NivoCredentialSyncKeychain.environmentValue(key: key))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    /// 相同名称的另一身份不能覆盖已有秘密，必须保留原变量供用户处理冲突。
    func testEnvironmentNameCollisionPreservesCredential() throws {
        let (store, _, key) = try environmentFixture()
        try store.applyRemoteItem(id: "fixture", key: key, value: "first-fixture", note: "",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 10))
        XCTAssertThrowsError(try store.applyRemoteItem(id: "other", key: key, value: "second-fixture", note: "",
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 20)))
        XCTAssertEqual(try NivoCredentialSyncKeychain.environmentValue(key: key), "first-fixture")
        XCTAssertEqual(store.entries.map(\.id), ["fixture"])
    }

    private func environmentFixture() throws -> (EnvVarStore, URL, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("metadata.json")
        let key = "NIVO_TEST_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        addTeardownBlock {
            for name in [key, key + "_RENAMED"] {
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "io.github.nanomuse.app.envvar", kSecAttrAccount as String: name,
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
                let status = SecItemDelete(query as CFDictionary)
                XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound)
            }
            try FileManager.default.removeItem(at: root)
        }
        return (EnvVarStore(fileURL: url, schedulesCleanup: false), url, key)
    }

    /// 同值新版本也必须原子更新版本，后来的旧值不能回滚用户凭证。
    func testSyncedCredentialValueAndVersionConvergeAcrossReorderedDelivery() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteAPIKey(instanceId: owner) }
        try NivoCredentialSyncKeychain.importProviders(providerPayload(owner, value: "fixture-current", version: 10))
        try NivoCredentialSyncKeychain.importProviders(providerPayload(owner, value: "fixture-current", version: 30))
        try NivoCredentialSyncKeychain.importProviders(providerPayload(owner, value: "fixture-older", version: 20))
        XCTAssertEqual(ProviderKeychainHelper.loadAPIKey(instanceId: owner), "fixture-current")
        XCTAssertEqual(try NivoCredentialSyncKeychain.savedProviderDate(instanceID: owner), Date(timeIntervalSince1970: 30))
    }

    /// 同步格式错误不会在抛错前先写入本批第一条密钥。
    func testMalformedCredentialBatchDoesNotPartiallyInsert() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteAPIKey(instanceId: owner) }
        let valid = try providerPayload(owner, value: "fixture-only", version: 10)
        let broken = String(valid.dropLast()) + ",{}]"
        XCTAssertThrowsError(try NivoCredentialSyncKeychain.importProviders(broken))
        XCTAssertNil(ProviderKeychainHelper.loadAPIKey(instanceId: owner))
    }

    /// 手动保存保留可读值并推进原子版本，不再经过先删除再新增的窗口。
    func testManualCredentialSaveAdvancesAtomicVersion() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteAPIKey(instanceId: owner) }
        let future = Date().addingTimeInterval(120).timeIntervalSince1970
        try NivoCredentialSyncKeychain.importProviders(providerPayload(owner, value: "remote-fixture", version: future))
        XCTAssertTrue(ProviderKeychainHelper.saveAPIKey("local-fixture", instanceId: owner))
        XCTAssertEqual(ProviderKeychainHelper.loadAPIKey(instanceId: owner), "local-fixture")
        let version = try XCTUnwrap(try NivoCredentialSyncKeychain.savedProviderDate(instanceID: owner))
        XCTAssertGreaterThan(version.timeIntervalSince1970, future)
    }

    private func providerPayload(_ owner: String, value: String, version: Double) throws -> String {
        let payload: [[String: Any]] = [["instanceId": owner,
            "apiKey": Data(value.utf8).base64EncodedString(), "updatedAt": version]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return String(decoding: data, as: UTF8.self)
    }

    func testInsertedCredentialIsVerifiedAndReceiptCanUndoAfterRestart() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteAPIKey(instanceId: owner) }
        let previousSavedAt = ProviderKeychainHelper.apiKeySavedAt(instanceId: owner)
        let earliestRestore = Date().addingTimeInterval(-1)
        let value = Data("fixture-only-value".utf8)
        let plan = try NivoCredentialRestore.prepare([.init(target: .init(kind: .providerAPIKey, owner: owner), data: value)])
        let result = try NivoCredentialRestore.apply(plan)
        XCTAssertEqual(result.inserted.count, 1)
        XCTAssertEqual(ProviderKeychainHelper.loadAPIKey(instanceId: owner), String(decoding: value, as: UTF8.self))
        XCTAssertGreaterThanOrEqual(ProviderKeychainHelper.apiKeySavedAt(instanceId: owner), earliestRestore)
        let encoded = try JSONEncoder().encode(plan.receipt)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(String(decoding: value, as: UTF8.self)))
        let restored = try JSONDecoder().decode(NivoCredentialRestoreReceipt.self, from: encoded)
        try NivoCredentialRestore.rollback(restored)
        try NivoCredentialRestore.rollback(restored)
        XCTAssertNil(ProviderKeychainHelper.loadAPIKey(instanceId: owner))
        XCTAssertEqual(ProviderKeychainHelper.apiKeySavedAt(instanceId: owner), previousSavedAt)
    }

    func testExistingCredentialAndCredentialAppearingAfterPrepareAreKept() throws {
        let owner = UUID().uuidString
        addTeardownBlock { ProviderKeychainHelper.deleteAPIKey(instanceId: owner) }
        let item = NivoCredentialRestore.Item(target: .init(kind: .providerAPIKey, owner: owner), data: Data("backup-fixture".utf8))
        let preparedBefore = try NivoCredentialRestore.prepare([item])
        ProviderKeychainHelper.saveAPIKey("local-fixture", instanceId: owner)
        XCTAssertEqual(ProviderKeychainHelper.loadAPIKey(instanceId: owner), "local-fixture")
        let result = try NivoCredentialRestore.apply(preparedBefore)
        XCTAssertTrue(result.inserted.isEmpty)
        XCTAssertEqual(result.kept.count, 1)
        try NivoCredentialRestore.rollback(preparedBefore.receipt)
        let preparedAfter = try NivoCredentialRestore.prepare([item])
        XCTAssertTrue(preparedAfter.receipt.targets.isEmpty)
        XCTAssertEqual(ProviderKeychainHelper.loadAPIKey(instanceId: owner), "local-fixture")
    }

    func testEnvironmentUpdateRevokesOldRestoreOwnership() throws {
        let owner = "NIVO_TEST_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        addTeardownBlock {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "io.github.nanomuse.app.envvar", kSecAttrAccount as String: owner,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny]
            let status = SecItemDelete(query as CFDictionary)
            XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound)
        }
        let plan = try NivoCredentialRestore.prepare([.init(target: .init(kind: .environment, owner: owner), data: Data("backup-fixture".utf8))])
        _ = try NivoCredentialRestore.apply(plan)
        EnvVarStore.saveValueSync("new-fixture", forKey: owner)
        XCTAssertEqual(EnvVarStore.loadValueSync(forKey: owner), "new-fixture")
        try NivoCredentialRestore.rollback(plan.receipt)
        XCTAssertEqual(EnvVarStore.loadValueSync(forKey: owner), "new-fixture")
    }
}
