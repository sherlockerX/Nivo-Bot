import Foundation

/// 专注查询按实际开始日期筛选，稳定排序后分页，删除记录不进入个人分析。
enum NivoPersonalRecordsFocusQuery {
    /// 日期标签沿用设备日历，与专注页面统计的日期语义一致。
    static func rows(_ sessions: [NivoFocusSession], kind: String, startDay: Int64?, endDay: Int64?,
                     timeZone: TimeZone = .current) throws -> [NivoFocusSession] {
        guard startDay == nil || endDay == nil || startDay! <= endDay! else {
            throw NivoJigsawQuery.QueryError("startDate must not follow endDate")
        }
        return sessions.filter { session in
            let day = NivoLifeDay.value(Date(timeIntervalSince1970: Double(session.startedAt) / 1_000), timeZone: timeZone)
            return session.deletedAt == nil && (kind != "active" || session.isActive)
                && (startDay == nil || day >= startDay!) && (endDay == nil || day <= endDay!)
        }.sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
    }

    /// 用本地公历边界计算整段和分组时长，使用全部区间而不是查询页。
    static func statistics(_ sessions: [NivoFocusSession], spans: [NivoFocusSpan], tasks: [NivoTodoTask],
                           startDay: Int64, endDay: Int64, timeZone: TimeZone = .current) throws -> NivoFocusDistribution {
        guard endDay >= startDay, endDay - startDay <= 3_660 else {
            throw NivoJigsawQuery.QueryError("statistics requires a valid range of at most 3661 days")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: NivoLifeDay.date(startDay, timeZone: timeZone))
        let end = calendar.startOfDay(for: NivoLifeDay.date(endDay + 1, timeZone: timeZone))
        return NivoFocusStatistics.distribution(sessions: sessions, spans: spans,
            startMs: Int64(start.timeIntervalSince1970 * 1_000), endMs: Int64(end.timeIntervalSince1970 * 1_000), tasks: tasks)
    }
}
