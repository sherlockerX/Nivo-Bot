import Foundation

/// 凭证存储错误独立于网络错误，令牌刷新不能将其降级为旧令牌可用。
enum NivoOAuthPersistenceError: Error, Equatable {
    case invalidValue
    case verificationFailed
    case conflictingCredential
    case storage(operation: String, status: Int32)
}

/// OAuth写入与迁移共用的确认规则；系统存储操作由Keychain适配器提供。
enum NivoOAuthPersistence {
    /// 成功的旧刷新也不能覆盖等待期间被同步、删除或手动修改的凭证。
    static func requireUnchanged(accessToken: String, refreshToken: String?,
                                 currentAccessToken: String?, currentRefreshToken: String?) throws {
        guard currentAccessToken == accessToken, currentRefreshToken == refreshToken else {
            throw NivoOAuthPersistenceError.conflictingCredential
        }
    }

    /// 已有条目原位更新，缺少时新增；失败不删除旧值，成功必须读回确认。
    static func save(_ value: Data, read: () throws -> Data?,
                     update: (Data) throws -> Void, insert: (Data) throws -> Void) throws {
        guard !value.isEmpty, value.count <= 1_048_576 else { throw NivoOAuthPersistenceError.invalidValue }
        let current = try read()
        if current == value { return }
        if current != nil { try update(value) }
        else { try insert(value) }
        guard try read() == value else { throw NivoOAuthPersistenceError.verificationFailed }
    }

    /// 旧配置迁移只能填补空槽，已有不同凭证保持原样并保留旧来源。
    static func copyMissing(_ value: Data, read: () throws -> Data?, write: (Data) throws -> Void) throws {
        if let current = try read() {
            guard current == value else { throw NivoOAuthPersistenceError.conflictingCredential }
            return
        }
        try write(value)
        guard try read() == value else { throw NivoOAuthPersistenceError.verificationFailed }
    }
}
