import Foundation
import Security

/// 恢复失败保留系统状态码；不会把读取受限误认为凭证不存在。
enum NivoCredentialRestoreError: Error {
    case keychain(operation: String, status: OSStatus)
    case invalidValue
    case verificationFailed
}

/// 仅允许插入缺少的凭证；已有或并发出现的条目保持原值，回滚只删除本次标记的插入。
enum NivoCredentialRestore {
    typealias Target = NivoCredentialRestoreReceipt.Target

    struct Item: Sendable {
        let target: Target
        let data: Data
    }

    struct Plan: Sendable {
        let receipt: NivoCredentialRestoreReceipt
        let items: [Item]
        let kept: [Target]
    }

    struct Result: Sendable {
        var inserted: [Target] = []
        var kept: [Target] = []
    }

    /// 快照前读取所有目标，权限/解锁错误直接中止准备；返回的日志不包含data。
    static func prepare(_ items: [Item]) throws -> Plan {
        let receipt = NivoCredentialRestoreReceipt(identifier: UUID(), targets: items.map(\.target))
        try receipt.validate()
        var pending: [Item] = []
        var kept: [Target] = []
        for item in items {
            guard item.data.count <= 1_048_576 else { throw NivoCredentialRestoreError.invalidValue }
            if try existing(item.target) { kept.append(item.target) }
            else { pending.append(item) }
        }
        return Plan(receipt: NivoCredentialRestoreReceipt(identifier: receipt.identifier, targets: pending.map(\.target)),
                    items: pending, kept: kept)
    }

    /// 必须在receipt已经进入持久恢复日志后调用，写入后按同一条目回读确认。
    static func apply(_ plan: Plan) throws -> Result {
        try plan.receipt.validate()
        guard plan.receipt.targets == plan.items.map(\.target) else { throw NivoCredentialRestoreError.invalidValue }
        var result = Result(kept: plan.kept)
        for item in plan.items {
            if try insert(item, comment: plan.receipt.keychainComment) { result.inserted.append(item.target) }
            else { result.kept.append(item.target) }
        }
        return result
    }

    /// 崩溃重启时只需要日志里的标识；用户之后更新的条目没有本次标记，不会被删除。
    static func rollback(_ receipt: NivoCredentialRestoreReceipt) throws {
        try receipt.validate()
        for target in receipt.targets {
            var query = match(target, synchronizable: isSynchronizable(target))
            query[kSecAttrComment as String] = receipt.keychainComment
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NivoCredentialRestoreError.keychain(operation: "rollback", status: status)
            }
            invalidate(target)
        }
    }

    /// 还带恢复标记的API密钥采用条目创建时间参与同步冲突判断，不另写难以回滚的时间戳。
    static func restoredAPIKeyDate(instanceID: String) -> Date? {
        let target = Target(kind: .providerAPIKey, owner: instanceID)
        var query = match(target, synchronizable: true)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              let comment = attributes[kSecAttrComment as String] as? String,
              comment.hasPrefix("nivo-restore-"),
              UUID(uuidString: String(comment.dropFirst("nivo-restore-".count))) != nil else { return nil }
        return attributes[kSecAttrCreationDate as String] as? Date
    }

    private static func insert(_ item: Item, comment: String) throws -> Bool {
        if try existing(item.target) { return false }
        let isSync = isSynchronizable(item.target)
        var query = match(item.target, synchronizable: isSync)
        query[kSecValueData as String] = item.data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecAttrComment as String] = comment
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard try existing(item.target) else { throw NivoCredentialRestoreError.verificationFailed }
            return false
        }
        guard status == errSecSuccess else { throw NivoCredentialRestoreError.keychain(operation: "insert", status: status) }
        let written = try read(item.target, synchronizable: isSync)
        guard written?.data == item.data, written?.comment == comment else { throw NivoCredentialRestoreError.verificationFailed }
        invalidate(item.target)
        return true
    }

    private static func existing(_ target: Target) throws -> Bool {
        // 同步与旧本机条目均检查，读取失败不能触发删除重建。
        let sync = try read(target, synchronizable: true)
        let local = try read(target, synchronizable: false)
        return sync != nil || local != nil
    }

    private static func read(_ target: Target, synchronizable: Bool) throws -> (data: Data, comment: String?)? {
        var query = match(target, synchronizable: synchronizable)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NivoCredentialRestoreError.keychain(operation: "read", status: status) }
        guard let attributes = value as? [String: Any], let data = attributes[kSecValueData as String] as? Data else {
            throw NivoCredentialRestoreError.verificationFailed
        }
        return (data, attributes[kSecAttrComment as String] as? String)
    }

    /// 服务和账户映射沿用现有三个凭证宿主，MCP令牌始终留在本机。
    private static func match(_ target: Target, synchronizable: Bool) -> [String: Any] {
        let service: String
        let account: String
        switch target.kind {
        case .environment:
            service = "io.github.nanomuse.app.envvar"; account = target.owner
        case .mcpTokens, .mcpClientSecret:
            service = "io.github.nanomuse.app.mcp-oauth"
            account = target.owner + (target.kind == .mcpTokens ? "#tokens" : "#secret")
        default:
            service = "io.github.nanomuse.app.provider." + target.owner
            account = providerAccount(target.kind)
        }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrSynchronizable as String: synchronizable]
    }

    private static func providerAccount(_ kind: NivoCredentialRestoreReceipt.Kind) -> String {
        switch kind {
        case .providerAPIKey: return "api-key"
        case .providerOAuthToken: return "oauth-token"
        case .providerManualToken: return "manual-oauth-token"
        case .providerEmail: return "oauth-email"
        case .providerProject: return "oauth-gcp-project"
        case .providerBaseURL: return "oauth-base-url"
        default: return ""
        }
    }

    private static func isSynchronizable(_ target: Target) -> Bool {
        target.kind != .mcpTokens && target.kind != .mcpClientSecret
    }

    private static func invalidate(_ target: Target) {
        if target.kind.isProvider { ProviderKeychainHelper.nmDeviceKeyChanged(instanceId: target.owner) }
    }
}
