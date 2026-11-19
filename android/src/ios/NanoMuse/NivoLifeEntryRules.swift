import Foundation

/// 页面跳转绑定来源账户代次，旧弹窗不能在切号或恢复备份后继续打开新账户的内容。
struct NivoLifeItemTarget: Equatable, Hashable, Sendable {
    var id: String
    var scope: NivoLifeScope
}

/// 串行消费页面当前目标；处理期间到达的新请求由同一轮继续读取，不依赖第二次界面事件。
@MainActor
final class NivoLifeRequestDrain {
    private(set) var isRunning = false

    /// 每轮最多尝试同一目标一次，暂未具备呈现条件的请求保留给下一次真实页面事件。
    func run(next: () -> NivoLifeItemTarget?, handle: (NivoLifeItemTarget) async -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        var attempted: Set<NivoLifeItemTarget> = []
        while !Task.isCancelled, let target = next(), attempted.insert(target).inserted {
            await handle(target)
        }
    }
}

/// 专注入口的结果只描述导航，不开始计时或改变任务状态。
enum NivoFocusDestination: Equatable, Sendable {
    case session(String), task(String), busy, unavailable, none
}

/// 通知、任务详情与恢复界面共用目标选择，明确目标失效时不跳到另一条记录。
enum NivoLifeEntryRules {
    /// 通知允许打开已经结束的记录；任务入口必须先确认所属账户及现有计时。
    static func focusDestination(
        requestedSessionID: String?, requestedTask: NivoLifeItemTarget?, storedID: String,
        sessions: [NivoFocusSession], tasks: [NivoTodoTask], scope: NivoLifeScope,
        shouldRestore: Bool
    ) -> NivoFocusDestination {
        let visible = sessions.filter { $0.ownerKey == scope.ownerKey && $0.deletedAt == nil }
        if let identifier = requestedSessionID {
            return visible.contains { $0.id == identifier } ? .session(identifier) : .unavailable
        }
        if let target = requestedTask {
            guard target.scope == scope,
                  let task = tasks.first(where: { $0.id == target.id && $0.ownerKey == scope.ownerKey && $0.deletedAt == nil }) else {
                return .unavailable
            }
            if let active = visible.first(where: \.isActive) {
                return active.taskId == target.id ? .session(active.id) : .busy
            }
            return task.status == .done ? .unavailable : .task(target.id)
        }
        guard shouldRestore else { return .none }
        if !storedID.isEmpty {
            return visible.contains { $0.id == storedID } ? .session(storedID) : .none
        }
        return visible.first(where: \.isActive).map { .session($0.id) } ?? .none
    }

    /// 任务投入只计已结束的非休息记录，进行中时长不能提前进入成果统计。
    static func finishedFocus(for task: NivoTodoTask, sessions: [NivoFocusSession]) -> [NivoFocusSession] {
        sessions.filter {
            $0.ownerKey == task.ownerKey && $0.taskId == task.id && $0.deletedAt == nil
                && $0.status == .finished && $0.mode != .rest
        }.sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
    }

    /// 关联回顾仅展示仍存在的本账户碎片，旧语义快照也可用于定位原任务。
    static func linkedFragments(for task: NivoTodoTask, entries: [NivoMosaicEntry]) -> [NivoMosaicEntry] {
        entries.filter {
            $0.ownerKey == task.ownerKey && $0.deletedAt == nil
                && ($0.taskIDs.contains(task.id) || ($0.taskSnapshots ?? []).contains { $0.id == task.id })
        }.sorted { ($0.day, $0.createdAt, $0.id) > ($1.day, $1.createdAt, $1.id) }
    }
}
