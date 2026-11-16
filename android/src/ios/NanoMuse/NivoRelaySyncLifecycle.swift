import Foundation

/// 网络请求绑定发起时的账户、凭证和配置代次，不把旧回执应用到新身份。
struct NivoRelaySyncLifecycle {
    /// 凭证只参与进程内比较，不编码、不记录到文件或日志。
    struct Identity: Equatable, Sendable {
        let account: String
        let credential: String
        let endpoint: String
        let accountGeneration: UInt64
    }

    /// 延时任务先记录意图；等待完成后仍须核对当前身份和同步代次。
    struct Intent: Equatable, Sendable {
        let generation: UInt64
        let identity: Identity
    }

    /// 同一时间只允许一个读写操作，避免下载、上传和延后队列互相覆盖。
    struct Lease: Equatable, Sendable {
        let id: UUID
        let intent: Intent
    }

    private(set) var generation: UInt64 = 0
    private(set) var lease: Lease?
    var isBusy: Bool { lease != nil }

    /// 改变同步范围或账户后作废旧结果，保留占位直到实际请求结束。
    mutating func invalidate() { generation &+= 1 }

    /// 只捕获身份，不占用网络或数据库。
    func intent(for identity: Identity) -> Intent { Intent(generation: generation, identity: identity) }

    /// 开始实际操作；忙碌时由宿主合并重试请求，不并发改同一张映射表。
    mutating func begin(_ identity: Identity) -> Lease? {
        guard lease == nil, !identity.account.isEmpty, !identity.credential.isEmpty else { return nil }
        let started = Lease(id: UUID(), intent: intent(for: identity))
        lease = started
        return started
    }

    /// 检查尚未开始的延时意图，涵盖同账户退出后重新登录。
    func accepts(_ intent: Intent, identity: Identity) -> Bool {
        intent.generation == generation && intent.identity == identity
    }

    /// 每次异步返回后检查，不能仅依靠请求开始时的开关。
    func accepts(_ lease: Lease, identity: Identity) -> Bool {
        self.lease == lease && accepts(lease.intent, identity: identity)
    }

    /// 只有自己的完成回调能够释放占位，重复旧回调不能放开新任务。
    @discardableResult
    mutating func end(_ lease: Lease) -> Bool {
        guard self.lease == lease else { return false }
        self.lease = nil
        return true
    }
}
