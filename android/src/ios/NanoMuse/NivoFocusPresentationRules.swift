import Foundation

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
}
