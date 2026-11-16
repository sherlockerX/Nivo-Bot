import Foundation

/// 任务日期代表本地日历日，保存时不受时区偏移和夏令时小时数影响。
enum NivoLifeDay {
    /// 从本地公历年月日生成安卓兼容的epoch day。
    static func value(_ date: Date = Date(), timeZone: TimeZone = .current) -> Int64 {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let components = local.dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return Int64((utc.date(from: components) ?? date).timeIntervalSince1970 / 86_400)
    }

    /// 将epoch day的年月日映射到当前时区正午，避免午夜夏令时缺口。
    static func date(_ day: Int64, timeZone: TimeZone = .current) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = Date(timeIntervalSince1970: Double(day) * 86_400)
        var components = utc.dateComponents([.year, .month, .day], from: reference)
        components.hour = 12
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        return local.date(from: components) ?? reference
    }
}
