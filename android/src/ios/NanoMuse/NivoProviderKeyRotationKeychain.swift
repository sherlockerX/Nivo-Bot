import Foundation
import Security

/// 密钥轮换与普通同步共用进程锁，恢复材料只放入不参与iCloud同步的Keychain服务。
enum NivoProviderKeyRotationKeychain {
    private static let STAGE_SERVICE = "io.github.nanomuse.app.provider-key-rotation"
    private typealias Secret = NivoProviderKeyRotation.Secret
    private typealias Stage = NivoProviderKeyRotation.Stage

    /// 在正式日志建立前保存并回读暂存；此时不改正式密钥和旧版时间戳。
    static func prepare(_ value: String, instanceID: String,
                        expected: NivoCredentialSyncKeychain.ProviderSnapshot?) throws -> NivoProviderKeyRotation.Receipt {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            let receipt = NivoProviderKeyRotation.Receipt(identifier: UUID(), instanceID: instanceID)
            try receipt.validate()
            guard try NivoCredentialSyncKeychain.providerSnapshot(instanceID: instanceID) == expected else {
                throw NivoOAuthPersistenceError.conflictingCredential
            }
            let previousSync = try readSecret(instanceID: instanceID, synchronizable: true)
            let previousLocal = try readSecret(instanceID: instanceID, synchronizable: false)
            let seen = expected?.version ?? ProviderKeychainHelper.apiKeySavedAt(instanceId: instanceID)
            let date = NivoProviderEditClock.next(after: [seen], now: Date())
            let version = try JSONEncoder().encode(NivoProviderKeyRotation.Version(schema: 1, seconds: date.timeIntervalSince1970))
            let replacement = Secret(value: Data(value.utf8), version: version, comment: receipt.comment,
                accessibility: kSecAttrAccessibleAfterFirstUnlock as String)
            let stage = Stage(receipt: receipt, previousSync: previousSync, previousLocal: previousLocal, replacement: replacement)
            try stage.validate()
            guard try stage.matchesPrevious(value: expected?.value, version: expected?.version,
                fallbackVersion: ProviderKeychainHelper.apiKeySavedAt(instanceId: instanceID)) else {
                throw NivoOAuthPersistenceError.conflictingCredential
            }
            let data = try JSONEncoder().encode(stage)
            var query = stageQuery(receipt.identifier)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(query as CFDictionary, nil), operation: "rotation_prepare")
            guard try requireStage(receipt) == stage else { throw NivoCredentialRestoreError.verificationFailed }
            return receipt
        }
    }

    /// 日志已落盘后才调用，等待快照期间变化的同步或旧本机条目都拒绝覆盖。
    static func apply(_ receipt: NivoProviderKeyRotation.Receipt) throws {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            let stage = try requireStage(receipt)
            guard try readSecret(instanceID: receipt.instanceID, synchronizable: true) == stage.previousSync,
                  try readSecret(instanceID: receipt.instanceID, synchronizable: false) == stage.previousLocal else {
                throw NivoOAuthPersistenceError.conflictingCredential
            }
            defer { ProviderKeychainHelper.nmDeviceKeyChanged(instanceId: receipt.instanceID) }
            var query = secretQuery(instanceID: receipt.instanceID, synchronizable: true)
            let attributes = attributes(stage.replacement)
            let status: OSStatus
            if let previous = stage.previousSync {
                // 将读到的旧版本和标记交给系统匹配，读取之后到达的同步不能被无条件覆盖。
                query[kSecAttrGeneric as String] = previous.version ?? Data()
                query[kSecAttrComment as String] = previous.comment
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            } else {
                status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
            if status == errSecItemNotFound || status == errSecDuplicateItem {
                throw NivoOAuthPersistenceError.conflictingCredential
            }
            try check(status, operation: "rotation_apply")
            guard try readSecret(instanceID: receipt.instanceID, synchronizable: true) == stage.replacement else {
                throw NivoCredentialRestoreError.verificationFailed
            }
        }
    }

    /// 重启及当场失败共用回滚，保留暂存直至文件日志删除成功。
    static func rollback(_ receipt: NivoProviderKeyRotation.Receipt) throws {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            let stage = try requireStage(receipt)
            let current = try readSecret(instanceID: receipt.instanceID, synchronizable: true)
            let decision = try stage.rollback(current: current)
            if decision == .preserve { return }
            defer { ProviderKeychainHelper.nmDeviceKeyChanged(instanceId: receipt.instanceID) }
            var query = secretQuery(instanceID: receipt.instanceID, synchronizable: true)
            query[kSecAttrComment as String] = receipt.comment
            query[kSecAttrGeneric as String] = stage.replacement.version
            switch decision {
            case .preserve: return
            case .remove:
                let status = SecItemDelete(query as CFDictionary)
                if status != errSecItemNotFound { try check(status, operation: "rotation_remove") }
            case .restore(let previous):
                let status = SecItemUpdate(query as CFDictionary, attributes(previous) as CFDictionary)
                if status != errSecItemNotFound { try check(status, operation: "rotation_restore") }
            }
            // 比较条件未命中说明系统同步已经更新条目；不能降级为无条件写入。
            let after = try readSecret(instanceID: receipt.instanceID, synchronizable: true)
            guard try stage.rollback(current: after) == .preserve else { throw NivoCredentialRestoreError.verificationFailed }
        }
    }

    /// 日志提交后清理，不得在尚需恢复时调用。
    static func discard(_ identifier: UUID) throws {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            let status = SecItemDelete(stageQuery(identifier) as CFDictionary)
            if status != errSecItemNotFound { try check(status, operation: "rotation_discard") }
        }
    }

    /// 只在启动恢复或开始新事务前清理；损坏日志不允许清理任何恢复材料。
    static func discardOrphans(preserving receipt: NivoProviderKeyRotation.Receipt?) throws {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: STAGE_SERVICE, kSecAttrSynchronizable as String: false,
                kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
            query[kSecReturnData as String] = false
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return }
            try check(status, operation: "rotation_list")
            guard let rows = result as? [[String: Any]] else { throw NivoCredentialRestoreError.verificationFailed }
            let identifiers = try rows.map { row in
                guard let name = row[kSecAttrAccount as String] as? String, let identifier = UUID(uuidString: name) else {
                    throw NivoCredentialRestoreError.invalidValue
                }
                return identifier
            }
            try discardOrphans(preserving: receipt, among: identifiers)
        }
    }

    /// 仅清理调用方已经确认可清理的暂存集合，保留当前日志引用；独立测试也无需扫描其他事务。
    static func discardOrphans(preserving receipt: NivoProviderKeyRotation.Receipt?, among identifiers: [UUID]) throws {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            try receipt?.validate()
            for identifier in Set(identifiers) where identifier != receipt?.identifier { try discard(identifier) }
        }
    }

    private static func requireStage(_ receipt: NivoProviderKeyRotation.Receipt) throws -> Stage {
        try receipt.validate()
        var query = stageQuery(receipt.identifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &result), operation: "rotation_read_stage")
        guard let data = result as? Data, data.count <= 8_388_608 else { throw NivoCredentialRestoreError.invalidValue }
        let stage = try JSONDecoder().decode(Stage.self, from: data)
        try stage.validate()
        guard stage.receipt == receipt else { throw NivoCredentialRestoreError.invalidValue }
        return stage
    }

    private static func readSecret(instanceID: String, synchronizable: Bool) throws -> Secret? {
        var query = secretQuery(instanceID: instanceID, synchronizable: synchronizable)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, operation: "rotation_read")
        guard let row = result as? [String: Any], let value = row[kSecValueData as String] as? Data else {
            throw NivoCredentialRestoreError.verificationFailed
        }
        let version = row[kSecAttrGeneric as String] as? Data
        return Secret(value: value, version: version?.isEmpty == false ? version : nil,
            comment: row[kSecAttrComment as String] as? String ?? "",
            accessibility: row[kSecAttrAccessible as String] as? String)
    }

    private static func attributes(_ secret: Secret) -> [String: Any] {
        [kSecValueData as String: secret.value, kSecAttrGeneric as String: secret.version ?? Data(),
         kSecAttrComment as String: secret.comment,
         kSecAttrAccessible as String: secret.accessibility ?? (kSecAttrAccessibleAfterFirstUnlock as String)]
    }

    private static func secretQuery(instanceID: String, synchronizable: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.nanomuse.app.provider." + instanceID,
         kSecAttrAccount as String: "api-key", kSecAttrSynchronizable as String: synchronizable]
    }

    private static func stageQuery(_ identifier: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: STAGE_SERVICE,
         kSecAttrAccount as String: identifier.uuidString, kSecAttrSynchronizable as String: false]
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else { throw NivoCredentialRestoreError.keychain(operation: operation, status: status) }
    }
}
