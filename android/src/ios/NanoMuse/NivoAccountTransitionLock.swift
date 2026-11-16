import Foundation

/// 账户切换按进入顺序独占执行，异步网络等待不会让另一次登录或退出插入文件迁移中间。
@MainActor
final class NivoAccountTransitionLock {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 账户清理必须走完边界，因此等待不因调用者取消而丢弃；持有者始终用defer释放。
    func acquire() async {
        if !isHeld { isHeld = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 将独占权直接交给下一位，避免释放与恢复之间的新请求插队。
    func release() {
        guard isHeld else { return }
        if waiters.isEmpty { isHeld = false }
        else { waiters.removeFirst().resume() }
    }
}
