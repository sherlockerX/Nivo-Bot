import Foundation
import Security

/// 仅在本机Keychain暂存恢复所需的值，文件日志中不包含秘密或秘密摘要。
enum NivoEnvVarKeychainTransaction {
    private struct Secret: Codable, Equatable {
        var value: Data
        var version: Data?
    }

    private struct Cleanup: Codable {
        var key: String
        var synchronizable: Bool
        var expected: Secret
    }

    private struct Stage: Codable {
        var identifier: UUID
        var key: String?
        var value: String?
        var version: Date?
        var cleanup: [Cleanup]
    }

    static var credentials: NivoEnvVarTransaction.Credentials {
        .init(contains: { try readStage($0) != nil }, apply: apply, cleanup: cleanup, discard: discard)
    }

    /// 在持久日志之后创建秘密暂存，系统失败时由日志决定重试或撤销。
    static func prepare(_ journal: NivoEnvVarTransaction.Journal, value: String?) throws {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            try journal.validate()
            guard (journal.writeKey == nil) == (value == nil), (value?.utf8.count ?? 0) <= 1_048_576 else {
                throw NivoCredentialRestoreError.invalidValue
            }
            let cleanup = try captureCleanup(keys: journal.cleanupKeys)
            let stage = Stage(identifier: journal.identifier, key: journal.writeKey, value: value,
                version: journal.after.first { $0.key == journal.writeKey }?.version, cleanup: cleanup)
            let encoded = try JSONEncoder().encode(stage)
            var query = stageQuery(journal.identifier)
            query[kSecValueData as String] = encoded
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(query as CFDictionary, nil), operation: "env_stage")
            guard try readData(stageQuery(journal.identifier)) == encoded else {
                throw NivoCredentialRestoreError.verificationFailed
            }
        }
    }

    private static func captureCleanup(keys: [String]) throws -> [Cleanup] {
        var snapshots: [Cleanup] = []
        for key in keys {
            for synchronizable in [true, false] {
                if let expected = try readSecret(key, synchronizable: synchronizable) {
                    snapshots.append(Cleanup(key: key, synchronizable: synchronizable, expected: expected))
                }
            }
        }
        return snapshots
    }

    private static func apply(_ journal: NivoEnvVarTransaction.Journal) throws {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            let stage = try requireStage(journal)
            if let key = stage.key, let value = stage.value, let version = stage.version {
                _ = try NivoCredentialSyncKeychain.saveEnvironment(value, key: key, version: version)
            }
        }
    }

    private static func cleanup(_ journal: NivoEnvVarTransaction.Journal) throws {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            let stage = try requireStage(journal)
            for entry in stage.cleanup { try removeUnchanged(entry, identifier: journal.identifier) }
        }
    }

    /// 先核对旧值及版本，再标记并回读；删除必须匹配本次标记，后来更新的值保留。
    private static func removeUnchanged(_ entry: Cleanup, identifier: UUID) throws {
        guard try readSecret(entry.key, synchronizable: entry.synchronizable) == entry.expected else { return }
        var query = secretQuery(entry.key, synchronizable: entry.synchronizable)
        if let version = entry.expected.version { query[kSecAttrGeneric as String] = version }
        let marker = "nivo-env-cleanup-" + identifier.uuidString
        let status = SecItemUpdate(query as CFDictionary, [kSecAttrComment as String: marker] as CFDictionary)
        if status == errSecItemNotFound { return }
        try check(status, operation: "env_cleanup_mark")
        guard try readSecret(entry.key, synchronizable: entry.synchronizable) == entry.expected else { return }
        query[kSecAttrComment as String] = marker
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw NivoCredentialRestoreError.keychain(operation: "env_cleanup", status: deleted)
        }
    }

    private static func requireStage(_ journal: NivoEnvVarTransaction.Journal) throws -> Stage {
        guard let stage = try readStage(journal.identifier), stage.identifier == journal.identifier,
              stage.key == journal.writeKey,
              (stage.value == nil) == (stage.key == nil),
              stage.version == journal.after.first(where: { $0.key == journal.writeKey })?.version,
              Set(stage.cleanup.map(\.key)).isSubset(of: Set(journal.cleanupKeys)),
              Set(stage.cleanup.map { $0.key + ($0.synchronizable ? ":sync" : ":local") }).count == stage.cleanup.count,
              stage.cleanup.count <= 2 else { throw NivoCredentialRestoreError.invalidValue }
        return stage
    }

    private static func readStage(_ identifier: UUID) throws -> Stage? {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            guard let data = try readData(stageQuery(identifier)) else { return nil }
            guard data.count <= 8_388_608 else { throw NivoCredentialRestoreError.invalidValue }
            let stage = try JSONDecoder().decode(Stage.self, from: data)
            guard stage.identifier == identifier else { throw NivoCredentialRestoreError.invalidValue }
            return stage
        }
    }

    private static func discard(_ identifier: UUID) throws {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            let status = SecItemDelete(stageQuery(identifier) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NivoCredentialRestoreError.keychain(operation: "env_stage_discard", status: status)
            }
        }
    }

    private static func readSecret(_ key: String, synchronizable: Bool) throws -> Secret? {
        var query = secretQuery(key, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, operation: "env_cleanup_read")
        guard let attributes = result as? [String: Any], let data = attributes[kSecValueData as String] as? Data else {
            throw NivoCredentialRestoreError.verificationFailed
        }
        return Secret(value: data, version: attributes[kSecAttrGeneric as String] as? Data)
    }

    private static func readData(_ base: [String: Any]) throws -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, operation: "env_stage_read")
        guard let data = result as? Data else { throw NivoCredentialRestoreError.verificationFailed }
        return data
    }

    private static func stageQuery(_ identifier: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.nanomuse.app.envvar-transaction",
         kSecAttrAccount as String: identifier.uuidString, kSecAttrSynchronizable as String: false]
    }

    private static func secretQuery(_ key: String, synchronizable: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.nanomuse.app.envvar",
         kSecAttrAccount as String: key, kSecAttrSynchronizable as String: synchronizable]
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else { throw NivoCredentialRestoreError.keychain(operation: operation, status: status) }
    }
}
