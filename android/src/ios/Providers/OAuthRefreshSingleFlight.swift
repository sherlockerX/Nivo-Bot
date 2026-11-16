import Foundation

/// [T-oauth-refresh-race] Instance-level single-flight coordinator for OAuth
/// token refreshes, shared by every provider manager. At most one in-flight
/// refresh `Task` per provider instance: concurrent callers await/reuse the same
/// task instead of each firing their own network refresh with the same (about-
/// to-be-rotated) refresh token.
///
/// `@MainActor` so the check-and-insert of `inFlight[instanceId]` is atomic
/// (there is no `await` between the lookup and the store), matching how each
/// provider manager is already isolated. Generic over the provider's token type;
/// combine with `OAuthRefreshCoordinator.resolveAfterRefreshFailure` for the
/// compare-before-delete backstop when the shared refresh fails.
@MainActor
final class OAuthRefreshSingleFlight<Token: Sendable> {
    // nanoMuse: 登录代次参与键，旧刷新结束不能覆盖或移除新登录的刷新。
    private struct Key: Hashable {
        let instanceId: String
        let generation: UUID?
    }
    private struct Flight {
        let identifier: UUID
        let task: Task<Token, Error>
    }
    private var inFlight: [Key: Flight] = [:]

    init() {}

    /// Whether a refresh is currently running for `instanceId` (test/introspection).
    func hasInFlight(_ instanceId: String) -> Bool { inFlight.keys.contains { $0.instanceId == instanceId } }

    // nanoMuse: 作废任务后保留身份核对，网络即使忽略取消也不能报告刷新成功。
    /// 退出时取消该实例全部在途刷新，其他实例保持独立。
    func invalidate(instanceId: String) {
        let keys = inFlight.keys.filter { $0.instanceId == instanceId }
        for key in keys { inFlight.removeValue(forKey: key)?.task.cancel() }
    }

    /// Run `perform` under single-flight for `instanceId`.
    ///
    /// - If a refresh is already running for this instance, await it and return
    ///   its result (join — no second network call). If that shared task throws,
    ///   the error is rethrown so the caller can apply its compare-before-delete
    ///   resolution against the now-current persisted state.
    /// - Otherwise start a new task, register it, run it, and clear the slot when
    ///   it settles (success or failure).
    ///
    /// `perform` is responsible for the actual token-endpoint round trip AND for
    /// persisting the rotated token on success (so a joiner reading persisted
    /// state after success sees the new token).
    func run(instanceId: String, generation: UUID? = nil,
             perform: @escaping @MainActor () async throws -> Token) async throws -> Token {
        // nanoMuse: 调用者取消只停止自己的结果，不能取消其他调用者仍在使用的共享刷新。
        try Task.checkCancellation()
        let key = Key(instanceId: instanceId, generation: generation)
        if let existing = inFlight[key] {
            let result = try await existing.task.value
            try Task.checkCancellation()
            return result
        }
        let identifier = UUID()
        let task = Task<Token, Error> {
            try Task.checkCancellation()
            let result = try await perform()
            try Task.checkCancellation()
            return result
        }
        inFlight[key] = Flight(identifier: identifier, task: task)
        defer {
            if inFlight[key]?.identifier == identifier { inFlight[key] = nil }
        }
        let result = try await task.value
        try Task.checkCancellation()
        return result
    }
}
