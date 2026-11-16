import Foundation

/// 尚未执行的显式运行请求，恢复时保留请求身份而不是再生成一次业务动作。
struct NivoRoutinePendingRun: Codable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var queuedAt: Date
    var trigger: String = "command"
    var dryNotify = false
}

/// 调度器与档案测试共用的队列、启动和中断规则。
enum NivoRoutineRunRules {
    static let maximumResultBytes = 128 * 1_024

    /// 重复点击不会多排一次；只有成功写入后的候选才可向调用方返回已接受。
    static func enqueuing(_ row: NanoMuseRoutine, now: Date, dryNotify: Bool) throws -> NanoMuseRoutine {
        guard row.pendingRun == nil, !row.runs.contains(where: { $0.status == "running" }) else {
            throw NivoLifeError.operationConflict
        }
        var result = row
        result.pendingRun = NivoRoutinePendingRun(queuedAt: now, dryNotify: dryNotify)
        return result
    }

    /// 在模型执行之前将请求原子交接为运行记录，重启不会自动重放已开始的请求。
    static func starting(_ row: NanoMuseRoutine, now: Date, trigger: String) -> NanoMuseRoutine {
        var result = row
        let pending = row.pendingRun
        let origin = pending?.trigger ?? trigger
        let scheduledFor = ["manual", "command"].contains(origin) ? nil : row.nextDue(after: now)
        result.lastFiredAt = now
        result.pendingRun = nil
        result.runs.insert(NanoMuseRoutine.Run(at: now, ok: false, id: pending?.id ?? UUID().uuidString,
            trigger: origin, status: "running", scheduledFor: scheduledFor), at: 0)
        result.runs = Array(result.runs.prefix(50))
        return result
    }

    /// 启动后遗留的运行只记为中断，未知时长与未知结果不按成功填写。
    static func recovering(_ rows: [NanoMuseRoutine]) -> [NanoMuseRoutine] {
        rows.map { row in
            var result = row
            for index in result.runs.indices where result.runs[index].status == "running" {
                result.runs[index].status = "interrupted"
                result.runs[index].ok = false
            }
            return result
        }
    }

    /// 档案保存有界预览，完整结果仍在对应聊天中；截断不会切断UTF-8码点。
    static func boundedResult(_ text: String) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maximumResultBytes else { return (text, false) }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: maximumResultBytes)
        while end.samePosition(in: text.unicodeScalars) == nil { end = text.utf8.index(before: end) }
        return (String(text[..<end]), true)
    }
}
