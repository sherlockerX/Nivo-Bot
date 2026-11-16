import Foundation

/// 标签统计使用完成时快照，多标签均分一项任务的权重。
struct NivoTodoTagSlice: Equatable, Identifiable, Sendable {
    var tag: String
    var weight: Double
    var taskIDs: [String]
    var percentage: Double
    var id: String { tag }
}

/// 日期范围采用左闭右开，删除或重开的任务不再计入有效完成。
enum NivoTodoStatistics {
    static func calculate(_ tasks: [NivoTodoTask], startDay: Int64, endDay: Int64) -> [NivoTodoTagSlice] {
        var seen: Set<String> = []
        let completed = tasks.filter { task in
            guard task.deletedAt == nil, task.status == .done, let day = task.completedDay,
                  day >= startDay, day < endDay else { return false }
            return seen.insert(task.ownerKey + "\0" + task.id).inserted
        }
        guard !completed.isEmpty else { return [] }
        var weights: [String: Double] = [:]
        var identifiers: [String: [String]] = [:]
        for task in completed {
            let tags = task.completionTags.isEmpty ? [""] : task.completionTags
            for tag in tags {
                weights[tag, default: 0] += 1.0 / Double(tags.count)
                identifiers[tag, default: []].append(task.id)
            }
        }
        return weights.map { tag, weight in
            NivoTodoTagSlice(tag: tag, weight: weight, taskIDs: identifiers[tag] ?? [],
                             percentage: weight / Double(completed.count) * 100)
        }.sorted { $0.weight == $1.weight ? $0.tag < $1.tag : $0.weight > $1.weight }
    }
}
