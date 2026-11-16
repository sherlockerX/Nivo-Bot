import Foundation

/// 一天中的本地时间；独立于日期保存，系统时区改变后仍在同一钟点提醒。
struct NivoRoutineTime: Codable, Hashable, Comparable, Sendable {
    var hour: Int
    var minute: Int

    var isValid: Bool { (0...23).contains(hour) && (0...59).contains(minute) }
    var text: String { String(format: "%02d:%02d", hour, minute) }

    /// 同一分钟只安排一次，排序不依赖显示语言。
    static func < (left: Self, right: Self) -> Bool {
        left.hour * 60 + left.minute < right.hour * 60 + right.minute
    }

    /// CLI与编辑页共用严格时间解析，不把非法时间自动归一化到第二天。
    static func parse(_ text: String) -> Self? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        let result = Self(hour: hour, minute: minute)
        return result.isValid ? result : nil
    }
}

/// 新增日程字段放在可选对象中，旧routines.json仍按原有时间读取。
struct NivoRoutineSchedule: Codable, Equatable, Sendable {
    var times: [NivoRoutineTime] = []
    /// 与Calendar.weekday和安卓一致：星期日为1，星期六为7。
    var customDays: [Int] = []
    var startDay: Int64?
    var endDay: Int64?
    var intervalMinutes: Int?
}

/// 对话运行方式和模型选择按任务保存，不修改全局默认模型。
struct NivoRoutineExecution: Codable, Equatable, Sendable {
    enum Target: String, Codable, CaseIterable, Sendable { case newSession, append, rerun }
    enum ModelKind: String, Codable, Sendable { case entry, group }
    var target: Target = .newSession
    var messageID: String?
    var modelKind: ModelKind?
    var modelID: String?
    var autoDisableOnFailure = false
    var failureThreshold = 5
    var notification: NivoRoutineNotificationOptions?
}

