import Foundation

/// 独立凭证删除和提供商删除共用核对规则，秘密只保存在Keychain暂存。
enum NivoCredentialDeletion {
    static let accounts = ["api-key", "oauth-token", "manual-oauth-token", "oauth-email", "oauth-gcp-project", "oauth-base-url"]

    struct Secret: Codable, Equatable, Sendable {
        let value: Data
        let version: Data?
        var modifiedAt: Date? = nil
        var marker: String? = nil
    }

    enum Action: Equatable { case absent, remove, preserve }
    enum Settlement: String, Codable { case removed, preserved }

    /// 仅携带固定账户名称的终结回执，不记录凭证、摘要或用户身份。
    struct Outcome: Codable, Equatable, Sendable {
        var preservedAccounts: [String] = []
        var hasPreservedCredentials: Bool { !preservedAccounts.isEmpty }
    }

    /// 已失去所有权是安全保留结果；真正的读取或写入错误由系统适配器继续抛出。
    static func action(current: Secret?, expected: Secret?, marker: String) -> Action {
        guard let current else { return .absent }
        guard let expected else { return .preserve }
        if current == expected { return .remove }
        if current.marker == marker, current.value == expected.value, current.version == expected.version {
            return .remove
        }
        return .preserve
    }
}
