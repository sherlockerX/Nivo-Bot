import Foundation

/// 凭证回滚只保存目标标识和本次插入标记，任何密钥正文都不写入恢复日志。
struct NivoCredentialRestoreReceipt: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case providerAPIKey, providerOAuthToken, providerManualToken, providerEmail, providerProject, providerBaseURL
        case environment, mcpTokens, mcpClientSecret

        var isProvider: Bool {
            switch self {
            case .providerAPIKey, .providerOAuthToken, .providerManualToken, .providerEmail, .providerProject, .providerBaseURL: return true
            default: return false
            }
        }
    }

    struct Target: Codable, Hashable, Sendable {
        var kind: Kind
        var owner: String
    }

    var identifier: UUID
    var targets: [Target]

    /// 固定枚举决定Keychain服务名，日志不能指定任意服务或重复删除目标。
    func validate() throws {
        guard targets.count <= 4_096, Set(targets).count == targets.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for target in targets {
            guard !target.owner.isEmpty, target.owner.utf8.count <= 512, !target.owner.contains("\0") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if target.kind == .environment {
                guard let first = target.owner.first, first.isASCII, first.isLetter,
                      target.owner.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
    }

    var keychainComment: String { "nivo-restore-" + identifier.uuidString }
}
