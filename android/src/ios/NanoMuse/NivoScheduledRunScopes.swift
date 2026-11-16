import Foundation

/// 模型自报和宿主执行状态分别保留，传输失败或非零退出码优先于先前成功上报。
struct NivoScheduledReport: Equatable, Sendable {
    var status: String?
    var reason: String?
    var result: String?

    /// 正常结束的模型任务没有可信上报时仍为未知，不自动宣布业务目标达成。
    func outcome(failed: Bool, scriptExit: Int?, outputRequired: Bool, hasOutput: Bool) -> String {
        if failed || (outputRequired && !hasOutput) || status == "failure" { return "failure" }
        if let scriptExit { return scriptExit == 0 ? "success" : "failure" }
        return status ?? "unknown"
    }
}

/// 只在内存保存运行能力；任务与会话独占，内核执行上下文不能由命令参数自行申领。
final class NivoScheduledRunScopes: @unchecked Sendable {
    static let shared = NivoScheduledRunScopes()

    struct Lease: Equatable, Sendable {
        let nonce: UUID
        let taskID: String
        let runID: String
        let sessionID: String
        let owner: String
        let isScript: Bool
    }

    private struct Active {
        let lease: Lease
        var report = NivoScheduledReport()
    }
    private let lock = NSLock()
    private var sessions: [String: Active] = [:]
    private var contexts: [UInt64: Lease] = [:]
    private var editing: [String: UUID] = [:]

    /// 脚本没有聊天忙碌标记，备份仍须等待全部运行租约释放。
    var isBusy: Bool { lock.withLock { !sessions.isEmpty || !editing.isEmpty } }

    /// 删除或清空从界面检查到SQLite提交期间占住会话，防止任务趁异步交接开始。
    func beginConversationEdit(_ identifiers: Set<String>, scheduledRunID: String? = nil) throws -> UUID {
        try lock.withLock {
            let ownsRun = scheduledRunID.map { runID in
                identifiers.count == 1 && identifiers.allSatisfy {
                    sessions[$0]?.lease.runID == runID && sessions[$0]?.lease.isScript == false
                }
            } ?? identifiers.allSatisfy { sessions[$0] == nil }
            guard ownsRun, identifiers.allSatisfy({ editing[$0] == nil }) else {
                throw NivoLifeError.operationConflict
            }
            let token = UUID()
            for identifier in identifiers { editing[identifier] = token }
            return token
        }
    }

    /// 只撤销本次编辑占位，过期回调不会释放另一个编辑操作。
    func endConversationEdit(_ token: UUID) {
        lock.withLock { editing = editing.filter { $0.value != token } }
    }

    /// 会话尚未获得租约时不能开始执行，两个任务不能同时向同一对话写入。
    func enter(taskID: String, runID: String, sessionID: String, owner: String, isScript: Bool) throws -> Lease {
        try lock.withLock {
            // 空owner代表未登录的本机账户，同样允许使用自备模型和本地脚本。
            guard UUID(uuidString: runID) != nil, !taskID.isEmpty, !sessionID.isEmpty else {
                throw NivoLifeError.invalidField("run_identity")
            }
            guard sessions[sessionID] == nil, editing[sessionID] == nil,
                  !sessions.values.contains(where: { $0.lease.taskID == taskID }) else {
                throw NivoLifeError.operationConflict
            }
            let lease = Lease(nonce: UUID(), taskID: taskID, runID: runID, sessionID: sessionID, owner: owner, isScript: isScript)
            sessions[sessionID] = Active(lease: lease)
            return lease
        }
    }

    /// 仅释放自己取得的租约，迟到回调不能清除后来运行的任务。
    func leave(_ lease: Lease) {
        lock.withLock {
            guard sessions[lease.sessionID]?.lease == lease else { return }
            sessions.removeValue(forKey: lease.sessionID)
            contexts = contexts.filter { $0.value != lease }
        }
    }

    /// 普通输入不借用任务上下文；当前任务的内部调用必须携带宿主保存的runID。
    func canStart(sessionID: String?, runID: String?) -> Bool {
        lock.withLock {
            if let sessionID, editing[sessionID] != nil { return false }
            guard let sessionID, let active = sessions[sessionID] else { return runID == nil }
            return active.lease.runID == runID
        }
    }

    /// 仅返回当前运行的宿主身份，不从环境变量读取或补建租约。
    func lease(sessionID: String, runID: String) -> Lease? {
        lock.withLock {
            guard let lease = sessions[sessionID]?.lease, lease.runID == runID else { return nil }
            return lease
        }
    }

    /// 在启动进程之前绑定新fs_context；只给本次命令授予上报能力。
    func bind(context: UInt64, to lease: Lease) throws {
        try lock.withLock {
            guard context != 0, contexts[context] == nil, sessions[lease.sessionID]?.lease == lease else {
                throw NivoLifeError.invalidField("NOT_IN_TASK_RUN")
            }
            contexts[context] = lease
        }
    }

    /// 命令退出时立即撤销，遗留子进程也不能在后续任务中继续上报。
    func unbind(context: UInt64) { lock.withLock { _ = contexts.removeValue(forKey: context) } }

    /// 原生命令从内核读取context，模型或来宾填写taskID、runID和PID均不起作用。
    func report(context: UInt64, status: String?, reason: String?, result: String?) throws -> NivoScheduledReport {
        try lock.withLock {
            guard let lease = contexts[context], var active = sessions[lease.sessionID], active.lease == lease else {
                throw NivoLifeError.invalidField("NOT_IN_TASK_RUN")
            }
            guard status != nil || result != nil, status == nil || ["success", "failure"].contains(status!),
                  reason == nil || status != nil, (reason?.unicodeScalars.count ?? 0) <= 200,
                  (result?.unicodeScalars.count ?? 0) <= 4_000 else {
                throw NivoLifeError.invalidField("INVALID_REPORT")
            }
            if let status { active.report.status = status; active.report.reason = reason }
            if let result { active.report.result = result }
            sessions[lease.sessionID] = active
            return active.report
        }
    }

    /// 读取后仍由调用方持有租约，返回的快照不授予任何额外写入权。
    func snapshot(_ lease: Lease) -> NivoScheduledReport? {
        lock.withLock {
            guard let active = sessions[lease.sessionID], active.lease == lease else { return nil }
            return active.report
        }
    }

    /// 报告桥用于识别脚本的静默回执；不公开运行身份到模型输出。
    func lease(context: UInt64) -> Lease? { lock.withLock { contexts[context] } }
}
