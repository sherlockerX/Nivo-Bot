import Foundation

/// 每日碎片的时间尺度，和Android Mosaic保持同一组入口。
enum NivoMosaicScope: String, CaseIterable, Codable, Sendable {
    case day, week, month, quarter, year
}

/// 未选择心情时保存nil，不把默认选择当作用户报告。
enum NivoMosaicMood: Int, CaseIterable, Codable, Sendable {
    case great = 1, good, neutral, low, bad
}

/// 已发布碎片保存关联时的语义快照，后续任务与习惯改名不改写历史。
struct NivoMosaicEntry: Codable, Equatable, Identifiable, Sendable {
    var ownerKey: String
    var id: String
    var day: Int64
    var text: String
    var mood: NivoMosaicMood?
    var taskIDs: [String]
    var focusIDs: [String]
    var mediaPath: String?
    var createdAt: Int64
    var updatedAt: Int64
    var deletedAt: Int64?
    var revision: Int64?
    var habitID: String?
    var habitTitle: String?
    var taskSnapshots: [NivoMosaicTaskLink]?
    var focusSnapshots: [NivoMosaicFocusLink]?
    var crop: NivoMosaicCrop?
    var shape: String?
    var zoneID: String?
    /// 心得来源独立于用户可取消的关联，用于重复点击时定位原条目。
    var reflectionSessionID: String?
}

/// 编辑草稿携带读入的版本，自动保存不修改任务或习惯状态。
struct NivoMosaicDraft: Codable, Equatable, Identifiable, Sendable {
    var ownerKey: String
    var id: String
    var day: Int64
    var text: String
    var mood: NivoMosaicMood?
    var taskIDs: [String] = []
    var focusIDs: [String] = []
    var mediaPath: String?
    var entryID: String?
    var updatedAt: Int64
    var expectedRevision: Int64?
    var taskSelections: [NivoTodoSelection]?
    var habitID: String?
    var shouldMarkHabitDone: Bool?
    var crop: NivoMosaicCrop?
    var shape: String?
    /// 来源为空时保持普通碎片语义，旧快照缺少此字段仍可解码。
    var reflectionSessionID: String?
}

/// 习惯当前名称与历史日程分开保存，暂停不会抹去过去的计划。
struct NivoMosaicHabit: Codable, Equatable, Identifiable, Sendable {
    var ownerKey: String
    var id: String
    var title: String
    var weekdays: Set<Int>
    var createdAt: Int64
    var archivedDay: Int64?
    var revision: Int64?
    var shape: String?
    var schedules: [NivoMosaicHabitSchedule]?
}

/// 同一天多次改计划覆盖当天版本，之前日期维持旧计划。
struct NivoMosaicHabitSchedule: Codable, Equatable, Sendable {
    var fromDay: Int64
    var weekdays: Set<Int>
}

/// 当日明确勾选完成或跳过，没有记录表示尚未标记。
struct NivoMosaicHabitDay: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, CaseIterable, Sendable { case done, skipped }
    var habitID: String
    var day: Int64
    var status: Status
    var updatedAt: Int64
    var id: String { "\(habitID):\(day)" }
}

/// 裁切仅记录视口，不改写用户原图；坐标归一化为0到1。
struct NivoMosaicCrop: Codable, Equatable, Sendable {
    var focusX = 0.5
    var focusY = 0.5
    var zoom = 1.0
}

/// 关联快照记录碎片发布当时的任务名称和状态。
struct NivoMosaicTaskLink: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var status: NivoTodoStatus
    /// 关联首次保存的时间；旧快照没有此字段时不以碎片日期补造。
    var linkedAt: Int64?
}

/// 关联专注保留实际计量时长，休息时段不会作为专注关联。
struct NivoMosaicFocusLink: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var elapsedMs: Int64
    /// 保留实际会话的起止时刻；旧快照的未知时间保持为空。
    var startedAt: Int64?
    var endedAt: Int64?
}

/// 当日封面、心情和拼图形状由用户独立选择。
struct NivoMosaicDayInfo: Codable, Equatable, Sendable {
    var day: Int64
    var mood: NivoMosaicMood?
    var coverEntryID: String?
    var updatedAt: Int64
    var form: String?
}

/// 嵌入生活事务容器的碎片状态，可选字段兼容旧独立快照。
struct NivoMosaicState: Codable, Equatable, Sendable {
    var version = 1
    var ownerKey: String
    var entries: [NivoMosaicEntry] = []
    var drafts: [NivoMosaicDraft] = []
    var habits: [NivoMosaicHabit] = []
    var days: [NivoMosaicDayInfo] = []
    var habitDays: [NivoMosaicHabitDay]?
}

/// 以用户所选自然日计算范围，不随时区变化重解释已存日期。
struct NivoMosaicRange: Equatable, Sendable {
    var startDay: Int64
    var endDay: Int64
    var scope: NivoMosaicScope
}

/// 原生日期控件与所有统计共享的时间范围运算。
enum NivoMosaicCalendar {
    static func range(scope: NivoMosaicScope, anchor: Date, calendar: Calendar = .current) -> NivoMosaicRange {
        let day = calendar.startOfDay(for: anchor)
        let start: Date
        let end: Date
        switch scope {
        case .day: start = day; end = day
        case .week:
            start = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
            end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        case .month:
            start = calendar.dateInterval(of: .month, for: day)?.start ?? day
            end = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .month, value: 1, to: start) ?? start) ?? start
        case .quarter:
            let month = calendar.component(.month, from: day)
            let firstMonth = ((month - 1) / 3) * 3 + 1
            start = calendar.date(from: DateComponents(year: calendar.component(.year, from: day), month: firstMonth, day: 1)) ?? day
            end = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .month, value: 3, to: start) ?? start) ?? start
        case .year:
            start = calendar.dateInterval(of: .year, for: day)?.start ?? day
            end = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .year, value: 1, to: start) ?? start) ?? start
        }
        return NivoMosaicRange(startDay: NivoLifeDay.value(start), endDay: NivoLifeDay.value(end), scope: scope)
    }

    static func shifted(scope: NivoMosaicScope, anchor: Date, amount: Int, calendar: Calendar = .current) -> Date {
        let component: Calendar.Component
        switch scope {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .quarter: component = .month
        case .year: component = .year
        }
        return calendar.date(byAdding: component, value: scope == .quarter ? amount * 3 : amount, to: anchor) ?? anchor
    }
}
