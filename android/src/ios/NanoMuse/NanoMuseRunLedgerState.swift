import Foundation

/// 运行提示按账户及数据代次隔离，未开放个人仓库时仍可记录普通聊天。
struct NanoMuseRunLedgerContext: Equatable, Sendable {
    let ownerKey: String
    let generation: UInt64?
}

/// 进程内运行记录，不依赖聊天页面是否仍挂载。
struct NanoMuseRunLedgerState: Equatable, Sendable {
    enum Outcome: Sendable { case completed, failed, cancelled }
    private(set) var context: NanoMuseRunLedgerContext?
    private(set) var runs: [UUID: String] = [:]
    private(set) var outcomes: [String: Bool] = [:]
    private var viewers: [UUID: String] = [:]
    private var order: [String] = []
    private static let MAX_OUTCOMES = 256

    var running: Set<String> { Set(runs.values) }

    /// 相同账户恢复备份也清空提示，不把旧运行绑定给新档案。
    mutating func bind(_ next: NanoMuseRunLedgerContext) {
        guard context != next else { return }
        self = NanoMuseRunLedgerState()
        context = next
    }

    /// 重复开始通知保持现有运行，实际新运行会清掉上一次未读结果。
    mutating func begin(_ token: UUID, session: String) {
        guard runs[token] == nil else { return }
        runs[token] = session
        forget(session)
    }

    /// 草稿取得持久化ID后迁移同一次运行及查看状态。
    mutating func rebind(_ token: UUID, session: String) {
        guard let previous = runs[token], previous != session else { return }
        runs[token] = session
        for viewer in viewers.keys where viewers[viewer] == previous { viewers[viewer] = session }
        forget(previous)
        forget(session)
    }

    /// 仅为实际运行过且无人正在查看的会话留下结果；手动停止不显示完成。
    mutating func finish(_ token: UUID, outcome: Outcome) {
        guard let session = runs.removeValue(forKey: token) else { return }
        guard !runs.values.contains(session), !viewers.values.contains(session) else { return }
        forget(session)
        guard outcome != .cancelled else { return }
        outcomes[session] = outcome == .completed
        order.append(session)
        if order.count > Self.MAX_OUTCOMES { outcomes.removeValue(forKey: order.removeFirst()) }
    }

    /// 每个页面使用独立令牌，旧页面退出不能清除新页面的查看状态。
    mutating func setViewing(_ token: UUID, session: String?) {
        viewers[token] = session
        if let session { forget(session) }
    }

    private mutating func forget(_ session: String) {
        outcomes.removeValue(forKey: session)
        order.removeAll { $0 == session }
    }
}
