import Foundation

/// 保留旧资料的本地归属，不保存账号密码，也不依赖服务器确认身份。
struct NivoLocalIdentity: Codable, Equatable, Sendable {
    let version: Int
    let owner: String
    let retiredProviderIDs: [String]

    /// 严格读取现有档案，损坏或未来格式必须进入恢复流程，不能静默创建空档案。
    static func read(from url: URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let identity = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard identity.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return identity
    }

    /// 在移除旧凭证之前持久化归属，重复执行只补充退役实例，不更换档案。
    static func prepare(at url: URL, legacyOwner: String, retiring identifiers: [String]) throws -> Self {
        let existing = try read(from: url)
        let retired = Set((existing?.retiredProviderIDs ?? []) + identifiers).filter { !$0.isEmpty }.sorted()
        let identity = Self(version: 1, owner: existing?.owner ?? legacyOwner, retiredProviderIDs: retired)
        if existing == identity { return identity }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(identity).write(to: url, options: .atomic)
        return identity
    }

    /// 历史中继实例按标识识别，旧默认服务按精确主机识别，保留用户自己的API端点。
    static func isRetiredProvider(id: String, baseURL: String?, retiredIDs: [String]) -> Bool {
        if retiredIDs.contains(id) { return true }
        guard let baseURL, var host = URL(string: baseURL)?.host?.lowercased() else { return false }
        // DNS绝对域名的末尾根点不改变服务归属，不能用它绕过原服务停用规则。
        if host.hasSuffix(".") { host.removeLast() }
        return host == "cloud.nanomuse.cn"
    }
}

/// 模型解析可能在后台线程发生，退役名单用锁共享，不在每次解析时读取磁盘。
final class NivoRetiredProviderPolicy: @unchecked Sendable {
    static let shared = NivoRetiredProviderPolicy()
    private let lock = NSLock()
    private var retiredIDs: [String] = []

    /// 仅在本地身份已可靠保存后发布名单。
    func install(_ identifiers: [String]) {
        lock.withLock { retiredIDs = identifiers }
    }

    /// 拒绝原服务及旧实例的重导入，个人API和局域网模型不受影响。
    func blocks(id: String, baseURL: String?) -> Bool {
        let identifiers = lock.withLock { retiredIDs }
        return NivoLocalIdentity.isRetiredProvider(id: id, baseURL: baseURL, retiredIDs: identifiers)
    }
}
