import Foundation

/// 通知策略与安卓命令使用相同的取值；旧任务缺少此对象时沿用on_change。
struct NivoRoutineNotificationOptions: Codable, Equatable, Sendable {
    enum Policy: String, Codable, CaseIterable, Sendable {
        case always, onChange = "on_change", onFailure = "on_failure", never
    }
    var policy: Policy = .onChange
    var title: String?
    var isSilent = false
}

/// 决定与提交结果分开存储；系统接受请求也不等于用户已经看到通知。
struct NivoRoutineNotificationDecision: Codable, Equatable, Sendable {
    var shouldNotify: Bool
    var reason: String
    var silentReason: String?
    var submittedAt: Date?
    var deliveryError: String?
}

/// 每个账户分别保存静音时段，默认与安卓一致。
struct NivoRoutineNotificationSettings: Codable, Equatable, Sendable {
    var quietHours = "01:00-08:00"
}

/// 通知去重与静音计算只依赖明确的时间和已提交的记录。
enum NivoRoutineNotificationRules {
    /// 接受off或两个严格的本地钟点，不接受部分解析或额外段落。
    static func validateQuietHours(_ text: String) throws {
        guard text != "off" else { return }
        guard quietRange(text) != nil else { throw NivoLifeError.invalidField("quiet_hours") }
    }

    /// 支持跨午夜，结束时点不再静音；相同起止时间代表空窗口。
    static func isQuiet(_ text: String, at now: Date, calendar: Calendar = .current) -> Bool {
        guard let (start, end) = quietRange(text), start != end else { return false }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return start < end ? (start..<end).contains(minute) : minute >= start || minute < end
    }

    /// 只以已成功提交的通知去重；当前运行和未来时间戳不消耗历史限额。
    static func decide(row: NanoMuseRoutine, run: NanoMuseRoutine.Run, allRows: [NanoMuseRoutine],
                       settings: NivoRoutineNotificationSettings, now: Date, dryNotify: Bool,
                       calendar: Calendar = .current) -> NivoRoutineNotificationDecision {
        let options = row.execution?.notification ?? NivoRoutineNotificationOptions()
        if row.debug == true { return suppressed("debug") }
        if dryNotify { return suppressed("dry_notify") }
        if options.policy == .never { return suppressed("policy_never") }
        let body = normalized(run.result ?? "")
        if run.ok, options.policy == .onFailure { return suppressed("policy_on_failure") }
        if run.ok, body.isEmpty { return suppressed("empty") }
        let previous = row.runs.filter { $0.id != run.id && $0.notification?.submittedAt != nil }
        if run.ok, options.policy == .onChange, previous.contains(where: {
            $0.ok && within($0.notification?.submittedAt, before: now, seconds: 6 * 3_600)
                && normalized($0.result ?? "") == body
        }) { return suppressed("unchanged") }
        let recent = allRows.flatMap(\.runs).filter { within($0.notification?.submittedAt, before: now, seconds: 3_600) }
        if recent.count >= 10 { return suppressed("rate_limited") }
        let silent: String?
        if options.isSilent { silent = "silent" }
        else if isQuiet(settings.quietHours, at: now, calendar: calendar) { silent = "quiet_hours" }
        else if previous.contains(where: { within($0.notification?.submittedAt, before: now, seconds: 60) }) { silent = "rate_limited" }
        else { silent = nil }
        return NivoRoutineNotificationDecision(shouldNotify: true,
            reason: run.ok ? (options.policy == .always ? "always" : "changed") : "failure", silentReason: silent)
    }

    /// NO_OUTPUT是定时任务明确的空结果约定，不把这个协议词推送给用户。
    static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "NO_OUTPUT" ? "" : trimmed
    }

    private static func suppressed(_ reason: String) -> NivoRoutineNotificationDecision {
        NivoRoutineNotificationDecision(shouldNotify: false, reason: reason)
    }

    private static func within(_ date: Date?, before now: Date, seconds: TimeInterval) -> Bool {
        guard let date else { return false }
        return date <= now && now.timeIntervalSince(date) < seconds
    }

    private static func quietRange(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 5 }),
              let start = NivoRoutineTime.parse(String(parts[0])), let end = NivoRoutineTime.parse(String(parts[1])) else { return nil }
        return (start.hour * 60 + start.minute, end.hour * 60 + end.minute)
    }
}
