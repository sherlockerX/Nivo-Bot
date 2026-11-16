import Foundation

/// 单份JSON完整解析后的配置意图，秘密仅在内存和有回滚标记的Keychain条目中。
struct NivoPreparedProviderImport {
    let instance: ProviderInstance
    let configuration: ProviderConfig
    let credentials: [NivoCredentialRestore.Item]
}

/// 单提供商分享导入沿用已有备份回滚协议，不建立第二套跨存储恢复格式。
@MainActor
enum NivoProviderJSONImport {
    /// 保存回传的是本次释放租约后的代次，不能在actor往返后重新接受其他事务的身份。
    private struct Completion {
        let instance: ProviderInstance
        let scope: NivoOAuthScope
    }

    private struct Rotation {
        let value: String
        let expected: NivoCredentialSyncKeychain.ProviderSnapshot?
    }

    /// 固定发起表单的账户，等待锁以后仍须检查，完整落盘才返回成功名称。
    static func run(_ json: String, sourceScope: NivoOAuthScope,
                    onRestoreFinished: (@MainActor (NivoOAuthScope) -> Void)? = nil) async throws -> String {
        let saved = try await performLocked(sourceScope: sourceScope, onRestoreFinished: onRestoreFinished) {
                try ProviderConfigStore.shared.nmPrepareInstanceImport(json)
        }
        refreshIfNeeded(saved, always: false)
        return saved.instance.label
    }

    /// API密钥新增复用导入的跨存储回滚边界，无密钥本机端点同样等待配置确认。
    static func create(_ instance: ProviderInstance, apiKey: String?, sourceScope: NivoOAuthScope,
                       models: [LLMModel] = [], defaultChatModel: String? = nil,
                       onRestoreFinished: (@MainActor (NivoOAuthScope) -> Void)? = nil) async throws {
        let saved = try await performLocked(sourceScope: sourceScope, onRestoreFinished: onRestoreFinished) {
                try NivoProviderSetupConfiguration.prepare(instance: instance, apiKey: apiKey, current: ProviderConfigStore.shared.config,
                    models: models, defaultChatModel: defaultChatModel)
        }
        refreshIfNeeded(saved, always: models.isEmpty)
    }

    /// 授权成功与配置保存分开确认，浏览器已有令牌不会因为配置回滚而被清除。
    static func createOAuth(_ instance: ProviderInstance, manualToken: String? = nil, sourceScope: NivoOAuthScope,
                            models: [LLMModel] = [], defaultChatModel: String? = nil,
                            onRestoreFinished: (@MainActor (NivoOAuthScope) -> Void)? = nil) async throws {
        let saved = try await performLocked(sourceScope: sourceScope, onRestoreFinished: onRestoreFinished) {
                if manualToken == nil { try requireAuthorization(instance) }
                return try NivoProviderSetupConfiguration.prepareOAuth(instance: instance, manualToken: manualToken,
                    current: ProviderConfigStore.shared.config, models: models, defaultChatModel: defaultChatModel)
        }
        refreshIfNeeded(saved, always: models.isEmpty)
    }

    /// 旧实例的密钥轮换及OAuth登录后的目录更新复用同一保存事务。
    static func update(_ instance: ProviderInstance, models: [LLMModel], defaultChatModel: String?,
                       apiKey: String? = nil, expectedKey: NivoCredentialSyncKeychain.ProviderSnapshot? = nil,
                       sourceScope: NivoOAuthScope,
                       onRestoreFinished: (@MainActor (NivoOAuthScope) -> Void)? = nil) async throws {
        let rotation = apiKey.map { Rotation(value: $0, expected: expectedKey) }
        let saved = try await performLocked(sourceScope: sourceScope, rotation: rotation,
            onRestoreFinished: onRestoreFinished) {
            if instance.credentialType == .oauth { try requireAuthorization(instance) }
            return try NivoProviderSetupConfiguration.updating(instance: instance,
                current: ProviderConfigStore.shared.config, models: models, defaultChatModel: defaultChatModel)
        }
        refreshIfNeeded(saved, always: models.isEmpty)
    }

    private static func requireAuthorization(_ instance: ProviderInstance) throws {
        let manual = try NivoProviderOAuthKeychain.read(instanceID: instance.id, account: "manual-oauth-token")
        let credential: Data?
        if let manual { credential = manual }
        else if instance.providerType == .openRouter {
            credential = try NivoCredentialSyncKeychain.providerValue(instanceID: instance.id)
        } else {
            credential = try NivoProviderOAuthKeychain.read(instanceID: instance.id, account: "oauth-token")
        }
        guard let credential, !credential.isEmpty else { throw NivoOAuthPersistenceError.invalidValue }
    }

    private static func refreshIfNeeded(_ completion: Completion, always: Bool) {
        let store = ProviderConfigStore.shared
        let instance = completion.instance
        let refreshScope = completion.scope
        guard refreshScope == NivoOAuthAccess.captureScope(),
              store.instance(for: instance.id) == instance,
              always || store.entries(for: instance.id).isEmpty else { return }
        Task {
            do { try NivoOAuthAccess.validateScope(refreshScope) }
            catch { return }
            await store.refreshModels(for: instance)
        }
    }

