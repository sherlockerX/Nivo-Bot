import CryptoKit
import Foundation

/// 恢复日志只保存身份缓存与密钥摘要，真实密钥始终留在本机Keychain。
struct NivoAccountSwitchIdentity: Codable, Sendable {
    let provider: Data?
    let account: Data?
    let instanceID: String?
    let previousInstanceID: String?
    let keyDigest: String?

    /// 登录目标在开始文件事务前完成编码，不能在替换数据之后才发现格式错误。
    @MainActor static func signingIn(provider: ProviderInstance, account: NanoMuseCloud.Account,
                                    key: String) throws -> Self {
        Self(provider: try JSONEncoder().encode(provider), account: try JSONEncoder().encode(account),
            instanceID: provider.id, previousInstanceID: NanoMuseCloud.instance?.id, keyDigest: digest(key))
    }

    /// 退出本机身份后再删除提供商；崩溃恢复仍知道需要清理哪个旧提供商。
    @MainActor static func signingOut() -> Self {
        Self(provider: nil, account: nil, instanceID: nil, previousInstanceID: NanoMuseCloud.instance?.id, keyDigest: nil)
    }

    /// 密钥可读性错误必须向上抛出，锁屏不能被误判成用户已经退出。
    @MainActor func isApplied() throws -> Bool {
        guard let instanceID, let keyDigest else { return NanoMuseCloud.transitionInstanceID == nil }
        return try NanoMuseAccountData.readRelayKey(instanceId: instanceID).map(Self.digest) == keyDigest
    }

    /// 恢复缓存前验证提供商ID和缓存编码，坏日志不能改变身份。
    @MainActor func validate(owner: String) throws {
        guard let provider, let account, let instanceID, let keyDigest else {
            guard self.provider == nil, self.account == nil, self.instanceID == nil, self.keyDigest == nil,
                  owner.isEmpty else { throw NivoLifeError.corruptStore }
            return
        }
        let decodedProvider = try JSONDecoder().decode(ProviderInstance.self, from: provider)
        let decodedAccount = try JSONDecoder().decode(NanoMuseCloud.Account.self, from: account)
        guard decodedProvider.id == instanceID, !owner.isEmpty, keyDigest.count == 64,
              keyDigest.allSatisfy(\.isHexDigit) else { throw NivoLifeError.corruptStore }
        if !decodedAccount.id.isEmpty {
            guard NanoMuseSync.accountKey(id: decodedAccount.id, hint: decodedAccount.hint, apiKey: nil) == owner else {
                throw NivoLifeError.corruptStore
            }
        }
    }

    nonisolated private static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
