import Foundation

/// 定时任务值模型，与前台执行器分离以验证日期和档案兼容规则。
struct NanoMuseRoutine: Codable, Identifiable, Equatable, Sendable {
    enum Repeat: String, Codable, CaseIterable, Sendable { case once, daily, weekdays, custom }

    struct Run: Codable, Equatable, Sendable {
        var at: Date
        var ok: Bool
        var note: String?
        /// 可选字段兼容既有记录，不把旧记录推断为包含完整运行证据。
        var id: String?
        var sessionId: String?
        var finishedAt: Date?
        var duration: TimeInterval?
        var trigger: String?
        var result: String?
        var status: String?
        var scheduledFor: Date?
        var resultTruncated: Bool?
        var notification: NivoRoutineNotificationDecision?
        /// 进程结果与模型自报分别存储，不能将模型的话当成退出码。
        var exitCode: Int?
        var reportedStatus: String?
        var resultSource: String?
        var scriptDigest: String?
        var verifiedOutcome: String?
        var stdoutBytes: Int64?
        var isDebug: Bool?
        var stdoutPreview: String?
        /// 进程已结束后的聊天写入错误不改变执行结论，也不触发脚本重放。
        var deliveryError: String?
    }

    var id: String = UUID().uuidString
    var label: String
    var prompt: String
    var hour: Int
    var minute: Int
    var repeatMode: Repeat = .daily
    /// 兼容早期每隔若干小时运行的目标检查。
    var intervalHours: Int? = nil
    var enabled: Bool = true
    /// 隐藏的目标检查和旧动态任务不出现在用户任务列表中。
    var hidden: Bool = false
    var goalId: String? = nil
    /// 运行的目标对话；新执行协议的具体方式由execution决定。
    var sessionId: String? = nil
    var createdAt: Date = Date()
    var lastFiredAt: Date? = nil
    var runs: [Run] = []
    /// 增量日程与运行配置保持可选，旧档案无需重写即可加载。
    var schedule: NivoRoutineSchedule?
    var execution: NivoRoutineExecution?
    var revision: Int64?
    var consecutiveFailures: Int?
    var totalFailures: Int?
    var lastSessionID: String?
    /// 新对话模式每个任务保留一个专属对话，删除后下次显式运行再创建。
    var dedicatedSessionID: String?
    /// 只保存已接受且尚未开始的请求；开始时与运行记录在同次写入中交接。
    var pendingRun: NivoRoutinePendingRun?
    /// 显式脚本不依赖模型；缺席时保持原来的提示词执行方式。
    var script: NivoRoutineScript?
    /// 调试脚本只留运行记录，不创建聊天；普通任务始终保存对话结果。
    var debug: Bool?
    var sessionOutput: Bool?

    var lastOk: Bool? { runs.first?.ok }

    /// 返回尚未运行的下个时点，包含当前应补跑的时点；停用或单次已运行时返回nil。
    func nextDue(after: Date, calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        if schedule == nil, let hours = intervalHours, hours > 0 {
            return lastFiredAt.map { $0.addingTimeInterval(TimeInterval(hours) * 3600) }
                ?? createdAt.addingTimeInterval(60)
        }
        return NivoRoutineScheduleRules.nextDue(self, after: after, calendar: calendar)
    }

    /// 当前时间已到达尚未运行的时点时，允许前台调度器执行。
    func isDue(at now: Date, calendar: Calendar = .current) -> Bool {
        guard let due = nextDue(after: now, calendar: calendar) else { return false }
        return due <= now
    }
}