/// 日程计算只依赖传入的时间和日历，可用固定时区回归夏令时与跨日行为。
enum NivoRoutineScheduleRules {
    /// 新任务不补跑创建之前的时间，单次任务在跨日后仍保留原定时刻。
    static func nextDue(_ routine: NanoMuseRoutine, after now: Date, calendar: Calendar) -> Date? {
        guard routine.enabled else { return nil }
        let schedule = routine.schedule ?? NivoRoutineSchedule()
        if let endDay = schedule.endDay, NivoLifeDay.value(now, timeZone: calendar.timeZone) > endDay { return nil }
        if let minutes = schedule.intervalMinutes, minutes > 0 {
            var due = routine.lastFiredAt?.addingTimeInterval(Double(minutes) * 60)
                ?? routine.createdAt.addingTimeInterval(60)
            if let start = schedule.startDay {
                due = max(due, calendar.startOfDay(for: NivoLifeDay.date(start, timeZone: calendar.timeZone)))
            }
            return withinWindow(due, schedule: schedule, calendar: calendar) ? due : nil
        }
        if routine.repeatMode == .once, routine.lastFiredAt != nil { return nil }
        let times = normalizedTimes(routine)
        let origin = routine.repeatMode == .once ? routine.createdAt : now
        var day = calendar.startOfDay(for: origin)
        if let startDay = schedule.startDay {
            day = max(day, calendar.startOfDay(for: NivoLifeDay.date(startDay, timeZone: calendar.timeZone)))
        }
        // 星期规则最多需要七天；多留一天覆盖夏令时跳过的整日。
        for _ in 0..<9 {
            if qualifies(day, routine: routine, calendar: calendar) {
                let candidates = times.compactMap { instant($0, on: day, calendar: calendar) }
                if let due = candidates.first(where: {
                    $0 > routine.createdAt && $0 > (routine.lastFiredAt ?? .distantPast)
                        && withinWindow($0, schedule: schedule, calendar: calendar)
                }) { return due }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// 编辑页和旧客户端均保留主时间，额外时间去重后统一排序。
    static func normalizedTimes(_ routine: NanoMuseRoutine) -> [NivoRoutineTime] {
        let primary = NivoRoutineTime(hour: routine.hour, minute: routine.minute)
        return Array(Set([primary] + (routine.schedule?.times ?? []))).filter(\.isValid).sorted()
    }

    /// 多个时间点分别排入通知，关闭应用后后续时点仍有提醒。
    static func notificationDates(_ routine: NanoMuseRoutine, after now: Date,
                                   limit: Int = 8, calendar: Calendar = .current) -> [Date] {
        guard routine.enabled, limit > 0 else { return [] }
        var cursor = routine
        var dates: [Date] = []
        var reference = now
        for _ in 0..<(limit + 1) {
            guard let due = cursor.nextDue(after: reference, calendar: calendar) else { break }
            if due > now.addingTimeInterval(30) { dates.append(due) }
            cursor.lastFiredAt = max(now, due)
            reference = max(now, due).addingTimeInterval(1)
            if dates.count >= limit { break }
        }
        return dates
    }

    /// 写入前拒绝空星期、逆序日期、过长内容和不可执行的对话目标。
    static func validate(_ routine: NanoMuseRoutine) throws {
        guard !routine.id.isEmpty, routine.id.utf8.count <= 200,
              routine.label.count <= 200, routine.prompt.utf8.count <= 100_000,
              routine.runs.count <= 50, (routine.revision ?? 0) >= 0,
              (routine.consecutiveFailures ?? 0) >= 0, (routine.consecutiveFailures ?? 0) <= 1_000_000,
              (routine.totalFailures ?? 0) >= 0, (routine.totalFailures ?? 0) <= 1_000_000_000,
              NivoRoutineTime(hour: routine.hour, minute: routine.minute).isValid else {
            throw NivoLifeError.invalidField("routine")
        }
        if let schedule = routine.schedule { try validateSchedule(schedule, mode: routine.repeatMode) }
        else if routine.repeatMode == .custom { throw NivoLifeError.invalidField("custom_days") }
        if let sessionID = routine.dedicatedSessionID, UUID(uuidString: sessionID) == nil {
            throw NivoLifeError.invalidField("dedicated_session_id")
        }
        if let pending = routine.pendingRun {
            guard UUID(uuidString: pending.id) != nil, pending.queuedAt.timeIntervalSince1970.isFinite,
                  pending.trigger == "command", !routine.runs.contains(where: { $0.status == "running" }) else {
                throw NivoLifeError.invalidField("pending_run")
            }
        }
        if let script = routine.script {
            try script.validate()
            guard routine.prompt.isEmpty, routine.execution?.target != .rerun,
                  routine.execution?.modelID == nil, routine.goalId == nil, !routine.hidden else {
                throw NivoLifeError.invalidField("script_prompt_or_model_conflict")
            }
        }
        guard let execution = routine.execution else { return }
        guard (2...100).contains(execution.failureThreshold),
              (execution.notification?.title?.count ?? 0) <= 200,
              (execution.modelID == nil) == (execution.modelKind == nil) else {
            throw NivoLifeError.invalidField("routine_execution")
        }
        if execution.target != .newSession {
            guard let sessionID = routine.sessionId, UUID(uuidString: sessionID) != nil else {
                throw NivoLifeError.invalidField("session_id")
            }
        }
        if execution.target == .rerun {
            guard let messageID = execution.messageID, UUID(uuidString: messageID) != nil else {
                throw NivoLifeError.invalidField("message_id")
            }
        } else if routine.script == nil && routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NivoLifeError.invalidField("prompt")
        }
    }

    private static func validateSchedule(_ schedule: NivoRoutineSchedule, mode: NanoMuseRoutine.Repeat) throws {
        guard schedule.times.count <= 24, schedule.times.allSatisfy(\.isValid),
              schedule.customDays.allSatisfy({ (1...7).contains($0) }),
              mode != .custom || !schedule.customDays.isEmpty else { throw NivoLifeError.invalidField("schedule") }
        if let minutes = schedule.intervalMinutes, !(1...525_600).contains(minutes) {
            throw NivoLifeError.invalidField("interval_minutes")
        }
        let bounds = [schedule.startDay, schedule.endDay].compactMap { $0 }
        guard bounds.allSatisfy({ (-25_567...84_005).contains($0) }),
              (schedule.startDay ?? .min) <= (schedule.endDay ?? .max) else {
            throw NivoLifeError.invalidField("date_window")
        }
    }

    private static func qualifies(_ day: Date, routine: NanoMuseRoutine, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: day)
        switch routine.repeatMode {
        case .once, .daily: return true
        case .weekdays: return (2...6).contains(weekday)
        case .custom: return routine.schedule?.customDays.contains(weekday) == true
        }
    }

    private static func withinWindow(_ instant: Date, schedule: NivoRoutineSchedule, calendar: Calendar) -> Bool {
        let day = NivoLifeDay.value(instant, timeZone: calendar.timeZone)
        return day >= (schedule.startDay ?? .min) && day <= (schedule.endDay ?? .max)
    }

    private static func instant(_ time: NivoRoutineTime, on day: Date, calendar: Calendar) -> Date? {
        // 春季不存在的钟点顺延至该日下一个有效时刻；秋季重复钟点只取第一次。
        let match = DateComponents(hour: time.hour, minute: time.minute, second: 0)
        guard let result = calendar.nextDate(after: day.addingTimeInterval(-1), matching: match,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first), calendar.isDate(result, inSameDayAs: day) else { return nil }
        return result
    }
}
