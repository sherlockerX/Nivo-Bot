import Foundation

/// 只重放本次迁移已经确认的快照；失败保留原基线，成功发布之后才结束意图。
@MainActor
final class NivoLocalModeConfigurationTransaction<Configuration: Equatable> {
    private struct Pending {
        let baseline: Configuration
        let target: Configuration
    }

    private var pending: Pending?
    var hasPendingConfiguration: Bool { pending != nil }

    /// 新意图必须先通过严格基线检查；已有意图重放也必须再次验证数据库可读。
    func run(current: Configuration, candidate: Configuration?,
             waitForBaseline: @MainActor (Bool) async throws -> Void,
             persist: @MainActor (Configuration, Configuration) async throws -> Configuration,
             publish: @MainActor (Configuration) throws -> Void) async throws {
        guard let intent = pending ?? candidate.map({ Pending(baseline: current, target: $0) }) else { return }
        guard current == intent.baseline else { throw CocoaError(.fileWriteUnknown) }
        try await waitForBaseline(pending != nil)
        pending = intent
        let persisted = try await persist(intent.baseline, intent.target)
        try publish(persisted)
        pending = nil
    }
}

#if canImport(UIKit)
/// 旧入口收到调用时明确说明能力已移除，避免显示虚假的登录或同步成功。
enum NivoLocalModeError: LocalizedError {
    case cloudRemoved

    var errorDescription: String? { AppLocalized("nivo.local.cloud_removed") }
}

/// 将旧账号归属固定为本地档案，提供商API凭证仍由原来的本机存储管理。
@MainActor
enum NivoLocalModeHost {
    private static let identityFile = "local-profile.json"
    private static var cachedIdentity: NivoLocalIdentity?

    private static var identityURL: URL {
        NanoMuseDirs.root.appendingPathComponent(identityFile)
    }

    /// 保持现有记录使用的归属键，不再向服务器验证或刷新它。
    static var owner: String {
        if let cachedIdentity { return cachedIdentity.owner }
        if let identity = try? NivoLocalIdentity.read(from: identityURL) {
            cachedIdentity = identity
            return identity.owner
        }
        return legacyOwner
    }

    private static var legacyOwner: String {
        let cached = NanoMuseCloud.account
        if let identifier = cached?.id, !identifier.isEmpty { return identifier }
        if let hint = cached?.hint, !hint.isEmpty { return hint }
        let key = NanoMuseCloud.transitionInstanceID.flatMap { ProviderKeychainHelper.loadAPIKey(instanceId: $0) }
        return NanoMuseSync.accountKey(id: nil, hint: nil, apiKey: key)
    }

    /// 启动已持有数据恢复锁，先保存归属，再禁用内置服务；保留历史模型与分组绑定。
    static func prepareDuringStartup() async throws {
        let store = ProviderConfigStore.shared
        try await store.nmReplayPendingLocalModeRetirement()
        try await store.nmWaitForMigrationBaseline(retryingFailedWrites: false)
        let saved = try NivoLocalIdentity.read(from: identityURL)
        let retired = (saved?.retiredProviderIDs ?? []) + [NanoMuseCloud.transitionInstanceID].compactMap { $0 }
        let candidates = store.instances.filter {
            NivoLocalIdentity.isRetiredProvider(id: $0.id, baseURL: $0.customBaseURL, retiredIDs: retired)
        }
        let identity = try NivoLocalIdentity.prepare(at: identityURL, legacyOwner: legacyOwner,
            retiring: retired + candidates.map(\.id))
        cachedIdentity = identity
        NivoRetiredProviderPolicy.shared.install(identity.retiredProviderIDs)
        try await store.nmCommitLocalModeRetirement(retiring: identity.retiredProviderIDs)
        // 凭证事务完成后才清理旧身份提示；学习档案、聊天和用户自有API配置均不迁移。
        NanoMuseCloud.clear()
        let defaults = UserDefaults.standard
        for key in ["nanomuse.cloud.base", "nanomuse.cloud.sign_in_ended", "nanomuse.relay.region"] {
            defaults.removeObject(forKey: key)
        }
        for key in ["nanomuse.sync.enabled", "nanomuse.sync.sidechats", "nanomuse.hub.enabled", "nanomuse.hub.remote_control"] {
            defaults.set(false, forKey: key)
        }
        guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
    }
}
#endif
