import Foundation
import Security

/// OAuth凭证的严格Keychain入口，权限故障与缺少记录分开处理。
enum NivoProviderOAuthKeychain {
    private static let lock = NSRecursiveLock()
    private static let accounts: Set<String> = ["oauth-token", "manual-oauth-token", "oauth-email", "oauth-gcp-project", "oauth-base-url"]

    /// 删除与OAuth原位写入共享进程锁，避免本机清理在值核对之间交错。
    static func withMutationLock<Value>(_ body: () throws -> Value) rethrows -> Value { try lock.withLock(body) }

    /// 同步条目优先；只有确实不存在时才读取旧的本机条目。
    static func read(instanceID: String, account: String) throws -> Data? {
        try lock.withLock {
            try validate(instanceID: instanceID, account: account)
            let service = "io.github.nanomuse.app.provider." + instanceID
            if let value = try read(service: service, account: account, synchronizable: true) { return value }
            return try read(service: service, account: account, synchronizable: false)
        }
    }

    /// 使用原位写入及读回确认，不清除旧的非同步条目作为写入前置步骤。
    static func save(_ value: Data, instanceID: String, account: String) throws {
        try lock.withLock {
            try validate(instanceID: instanceID, account: account)
            let service = "io.github.nanomuse.app.provider." + instanceID
            // 旧条目读取受限时也不能新建另一份并假装替换成功。
            _ = try read(service: service, account: account, synchronizable: false)
            try NivoOAuthPersistence.save(value,
                read: { try read(service: service, account: account, synchronizable: true) },
                update: { try write($0, service: service, account: account, isUpdate: true) },
                insert: { try write($0, service: service, account: account, isUpdate: false) })
        }
    }

    /// 迁移直接读取旧服务，任何非“记录不存在”的状态都会保留来源并抛错。
    static func readLegacy(service: String, account: String) throws -> Data? {
        try lock.withLock { try read(service: service, account: account, synchronizable: false) }
    }

    /// 配置和新凭证均已确认后才清理旧来源，来源变化则停止删除。
    static func removeLegacy(service: String, account: String, expected: Data) throws {
        try lock.withLock {
            guard let current = try read(service: service, account: account, synchronizable: false) else { return }
            guard current == expected else { throw NivoOAuthPersistenceError.conflictingCredential }
            let query = match(service: service, account: account, synchronizable: false)
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NivoOAuthPersistenceError.storage(operation: "legacy_delete", status: status)
            }
            guard try read(service: service, account: account, synchronizable: false) == nil else {
                throw NivoOAuthPersistenceError.verificationFailed
            }
        }
    }

    private static func validate(instanceID: String, account: String) throws {
        guard !instanceID.isEmpty, instanceID.utf8.count <= 512, !instanceID.contains("\0"),
              accounts.contains(account) else { throw NivoOAuthPersistenceError.invalidValue }
    }

    private static func read(service: String, account: String, synchronizable: Bool) throws -> Data? {
        var query = match(service: service, account: account, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NivoOAuthPersistenceError.storage(operation: "read", status: status) }
        guard let data = result as? Data else { throw NivoOAuthPersistenceError.verificationFailed }
        return data
    }

    private static func write(_ data: Data, service: String, account: String, isUpdate: Bool) throws {
        let query = match(service: service, account: account, synchronizable: true)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock, kSecAttrComment as String: ""]
        let status = isUpdate ? SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            : SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else { throw NivoOAuthPersistenceError.storage(operation: "write", status: status) }
    }

    private static func match(service: String, account: String, synchronizable: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: synchronizable]
    }
}
