import Foundation

/// 图表可以按任务的分组或标签归类。
enum NivoFocusShareBy: Hashable { case group, tag }

/// 同一类别内已分摊的实际时长。
struct NivoFocusGroupTotal: Equatable, Identifiable, Sendable {
    var group: String
    var durationMs: Int64
    var id: String { group }
}

/// 环形图、总计和图例共用统计结果，不能各自采用不同的记录筛选。
struct NivoFocusDistribution: Equatable, Sendable {
    var groups: [NivoFocusGroupTotal]
    var sessionCount = 0
    var totalMs: Int64 { groups.reduce(0) { $0 + $1.durationMs } }
}

/// 单次遍历专注区间，避免为每个分组重复扫描全部历史。
enum NivoFocusStatistics {
    /// 统计区间采用左闭右开，跨午夜按交集切分，休息、删除和未完成记录不计入。
    static func distribution(sessions: [NivoFocusSession], spans: [NivoFocusSpan],
                             startMs: Int64, endMs: Int64, tasks: [NivoTodoTask] = [],
                             by: NivoFocusShareBy = .group) -> NivoFocusDistribution {
        guard endMs > startMs else { return NivoFocusDistribution(groups: []) }
        let live = Dictionary(grouping: tasks.filter { $0.deletedAt == nil }, by: \.id)
        var measured: [String: Int64] = [:]
        for span in spans {
            guard span.durationMs > 0, span.startedAt <= Int64.max - span.durationMs else { continue }
            let duration = max(0, min(endMs, span.startedAt + span.durationMs) - max(startMs, span.startedAt))
            if duration > 0 { measured[span.sessionId, default: 0] += duration }
        }
        var totals: [String: Int64] = [:]
        var sessionCount = 0
        for session in sessions where session.status == .finished && session.deletedAt == nil && session.mode != .rest {
            guard let duration = measured[session.id] else { continue }
            sessionCount += 1
            let task = session.taskId.flatMap { live[$0]?.first { $0.ownerKey == session.ownerKey } }
            let names = by == .group ? [task?.groupName ?? session.groupName] : (task?.tags ?? session.tags)
            var keys = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }).sorted()
            if keys.isEmpty { keys = [""] }
            // 先按整次会话平分，余下的毫秒按稳定顺序分配，避免暂停次数改变标签占比。
            let count = Int64(keys.count)
            for (index, key) in keys.enumerated() {
                totals[key, default: 0] += duration / count + (Int64(index) < duration % count ? 1 : 0)
            }
        }
        // 分开映射和排序并固定类型，避免Apple编译器在链式重载中耗尽推导预算。
        var groups: [NivoFocusGroupTotal] = totals.map { entry in
            NivoFocusGroupTotal(group: entry.key, durationMs: entry.value)
        }
        groups.sort { (left: NivoFocusGroupTotal, right: NivoFocusGroupTotal) -> Bool in
            if left.durationMs != right.durationMs { return left.durationMs > right.durationMs }
            return left.group < right.group
        }
        return NivoFocusDistribution(groups: groups, sessionCount: sessionCount)
    }
}
