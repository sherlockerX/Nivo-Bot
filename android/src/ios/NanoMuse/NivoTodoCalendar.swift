import Foundation

/// 计划与截止同一天时只索引一次，未设置日期的任务始终单独可见。
struct NivoTodoCalendarIndex: Equatable, Sendable {
    var byDay: [Int64: [NivoTodoTask]]
    var undated: [NivoTodoTask]

    /// 保留传入列表的排序，不改变任务本身或生成日期。
    init(tasks: [NivoTodoTask]) {
        byDay = [:]
        undated = []
        for task in tasks where task.deletedAt == nil {
            let days = Set([task.scheduledDay, task.dueDay].compactMap { $0 })
            if days.isEmpty { undated.append(task) }
            for day in days { byDay[day, default: []].append(task) }
        }
    }
}

/// 月份显示始终使用公历与本地时区，周起点沿用用户日历设置。
struct NivoTodoCalendarMonth: Equatable, Sendable {
    var days: [Int64]
    var leadingEmptyCells: Int

    /// 日期使用epoch day，夏令时月份不按固定86400秒推进本地日期。
    init(selected: Date, calendar source: Calendar = .current) {
        let calendar = Self.calendar(source)
        guard let interval = calendar.dateInterval(of: .month, for: selected),
              let range = calendar.range(of: .day, in: .month, for: selected) else {
            days = []
            leadingEmptyCells = 0
            return
        }
        let first = NivoLifeDay.value(interval.start, timeZone: calendar.timeZone)
        days = range.map { first + Int64($0 - 1) }
        leadingEmptyCells = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
    }

    /// 切月保留日号，目标月份天数较少时收敛到月末，并限制有效年份。
    static func moving(_ selected: Date, months: Int, calendar source: Calendar = .current) -> Date? {
        let calendar = calendar(source)
        guard let interval = calendar.dateInterval(of: .month, for: selected),
              let destination = calendar.date(byAdding: .month, value: months, to: interval.start),
              (1...9999).contains(calendar.component(.year, from: destination)),
              let range = calendar.range(of: .day, in: .month, for: destination) else { return nil }
        var components = calendar.dateComponents([.year, .month], from: destination)
        components.day = min(calendar.component(.day, from: selected), range.count)
        components.hour = 12
        return calendar.date(from: components)
    }

    /// 统一时间与周起点，避免佛历等系统日历改变已保存公历日期的意义。
    static func calendar(_ source: Calendar) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = source.timeZone
        result.locale = source.locale
        result.firstWeekday = source.firstWeekday
        result.minimumDaysInFirstWeek = source.minimumDaysInFirstWeek
        return result
    }
}
