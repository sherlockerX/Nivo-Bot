import Foundation
import Security

/// 凭据仅写本机Keychain，旧同步读取只为升级兼容，值与版本仍原子提交。
enum NivoCredentialSyncKeychain {
    private static let lock = NSRecursiveLock()

    /// 环境变量的文件协议和非隔离读取共用同一进程锁，防止读到本机半份变更。
    static func withEnvironmentLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        try lock.withLock(body)
    }

    private struct Version: Codable {
        let schema: Int
        let seconds: Double
    }

    private struct Snapshot {
        let value: Data
        let version: Date?
    }

    /// 网络探测只在内存保留观察到的值与版本，日志中不保存秘密。
    struct ProviderSnapshot: Equatable, Sendable {
        let value: Data
        let version: Date
    }

    /// 同一批先完成格式校验，再逐项幂等写入；系统失败由上层保留同步游标。
    static func importProviders(_ json: String) throws {
        let entries = try NivoCredentialSync.providers(json)
        try lock.withLock {
            for entry in entries { try importProvider(entry) }
        }
    }

    /// 环境变量旧协议只填缺失值，读取权限错误不能被视为空条目。
    static func importEnvironments(_ json: String) throws {
        let entries = try NivoCredentialSync.environments(json)
        try lock.withLock {
            for entry in entries {
                let target = NivoCredentialRestoreReceipt.Target(kind: .environment, owner: entry.owner)
                let sync = try read(target, synchronizable: true)
                let legacy = try read(target, synchronizable: false)
                guard sync == nil, legacy == nil else { continue }
                try install(entry.value, target: target, version: nil, updatesExisting: false)
            }
        }
    }

    /// 本机手动保存也不先删除旧值；时间回拨时仍推进版本，供后续同步比较。
    static func saveLocalProvider(_ value: String, instanceID: String) throws {
        let target = NivoCredentialRestoreReceipt.Target(kind: .providerAPIKey, owner: instanceID)
        try NivoCredentialRestoreReceipt(identifier: UUID(), targets: [target]).validate()
        let data = Data(value.utf8)
        guard data.count <= 1_048_576 else { throw NivoCredentialRestoreError.invalidValue }
        try lock.withLock {
            let local = try read(target, synchronizable: false)
            if local == nil { _ = try read(target, synchronizable: true) }
            let previous = ProviderKeychainHelper.apiKeySavedAt(instanceId: instanceID).timeIntervalSince1970
            let seconds = max(Date().timeIntervalSince1970, max(previous + 0.001, previous.nextUp))
            guard seconds.isFinite else { throw NivoCredentialRestoreError.invalidValue }
            let version = Date(timeIntervalSince1970: seconds)
            try install(data, target: target, version: version, updatesExisting: local != nil)
            ProviderKeychainHelper.stampAPIKeySavedAt(version, instanceId: instanceID)
            ProviderKeychainHelper.nmDeviceKeyChanged(instanceId: instanceID)
        }
    }

    /// 迁移读取严格区分系统故障和缺少，不能把受限条目当作可覆盖的空槽。
    static func providerValue(instanceID: String) throws -> Data? {
        try lock.withLock {
            let target = NivoCredentialRestoreReceipt.Target(kind: .providerAPIKey, owner: instanceID)
            if let local = try read(target, synchronizable: false) { return local.value }
            return try read(target, synchronizable: true)?.value
        }
    }

    /// 网络探测后仅替换开始时看到的密钥，等待期间的新编辑不能被迟到响应覆盖。
    static func replaceLocalProvider(_ value: String, instanceID: String, expected: ProviderSnapshot?) throws {
        try lock.withLock {
            guard try providerSnapshot(instanceID: instanceID) == expected else {
                throw NivoOAuthPersistenceError.conflictingCredential
            }
            try saveLocalProvider(value, instanceID: instanceID)
        }
    }

    /// 相同密钥再次保存也属于新版本，不能被较早开始的探测当作未修改。
    static func providerSnapshot(instanceID: String) throws -> ProviderSnapshot? {
        try lock.withLock {
            let target = NivoCredentialRestoreReceipt.Target(kind: .providerAPIKey, owner: instanceID)
            let local = try read(target, synchronizable: false)
            guard let saved = try local ?? read(target, synchronizable: true) else { return nil }
            return ProviderSnapshot(value: saved.value,
                version: saved.version ?? ProviderKeychainHelper.apiKeySavedAt(instanceId: instanceID))
        }
    }

    /// 返回与密钥同时写入的版本；旧条目没有此字段，仍由宿主使用旧时间记录。
    static func savedProviderDate(instanceID: String) throws -> Date? {
        try lock.withLock {
            let target = NivoCredentialRestoreReceipt.Target(kind: .providerAPIKey, owner: instanceID)
            if let local = try read(target, synchronizable: false) { return local.version }
            return try read(target, synchronizable: true)?.version
        }
    }

    /// 单变量读取必须区分缺少和锁屏/权限错误，避免上传空值掩盖读取故障。
    static func environmentValue(key: String) throws -> String? {
        try environmentSnapshot(key: key)?.value
    }

    /// 发送值时同时读取其原子版本，文件提交中断不能给新秘密附上旧时间。
    static func environmentSnapshot(key: String) throws -> (value: String, version: Date?)? {
        try lock.withLock {
            let target = NivoCredentialRestoreReceipt.Target(kind: .environment, owner: key)
            let local = try read(target, synchronizable: false)
            guard let saved = try local ?? read(target, synchronizable: true) else { return nil }
            guard let value = String(data: saved.value, encoding: .utf8) else { throw NivoCredentialRestoreError.invalidValue }
            return (value, saved.version)
        }
    }

    /// 值和版本共同写入；Keychain已收到更新版本时保留它，等待对应元数据到达。
    static func saveEnvironment(_ value: String, key: String, version: Date, isLocal: Bool = false) throws -> Date {
        let target = NivoCredentialRestoreReceipt.Target(kind: .environment, owner: key)
        try NivoCredentialRestoreReceipt(identifier: UUID(), targets: [target]).validate()
        let data = Data(value.utf8)
        guard data.count <= 1_048_576, version.timeIntervalSince1970.isFinite else { throw NivoCredentialRestoreError.invalidValue }
        return try lock.withLock {
            let sync = try read(target, synchronizable: true)
            let legacy = try read(target, synchronizable: false)
            let seenVersion = (legacy ?? sync)?.version ?? .distantPast
            if !isLocal, seenVersion > version { return seenVersion }
            if !isLocal, let saved = legacy ?? sync, saved.version == version {
                guard saved.value == data else { throw NivoCredentialRestoreError.verificationFailed }
                return version
            }
            let next = isLocal ? try NivoEnvVarState.nextVersion(after: seenVersion, now: version) : version
            try install(data, target: target, version: next, updatesExisting: legacy != nil)
            return next
        }
    }

    private static func importProvider(_ entry: NivoCredentialSync.Entry) throws {
        let target = NivoCredentialRestoreReceipt.Target(kind: .providerAPIKey, owner: entry.owner)
        let sync = try read(target, synchronizable: true)
        let legacy = try read(target, synchronizable: false)
        let local = legacy ?? sync
        let localDate = local?.version ?? ProviderKeychainHelper.apiKeySavedAt(instanceId: entry.owner)
        let decision = NivoCredentialSync.decision(local: local?.value, localUpdatedAt: localDate, remote: entry, now: Date())
        guard case .write(let version) = decision else { return }
        try install(entry.value, target: target, version: version, updatesExisting: legacy != nil)
        ProviderKeychainHelper.stampAPIKeySavedAt(version, instanceId: entry.owner)
        ProviderKeychainHelper.nmDeviceKeyChanged(instanceId: entry.owner)
    }

    private static func read(_ target: NivoCredentialRestoreReceipt.Target, synchronizable: Bool) throws -> Snapshot? {
        var query = match(target, synchronizable: synchronizable)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NivoCredentialRestoreError.keychain(operation: "sync_read", status: status) }
        guard let attributes = result as? [String: Any], let data = attributes[kSecValueData as String] as? Data else {
            throw NivoCredentialRestoreError.verificationFailed
        }
        var date: Date?
        if let encoded = attributes[kSecAttrGeneric as String] as? Data, !encoded.isEmpty {
            guard let version = try? JSONDecoder().decode(Version.self, from: encoded),
                  version.schema == 1, version.seconds.isFinite else { throw NivoCredentialRestoreError.invalidValue }
            date = Date(timeIntervalSince1970: version.seconds)
        }
        return Snapshot(value: data, version: date)
    }

    private static func install(_ value: Data, target: NivoCredentialRestoreReceipt.Target,
                                version: Date?, updatesExisting: Bool) throws {
        let query = match(target, synchronizable: false)
        var attributes: [String: Any] = [kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, kSecAttrComment as String: ""]
        if let version {
            attributes[kSecAttrGeneric as String] = try JSONEncoder().encode(Version(schema: 1, seconds: version.timeIntervalSince1970))
        }
        let status: OSStatus
        if updatesExisting { status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
        else { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        // 新条目并发出现时保留它并重试，不能未读取其版本就直接覆盖。
        guard status == errSecSuccess else { throw NivoCredentialRestoreError.keychain(operation: "sync_write", status: status) }
        let written = try read(target, synchronizable: false)
        guard written?.value == value, written?.version == version else { throw NivoCredentialRestoreError.verificationFailed }
    }

    private static func match(_ target: NivoCredentialRestoreReceipt.Target, synchronizable: Bool) -> [String: Any] {
        let isProvider = target.kind == .providerAPIKey
        let service = isProvider ? "io.github.nanomuse.app.provider." + target.owner : "io.github.nanomuse.app.envvar"
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: isProvider ? "api-key" : target.owner,
            kSecAttrSynchronizable as String: synchronizable]
    }
}

/// 入站凭证写入与账户迁移、备份恢复使用同一冻结边界。
@MainActor
enum NivoCloudCredentialAccess {
    /// 调用点在首次异步交接前捕获代次；同步写入期间不再让出主线程。
    static func perform(expectedGeneration: UInt64, _ body: () throws -> Void) throws {
        guard NanoMuseAccountData.shared.generation == expectedGeneration else { throw NivoLifeError.accountChanged }
        try EnvVarStore.shared.nmRetryRecoveryIfNeeded()
        guard let token = NivoCloudExportAccess.begin() else { throw NivoPersonalBackupError.busy }
        defer { NivoCloudExportAccess.end(token) }
        try Task.checkCancellation()
        try body()
    }
}
