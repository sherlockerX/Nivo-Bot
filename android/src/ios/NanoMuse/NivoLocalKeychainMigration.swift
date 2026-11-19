import Foundation
import Security

/// 旧事务恢复后将本App凭据迁到仅本机Keychain，不处理设备标识或MCP服务。
enum NivoLocalKeychainMigration {
    private struct Target: Hashable {
        let service: String
        let account: String
    }

    private struct Payload: Equatable {
        let value: Data
        let version: Data?
        let comment: String
    }

    /// 启动恢复完成后调用；任何系统错误均中止，已经确认的本机副本可以安全重试。
    @MainActor
    static func migrateDuringStartup() async throws {
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            try NivoProviderOAuthKeychain.withMutationLock {
                for target in try targets() { try migrate(target) }
            }
        }
        ProviderCredentialCache.shared.invalidateAll()
    }

    /// 定向迁移也受范围和共享锁保护，测试与维护调用无需扫描其他凭据。
    static func migrateCredential(service: String, account: String) throws {
        guard NivoLocalCredentialMigration.includes(service: service, account: account) else { return }
        try NivoCredentialSyncKeychain.withEnvironmentLock {
            try NivoProviderOAuthKeychain.withMutationLock {
                try migrate(Target(service: service, account: account))
            }
        }
    }

    private static func migrate(_ target: Target) throws {
        try NivoLocalCredentialMigration.migrate(
            readCloud: { try read(target, synchronizable: true) },
            readLocal: { try read(target, synchronizable: false) },
            insertLocal: { try insert($0, target: target) },
            removeCloud: { try remove($0, target: target) })
    }

    private static func targets() throws -> [Target] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrSynchronizable as String: true, kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status, operation: "local_migration_list")
        guard let rows = result as? [[String: Any]] else { throw NivoCredentialRestoreError.verificationFailed }
        let selected: [Target] = rows.compactMap { row in
            guard let service = row[kSecAttrService as String] as? String,
                  let account = row[kSecAttrAccount as String] as? String,
                  NivoLocalCredentialMigration.includes(service: service, account: account) else { return nil }
            return Target(service: service, account: account)
        }
        return Array(Set(selected))
    }

    private static func read(_ target: Target, synchronizable: Bool) throws -> Payload? {
        var query = match(target, synchronizable: synchronizable)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, operation: "local_migration_read")
        guard let row = result as? [String: Any], let value = row[kSecValueData as String] as? Data,
              value.count <= 1_048_576 else { throw NivoCredentialRestoreError.verificationFailed }
        let version = row[kSecAttrGeneric as String] as? Data
        return Payload(value: value, version: version?.isEmpty == false ? version : nil,
            comment: row[kSecAttrComment as String] as? String ?? "")
    }

    private static func insert(_ payload: Payload, target: Target) throws {
        var query = match(target, synchronizable: false)
        query[kSecValueData as String] = payload.value
        query[kSecAttrGeneric as String] = payload.version ?? Data()
        query[kSecAttrComment as String] = payload.comment
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // 只插入；读取后并发出现的本机条目必须保留，不能退化为覆盖写入。
        try check(SecItemAdd(query as CFDictionary, nil), operation: "local_migration_insert")
    }

    private static func remove(_ expected: Payload, target: Target) throws {
        guard try read(target, synchronizable: true) == expected,
              let confirmedLocal = try read(target, synchronizable: false) else {
            throw NivoOAuthPersistenceError.conflictingCredential
        }
        var query = match(target, synchronizable: true)
        if let version = expected.version { query[kSecAttrGeneric as String] = version }
        if !expected.comment.isEmpty { query[kSecAttrComment as String] = expected.comment }
        let marker = "nivo-local-migration-" + UUID().uuidString
        // 沿用现有删除事务的认领协议；来源变化时保留它并在下一次启动重试。
        try check(SecItemUpdate(query as CFDictionary, [kSecAttrComment as String: marker] as CFDictionary),
                  operation: "local_migration_claim")
        guard let claimed = try read(target, synchronizable: true), claimed.value == expected.value,
              claimed.version == expected.version, claimed.comment == marker,
              try read(target, synchronizable: false) == confirmedLocal else {
            throw NivoOAuthPersistenceError.conflictingCredential
        }
        query[kSecAttrComment as String] = marker
        try check(SecItemDelete(query as CFDictionary), operation: "local_migration_remove")
        guard try read(target, synchronizable: true) == nil else {
            throw NivoOAuthPersistenceError.conflictingCredential
        }
    }

    private static func match(_ target: Target, synchronizable: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: target.service,
         kSecAttrAccount as String: target.account, kSecAttrSynchronizable as String: synchronizable]
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else { throw NivoCredentialRestoreError.keychain(operation: operation, status: status) }
    }
}
