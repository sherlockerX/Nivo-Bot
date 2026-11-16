import Foundation

/// 提供商完整快照的有序写盘队列；失败向等待者传播，后续完整快照可以显式重试。
@MainActor
final class NivoProviderWriteQueue {
    /// 镜像可以重试自身的错误，但不能把尚未成功的完整配置保存变成成功。
    private struct Outcome: Sendable {
        let result: Result<Void, Error>
        let hasConfigurationFailure: Bool
    }

    private var tail: Task<Outcome, Never>?
    private var revision: UInt64 = 0
    /// 最近一次排空后观察到的结果，调用方须先等待队列再决定是否需要重试完整快照。
    private(set) var hasFailedWrite = false

    /// 排队时先占据尾部，JSON与SQLite写入必须放进同一个operation，避免彼此超车。
    @discardableResult
    func enqueue(_ operation: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
        enqueue { _ in try await operation() }
    }

    /// 告知下一份完整快照前次是否失败，成功重试必须补登此前未提交的同步变化。
    @discardableResult
    func enqueue(_ operation: @escaping @Sendable (Bool) async throws -> Void) -> Task<Void, Error> {
        append(isMirror: false, operation: operation)
    }

    /// 数据库已经提交时只更新JSON镜像；此前的完整写入失败必须继续向调用方传播。
    @discardableResult
    func enqueueMirror(_ operation: @escaping @Sendable () async throws -> Void) -> Task<Void, Error> {
        append(isMirror: true) { _ in try await operation() }
    }

    private func append(isMirror: Bool, operation: @escaping @Sendable (Bool) async throws -> Void) -> Task<Void, Error> {
        let previous = tail
        revision &+= 1
        let task = Task.detached(priority: .utility) {
            let outcome = await previous?.value
            if isMirror, let outcome, outcome.hasConfigurationFailure { return outcome }
            let isRetry: Bool
            if let outcome, case .failure = outcome.result { isRetry = true }
            else { isRetry = false }
            do {
                try await operation(isRetry)
                return Outcome(result: .success(()), hasConfigurationFailure: false)
            } catch {
                return Outcome(result: .failure(error), hasConfigurationFailure: !isMirror)
            }
        }
        tail = task
        return Task { try await task.value.result.get() }
    }

    /// 等待期间又排入写入时继续等新尾部，不能把旧尾部结束误当成队列已经排空。
    func waitUntilIdle(allowingMirrorFailure: Bool = false) async throws {
        while let pending = tail {
            let observed = revision
            let outcome = await pending.value
            guard observed == revision else { continue }
            if case .failure = outcome.result { hasFailedWrite = true }
            else { hasFailedWrite = false }
            // 判断最终实际结果，不能在等待之前按那时的尾部类型决定吞掉什么错误。
            if allowingMirrorFailure, !outcome.hasConfigurationFailure { return }
            try outcome.result.get()
            return
        }
    }

    /// 只能在排空且已从快照恢复完成后调用，避免历史失败永久阻断下一次正常保存。
    func didRestoreSnapshot() {
        revision &+= 1
        tail = nil
        hasFailedWrite = false
    }
}
