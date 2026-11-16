import Foundation
import Security

/// 删除核对材料仅在本机Keychain保存，不把令牌、邮箱或端点写入文件日志。
enum NivoProviderDeletionKeychain {
    private typealias Secret = NivoCredentialDeletion.Secret

    private struct Entry: Codable {
        let account: String
        let synchronizable: Bool
        let expected: Secret?
        var settlement: NivoCredentialDeletion.Settlement? = nil
    }

    private struct Stage: Codable {
        let identifier: UUID
        let instanceID: String
        var entries: [Entry]
    }

    /// 兼容辅助方法的严格删除入口；错误必须由调用方处理，页面使用有日志的宿主入口。
    static func removeCredentials(instanceID: String, accounts: [String]) throws {
        let journal = NivoProviderDeletion.Journal(identifier: UUID(), phase: .synchronized,
            plan: .init(instanceID: instanceID, entryIDs: [], groupIDs: [], updatedGroupIDs: [], ruleIDs: [],
                deletedAt: Date(), credentialAccounts: accounts))
        try withLocks {
            try journal.validate()
            var stage = Stage(identifier: journal.identifier, instanceID: instanceID, entries: try snapshot(journal))
            try cleanup(&stage, journal: journal, persist: { _ in })
            // 兼容入口没有持久恢复屏障，仍用失败回执防止旧调用者误报退出成功。
            if result(stage).hasPreservedCredentials { throw NivoOAuthPersistenceError.conflictingCredential }
        }
    }

