import Foundation

/// 在用户发起编辑时推进已见版本，连续快速操作不必等待数据库缓存刷新。
enum NivoProviderEditClock {
    /// 只比较当前页面已知的时间；尚未到达页面的远端事件由数据库合并规则处理。
    static func next(after observed: [Date], now: Date = Date()) -> Date {
        guard let latest = observed.max(), latest >= now else { return now }
        let seconds = latest.timeIntervalSince1970
        return Date(timeIntervalSince1970: max(seconds + 0.001, seconds.nextUp))
    }
}
