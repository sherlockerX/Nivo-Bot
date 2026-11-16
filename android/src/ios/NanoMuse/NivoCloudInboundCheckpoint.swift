import Foundation

/// 云端回调先占位，实际落库完成后才允许保存同步游标；重启会从上次完整提交处重放。
final class NivoCloudInboundCheckpoint: @unchecked Sendable {
    static let shared = NivoCloudInboundCheckpoint()
    private let lock = NSLock()
    private var pending: Set<UUID> = []
    private var failed = false

    var isBusy: Bool { lock.withLock { !pending.isEmpty } }
    var hasFailure: Bool { lock.withLock { failed } }

    /// 在创建异步Task之前调用，封住回调交接时游标先落盘的窗口。
    func begin() -> UUID {
        lock.withLock {
            let identifier = UUID()
            pending.insert(identifier)
            return identifier
        }
    }

    /// 取消或落库失败后保留旧游标到下次启动，迟到的重复回调不能解除屏障。
    func finish(_ identifier: UUID, succeeded: Bool) {
        lock.withLock {
            guard pending.remove(identifier) != nil else { return }
            if !succeeded { failed = true }
        }
    }

    /// 检查与写盘共用锁，新的云端批次不能在两者之间插入。
    @discardableResult
    func persistIfSettled(_ write: () throws -> Void) rethrows -> Bool {
        try lock.withLock {
            guard pending.isEmpty, !failed else { return false }
            try write()
            return true
        }
    }
}