    /// 配置提交前捕获同步及本机旧条目，读取受限时停止删除。
    static func prepare(_ journal: NivoProviderDeletion.Journal) throws {
        try withLocks {
            try journal.validate()
            let entries = try snapshot(journal)
            let stage = Stage(identifier: journal.identifier, instanceID: journal.plan.instanceID, entries: entries)
            let data = try JSONEncoder().encode(stage)
            guard data.count <= 16_777_216 else { throw NivoCredentialRestoreError.invalidValue }
            var query = stageQuery(journal.identifier)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(query as CFDictionary, nil), operation: "provider_delete_stage")
            guard try readStageData(journal.identifier) == data else { throw NivoCredentialRestoreError.verificationFailed }
        }
    }

    /// 不把锁屏或权限故障当成没有暂存；恢复由文件阶段决定是否继续。
    static func contains(_ identifier: UUID) throws -> Bool { try withLocks { try readStageData(identifier) != nil } }

    /// 仅清理与开始删除时相同的凭证；后来更新或新出现的条目保持原样。
    static func cleanup(_ journal: NivoProviderDeletion.Journal) throws {
        try withLocks {
            var stage = try requireStage(journal)
            try cleanup(&stage, journal: journal, persist: saveStage)
        }
    }

    /// 终结回执写入普通日志前再次严格读取；只包含保留的账户类别。
    static func outcome(_ journal: NivoProviderDeletion.Journal) throws -> NivoCredentialDeletion.Outcome {
        try withLocks {
            var stage = try requireStage(journal)
            guard stage.entries.allSatisfy({ $0.settlement != nil }) else { throw NivoCredentialRestoreError.verificationFailed }
            try observeReplacements(&stage, persist: saveStage)
            return result(stage)
        }
    }

    private static func snapshot(_ journal: NivoProviderDeletion.Journal) throws -> [Entry] {
        var entries: [Entry] = []
        for account in journal.plan.selectedCredentialAccounts {
            for synchronizable in [true, false] {
                let expected = try readSecret(instanceID: journal.plan.instanceID, account: account, synchronizable: synchronizable)
                if expected != nil || journal.plan.isCredentialOnly {
                    entries.append(Entry(account: account, synchronizable: synchronizable, expected: expected))
                }
            }
        }
        return entries
    }

    private static func cleanup(_ stage: inout Stage, journal: NivoProviderDeletion.Journal,
                                persist: (Stage) throws -> Void) throws {
        // 部分删除失败也让缓存重新读取真实状态，不能保留已删除的旧令牌。
        defer { ProviderKeychainHelper.nmDeviceKeyChanged(instanceId: journal.plan.instanceID) }
        if journal.plan.isCredentialOnly, try hasReplacedCredential(stage, journal: journal) {
            try preserveRemaining(&stage, persist: persist)
        }
        for index in stage.entries.indices where stage.entries[index].settlement == nil {
            stage.entries[index].settlement = try removeUnchanged(stage.entries[index], journal: journal)
            // 每处理完一条就保存回执，后续失败重放不得重新取得已终结条目的所有权。
            try persist(stage)
            if journal.plan.isCredentialOnly, stage.entries[index].settlement == .preserved {
                try preserveRemaining(&stage, persist: persist)
            }
        }
        try observeReplacements(&stage, persist: persist)
        if journal.plan.selectedCredentialAccounts.contains("api-key") {
            try clearAbsentAPIKeyStamp(instanceID: journal.plan.instanceID)
        }
    }

    private static func hasReplacedCredential(_ stage: Stage, journal: NivoProviderDeletion.Journal) throws -> Bool {
        if stage.entries.contains(where: { $0.settlement == .preserved }) { return true }
        let marker = "nivo-provider-delete-" + journal.identifier.uuidString
        for entry in stage.entries where entry.settlement == nil {
            let current = try readSecret(instanceID: stage.instanceID, account: entry.account, synchronizable: entry.synchronizable)
            if NivoCredentialDeletion.action(current: current, expected: entry.expected, marker: marker) == .preserve { return true }
        }
        return false
    }

    private static func preserveRemaining(_ stage: inout Stage, persist: (Stage) throws -> Void) throws {
        // 同组令牌变更后保留尚未清理的关联资料，避免旧退出操作破坏新登录所需的邮箱或端点。
        for index in stage.entries.indices where stage.entries[index].settlement == nil {
            let entry = stage.entries[index]
            let current = try readSecret(instanceID: stage.instanceID, account: entry.account, synchronizable: entry.synchronizable)
            stage.entries[index].settlement = current == nil ? .removed : .preserved
            try persist(stage)
        }
    }

    private static func observeReplacements(_ stage: inout Stage, persist: (Stage) throws -> Void) throws {
        for index in stage.entries.indices where stage.entries[index].settlement == .removed {
            let entry = stage.entries[index]
            if try readSecret(instanceID: stage.instanceID, account: entry.account, synchronizable: entry.synchronizable) != nil {
                stage.entries[index].settlement = .preserved
                try persist(stage)
            }
        }
    }

    private static func result(_ stage: Stage) -> NivoCredentialDeletion.Outcome {
        .init(preservedAccounts: Set(stage.entries.filter { $0.settlement == .preserved }.map(\.account)).sorted())
    }

    private static func clearAbsentAPIKeyStamp(instanceID: String) throws {
        guard try readSecret(instanceID: instanceID, account: "api-key", synchronizable: true) == nil,
              try readSecret(instanceID: instanceID, account: "api-key", synchronizable: false) == nil else { return }
        // 仅在同步及本机密钥都已确认缺失后清除旧兼容时间戳。
        UserDefaults.standard.removeObject(forKey: "providerKey.savedAt." + instanceID)
    }

    private static func saveStage(_ stage: Stage) throws {
        let data = try JSONEncoder().encode(stage)
        guard data.count <= 16_777_216 else { throw NivoCredentialRestoreError.invalidValue }
        try check(SecItemUpdate(stageQuery(stage.identifier) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary), operation: "provider_delete_receipt")
        guard try readStageData(stage.identifier) == data else { throw NivoCredentialRestoreError.verificationFailed }
    }

    /// 清理阶段已持久化后才移除暂存，重复调用也能确认成功。
    static func discard(_ identifier: UUID) throws {
        try withLocks {
            let status = SecItemDelete(stageQuery(identifier) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NivoCredentialRestoreError.keychain(operation: "provider_delete_discard", status: status)
            }
        }
    }

    private static func removeUnchanged(_ entry: Entry, journal: NivoProviderDeletion.Journal) throws -> NivoCredentialDeletion.Settlement {
        let instanceID = journal.plan.instanceID
        let marker = "nivo-provider-delete-" + journal.identifier.uuidString
        let current = try readSecret(instanceID: instanceID, account: entry.account, synchronizable: entry.synchronizable)
        let action = NivoCredentialDeletion.action(current: current, expected: entry.expected, marker: marker)
        if let settled = settlement(for: action) { return settled }
        var query = secretQuery(instanceID: instanceID, account: entry.account, synchronizable: entry.synchronizable)
        if let version = entry.expected?.version { query[kSecAttrGeneric as String] = version }
        if let originalMarker = current?.marker { query[kSecAttrComment as String] = originalMarker }
        let status = SecItemUpdate(query as CFDictionary, [kSecAttrComment as String: marker] as CFDictionary)
        if status == errSecItemNotFound { return try settlementAfterRemoval(entry, journal: journal, marker: marker) }
        try check(status, operation: "provider_delete_mark")
        if let settled = settlement(for: try claimedAction(entry, journal: journal, marker: marker)) { return settled }
        query[kSecAttrComment as String] = marker
        let removed = SecItemDelete(query as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else {
            throw NivoCredentialRestoreError.keychain(operation: "provider_delete_cleanup", status: removed)
        }
        return try settlementAfterRemoval(entry, journal: journal, marker: marker)
    }

    private static func settlement(for action: NivoCredentialDeletion.Action) -> NivoCredentialDeletion.Settlement? {
        switch action {
        case .absent: return .removed
        case .preserve: return .preserved
        case .remove: return nil
        }
    }

    private static func claimedAction(_ entry: Entry, journal: NivoProviderDeletion.Journal, marker: String) throws -> NivoCredentialDeletion.Action {
        guard let current = try readSecret(instanceID: journal.plan.instanceID, account: entry.account, synchronizable: entry.synchronizable)
        else { return .absent }
        return current.marker == marker && current.value == entry.expected?.value && current.version == entry.expected?.version
            ? .remove : .preserve
    }

    private static func settlementAfterRemoval(_ entry: Entry, journal: NivoProviderDeletion.Journal,
                                               marker: String) throws -> NivoCredentialDeletion.Settlement {
        guard let current = try readSecret(instanceID: journal.plan.instanceID, account: entry.account, synchronizable: entry.synchronizable)
        else { return .removed }
        guard current.marker != marker || current.value != entry.expected?.value || current.version != entry.expected?.version
        else { throw NivoCredentialRestoreError.verificationFailed }
        return .preserved
    }

    private static func requireStage(_ journal: NivoProviderDeletion.Journal) throws -> Stage {
        try journal.validate()
        guard let data = try readStageData(journal.identifier) else { throw NivoProviderDeletion.Failure.missingStage }
        let stage = try JSONDecoder().decode(Stage.self, from: data)
        let accounts = journal.plan.selectedCredentialAccounts
        guard stage.identifier == journal.identifier, stage.instanceID == journal.plan.instanceID,
              stage.entries.count <= accounts.count * 2,
              stage.entries.allSatisfy({ accounts.contains($0.account) && ($0.expected?.value.count ?? 0) <= 1_048_576 }),
              (journal.plan.isCredentialOnly || stage.entries.allSatisfy({ $0.expected != nil })),
              Set(stage.entries.map { $0.account + ($0.synchronizable ? ":sync" : ":local") }).count == stage.entries.count else {
            throw NivoCredentialRestoreError.invalidValue
        }
        guard !journal.plan.isCredentialOnly || stage.entries.count == accounts.count * 2 else {
            throw NivoCredentialRestoreError.invalidValue
        }
        return stage
    }

    private static func readSecret(instanceID: String, account: String, synchronizable: Bool) throws -> Secret? {
        var query = secretQuery(instanceID: instanceID, account: account, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, operation: "provider_delete_read")
        guard let attributes = result as? [String: Any], let value = attributes[kSecValueData as String] as? Data,
              value.count <= 1_048_576 else { throw NivoCredentialRestoreError.invalidValue }
        return Secret(value: value, version: attributes[kSecAttrGeneric as String] as? Data,
            modifiedAt: attributes[kSecAttrModificationDate as String] as? Date, marker: attributes[kSecAttrComment as String] as? String)
    }

    private static func readStageData(_ identifier: UUID) throws -> Data? {
        var query = stageQuery(identifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, operation: "provider_delete_stage_read")
        guard let data = result as? Data, data.count <= 16_777_216 else { throw NivoCredentialRestoreError.invalidValue }
        return data
    }

    private static func secretQuery(instanceID: String, account: String, synchronizable: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.github.nanomuse.app.provider." + instanceID,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: synchronizable]
    }

    private static func stageQuery(_ identifier: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.github.nanomuse.app.provider-deletion",
         kSecAttrAccount as String: identifier.uuidString, kSecAttrSynchronizable as String: false]
    }

    /// 固定API锁再OAuth锁的顺序；这只串行化本进程，不声明跨设备Keychain事务。
    private static func withLocks<Value>(_ body: () throws -> Value) rethrows -> Value {
        try NivoCredentialSyncKeychain.withEnvironmentLock { try NivoProviderOAuthKeychain.withMutationLock(body) }
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else { throw NivoCredentialRestoreError.keychain(operation: operation, status: status) }
    }
}