    private static func performLocked(sourceScope: NivoOAuthScope, rotation: Rotation? = nil,
                                      onRestoreFinished: (@MainActor (NivoOAuthScope) -> Void)?,
                                      prepare: @MainActor () throws -> NivoPreparedProviderImport) async throws -> Completion {
        let activity = try await BackupActivityLock.shared.acquire(.restore)
        do {
            let result = try await perform(sourceScope: sourceScope, rotation: rotation,
                onRestoreFinished: onRestoreFinished, prepare: prepare)
            await BackupActivityLock.shared.release(activity)
            return result
        } catch {
            await BackupActivityLock.shared.release(activity)
            throw error
        }
    }

    private static func perform(sourceScope: NivoOAuthScope, rotation: Rotation?,
                                onRestoreFinished: (@MainActor (NivoOAuthScope) -> Void)?,
                                prepare: @MainActor () throws -> NivoPreparedProviderImport) async throws -> Completion {
        try NivoOAuthAccess.validateScope(sourceScope)
        let store = ProviderConfigStore.shared
        let lease = try NivoPersonalBackupAccess.beginProviderRestore(personalLeaseID: nil)
        let instance: ProviderInstance
        do {
            try await store.nmBeginRestore(lease)
            let previous = store.config
            let prepared = try prepare()
            try await commit(prepared, previous: previous, rotation: rotation, lease: lease)
            instance = prepared.instance
        } catch {
            _ = finishLease(lease, onRestoreFinished: onRestoreFinished)
            throw error
        }
        return Completion(instance: instance, scope: finishLease(lease, onRestoreFinished: onRestoreFinished))
    }

    private static func finishLease(_ lease: UUID, onRestoreFinished: (@MainActor (NivoOAuthScope) -> Void)?) -> NivoOAuthScope {
        ProviderConfigStore.shared.nmEndRestore(lease)
        NivoPersonalBackupAccess.endProviderRestore(lease)
        let finishedScope = NivoOAuthAccess.captureScope()
        // 只更新本次确实取得租约的表单；调用方仍须校验旧表单和账户身份。
        onRestoreFinished?(finishedScope)
        return finishedScope
    }

    private static func commit(_ prepared: NivoPreparedProviderImport, previous: ProviderConfig,
                               rotation: Rotation?, lease: UUID) async throws {
        let store = ProviderConfigStore.shared
        let credentialPlan = try NivoCredentialRestore.prepare(prepared.credentials)
        guard credentialPlan.kept.isEmpty else { throw NivoOAuthPersistenceError.conflictingCredential }
        let runID = UUID().uuidString
        let staging = BackupRestoreJournal.stagingRoot(runId: runID)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let importer = BackupImporter()
        let snapshot = try await importer.snapshotForRollback(category: .providers, staging: staging)
        let syncPlan = NivoProviderSetupConfiguration.syncPlan(prepared, previous: previous)
        let queueReceipt = try await ChatStore.shared.nmPrepareProviderSetup(syncPlan, zoneName: DeviceIdentity.zoneName)
        let keyReceipt = try rotation.map {
            guard prepared.instance.credentialType == .apiKey else { throw NivoOAuthPersistenceError.invalidValue }
            return try NivoProviderKeyRotationKeychain.prepare($0.value, instanceID: prepared.instance.id, expected: $0.expected)
        }
        do {
            try BackupRestoreJournal.begin(backupId: "provider-json-" + runID, categories: [BackupCategory.providers.rawValue],
                runId: runID, credentialRestore: credentialPlan.receipt,
                providerKeyRotation: keyReceipt, providerSetupQueue: queueReceipt)
        } catch {
            // 尚未建立日志，也未改正式存储；暂存清理失败留给冷启动处理。
            if let keyReceipt { try? NivoProviderKeyRotationKeychain.discard(keyReceipt.identifier) }
            throw error
        }
        try await NivoProviderImportCommit.run(writeCredentials: {
            let outcome = try NivoCredentialRestore.apply(credentialPlan)
            guard outcome.kept.isEmpty else { throw NivoOAuthPersistenceError.conflictingCredential }
            if let keyReceipt { try NivoProviderKeyRotationKeychain.apply(keyReceipt) }
        }, persist: {
            try await store.nmCommitImportedConfiguration(prepared.configuration, token: lease)
        }, synchronize: {
            try await ChatStore.shared.nmCommitProviderSetup(queueReceipt)
        }, finish: {
            try BackupRestoreJournal.finish(runId: runID)
        }, isPending: { BackupRestoreJournal.hasPendingRecovery }, rollback: {
            try await importer.rollback(snapshot)
            try NivoCredentialRestore.rollback(credentialPlan.receipt)
            if let keyReceipt { try NivoProviderKeyRotationKeychain.rollback(keyReceipt) }
            try await ChatStore.shared.nmRollbackProviderSetup(queueReceipt)
        })
    }
}
