import Foundation

/// 一次明确点击可从已结束的计时开始休息或继续专注。
struct NivoFocusFollowUp: Equatable, Sendable {
    var mode: NivoFocusMode
    var minutes: Int
    var title: String? = nil
    var taskID: String? = nil
}

/// 普通页面与全屏计时共用展示规则，显示值不写入专注档案。
enum NivoFocusPresentationRules {
    /// 返回当前界面应展示的时长。
    static func displayedDuration(_ session: NivoFocusSession, clock: NivoFocusClockSample) -> Int64 {
        let elapsed = NivoFocusRules.currentElapsed(session, clock: clock)
        if session.mode == .stopwatch || session.status == .finished { return elapsed }
        return max(0, session.targetMs - elapsed)
    }

    /// 只有到期或重启需要仓库结算，秒针变化不重复发布整份生活数据。
    static func needsReconciliation(_ session: NivoFocusSession, clock: NivoFocusClockSample) -> Bool {
        guard session.deletedAt == nil, session.status == .running else { return false }
        return session.bootID != clock.bootID || NivoFocusRules.currentElapsed(session, clock: clock) >= session.targetMs
    }

    /// 同一本地日的第4、8、12次番茄触发长休息，稍后重开完成页仍按原完成次序判断。
    static func followUp(after source: NivoFocusSession, sessions: [NivoFocusSession],
                         timeZone: TimeZone = .current) -> NivoFocusFollowUp? {
        guard source.deletedAt == nil, source.status == .finished, let endedAt = source.endedAt else { return nil }
        let sameOwner = sessions.filter { $0.ownerKey == source.ownerKey }
        guard !sameOwner.contains(where: { $0.followUpFromID == source.id }) else { return nil }
        let completed = sameOwner.filter { $0.deletedAt == nil && $0.status == .finished }
        if source.mode == .rest { return continuation(after: source, completed: completed) }
        let completedDay = NivoLifeDay.value(date(endedAt), timeZone: timeZone)
        let count = completed.count { session in
            guard session.mode == .pomodoro, let end = session.endedAt else { return false }
            return (end, session.id) <= (endedAt, source.id)
                && NivoLifeDay.value(date(end), timeZone: timeZone) == completedDay
        }
        return NivoFocusFollowUp(mode: .rest, minutes: source.mode == .pomodoro && count > 0 && count.isMultiple(of: 4) ? 15 : 5)
    }

    private static func continuation(after rest: NivoFocusSession, completed: [NivoFocusSession]) -> NivoFocusFollowUp? {
        let focused = completed.filter { $0.mode != .rest }
        let previous: NivoFocusSession?
        if let identifier = rest.followUpFromID {
            previous = focused.first { $0.id == identifier }
        } else {
            previous = focused.filter { ($0.endedAt ?? .max) <= rest.startedAt }
                .max { ($0.endedAt ?? .min, $0.id) < ($1.endedAt ?? .min, $1.id) }
        }
        guard let previous else { return nil }
        let minutes = previous.mode == .stopwatch ? 25 : Int((previous.targetMs + 30_000) / 60_000)
        return NivoFocusFollowUp(mode: previous.mode, minutes: min(180, max(1, minutes)),
                                 title: previous.title, taskID: previous.taskId)
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
