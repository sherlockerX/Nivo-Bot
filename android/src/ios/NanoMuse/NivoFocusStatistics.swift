import Foundation

/// 分组沿用会话开始时的任务快照，每段时间只属于一个分组。
struct NivoFocusGroupTotal: Equatable, Identifiable, Sendable {
    var group: String
    var durationMs: Int64
    var id: String { group }
}

/// 环形图、总计和图例共用统计结果，不能各自采用不同的记录筛选。
struct NivoFocusDistribution: Equatable, Sendable {
    var groups: [NivoFocusGroupTotal]
    var totalMs: Int64 { groups.reduce(0) { $0 + $1.durationMs } }
}

/// 单次遍历专注区间，避免为每个分组重复扫描全部历史。
enum NivoFocusStatistics {
    /// 统计区间采用左闭右开，跨午夜按交集切分，休息、删除和未完成记录不计入。
    static func distribution(sessions: [NivoFocusSession], spans: [NivoFocusSpan],
                             startMs: Int64, endMs: Int64) -> NivoFocusDistribution {
        guard endMs > startMs else { return NivoFocusDistribution(groups: []) }
        var groupsBySession: [String: String] = [:]
        for session in sessions where session.status == .finished && session.deletedAt == nil && session.mode != .rest {
            groupsBySession[session.id] = session.groupName
        }
        var totals: [String: Int64] = [:]
        for span in spans {
            guard let group = groupsBySession[span.sessionId] else { continue }
            let duration = max(0, min(endMs, span.startedAt + span.durationMs) - max(startMs, span.startedAt))
            if duration > 0 { totals[group, default: 0] += duration }
        }
        // 分开映射和排序并固定类型，避免Apple编译器在链式重载中耗尽推导预算。
        var groups: [NivoFocusGroupTotal] = totals.map { entry in
            NivoFocusGroupTotal(group: entry.key, durationMs: entry.value)
        }
        groups.sort { (left: NivoFocusGroupTotal, right: NivoFocusGroupTotal) -> Bool in
            if left.durationMs != right.durationMs { return left.durationMs > right.durationMs }
            return left.group < right.group
        }
        return NivoFocusDistribution(groups: groups)
    }
}
