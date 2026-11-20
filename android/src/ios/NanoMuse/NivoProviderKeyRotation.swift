import Foundation

/// API密钥轮换的恢复规则；秘密结构仅供Keychain暂存，文件日志只能保存Receipt。
enum NivoProviderKeyRotation {
    struct Receipt: Codable, Equatable, Sendable {
        let identifier: UUID
        let instanceID: String

        /// 回执不能引导适配器访问任意服务，实例身份保持现有凭证上限。
        func validate() throws {
            guard !instanceID.isEmpty, instanceID.utf8.count <= 512, !instanceID.contains("\0") else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }

        var comment: String { "nivo-key-rotation-" + identifier.uuidString }
    }

    struct Version: Codable, Equatable, Sendable {
        let schema: Int
        let seconds: Double
    }

    struct Secret: Codable, Equatable, Sendable {
        let value: Data
        var version: Data?
        var comment: String
        let accessibility: String?

        /// 旧条目沿用观察到的兼容时间，带版本条目必须从实际捕获的属性解码。
        func savedVersion(fallback: Date) throws -> Date {
            guard let version, !version.isEmpty else { return fallback }
            guard version.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
            let decoded = try JSONDecoder().decode(Version.self, from: version)
            guard decoded.schema == 1, decoded.seconds.isFinite else { throw CocoaError(.fileReadCorruptFile) }
            return Date(timeIntervalSince1970: decoded.seconds)
        }
    }

    enum Rollback: Equatable, Sendable { case preserve, remove, restore(Secret) }

    struct Stage: Codable, Equatable, Sendable {
        let receipt: Receipt
        var previousSync: Secret?
        var previousLocal: Secret?
        var replacement: Secret
        // 缺失表示旧版同步事务；新事务明确标记本机目标，避免重启时回滚错条目。
        var targetIsLocal: Bool? = nil

        /// 再次核对真正进入暂存的值与版本，不能让两次Keychain读取之间的新值成为可覆盖基线。
        func matchesPrevious(value: Data?, version: Date?, fallbackVersion: Date) throws -> Bool {
            let selected = targetIsLocal == true ? previousLocal ?? previousSync : previousSync ?? previousLocal
            guard let previous = selected else { return value == nil && version == nil }
            guard let value, let version else { return false }
            let savedVersion = try previous.savedVersion(fallback: fallbackVersion)
            return previous.value == value && savedVersion == version
        }

        /// 暂存必须完整、可读且唯一绑定本次写入，缺少版本或所有权时停止恢复。
        func validate() throws {
            try receipt.validate()
            guard replacement.comment == receipt.comment, !replacement.value.isEmpty,
                  let encoded = replacement.version else { throw CocoaError(.fileReadCorruptFile) }
            let version = try JSONDecoder().decode(Version.self, from: encoded)
            guard version.schema == 1, version.seconds.isFinite else { throw CocoaError(.fileReadCorruptFile) }
            for secret in [previousSync, previousLocal, replacement].compactMap({ $0 }) {
                guard secret.value.count <= 1_048_576, (secret.version?.count ?? 0) <= 4096,
                      secret.comment.utf8.count <= 4096 else { throw CocoaError(.fileReadCorruptFile) }
            }
        }

        /// 精确匹配写入值、版本和操作标记；任何后来变化都保留，包括已经删除。
        func rollback(current: Secret?) throws -> Rollback {
            try validate()
            guard let current, current.value == replacement.value,
                  current.version == replacement.version, current.comment == receipt.comment else { return .preserve }
            let previous = targetIsLocal == true ? previousLocal : previousSync
            return previous.map(Rollback.restore) ?? .remove
        }
    }
}
