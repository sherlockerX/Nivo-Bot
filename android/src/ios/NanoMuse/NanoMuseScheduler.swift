//
//  NanoMuseScheduler.swift
//  nanoMuse
//
//  The iPhone's scheduler primitive: a due-list of routines (the daily
//  feed, goal check-ins, the routines made from Ideas) kept in a JSON file,
//  run by the app itself when it is in the foreground — on open, and while
//  it stays active — with a BGAppRefreshTask and local notifications for
//  the hours it is not. iOS gives an app no way to run a model turn on a
//  schedule while it sleeps: when a routine comes due and the app is not
//  up, the phone shows "Check-in: <goal> — open to run it", and the run
//  happens when the person opens the app. Android has WorkManager for this
//  (io.github.nanomuse.app.scheduled.*); the words here say what the phone can
//  and cannot do.
//

import Foundation
import BackgroundTasks
import UserNotifications
import UIKit

// MARK: - Model

extension NanoMuseRoutine {
    /// "Checks every 6 hours" / "Daily 08:00" / "Weekdays 07:30" / "Once 18:00".
    var cadence: String {
        if let schedule {
            if let minutes = schedule.intervalMinutes {
                return String(format: AppLocalized("Every %d minutes"), minutes)
            }
            let times = NivoRoutineScheduleRules.normalizedTimes(self).map(\.text).joined(separator: ", ")
            switch repeatMode {
            case .daily: return String(format: AppLocalized("Daily · %@"), times)
            case .weekdays: return String(format: AppLocalized("Weekdays · %@"), times)
            case .once: return String(format: AppLocalized("Once · %@"), times)
            case .custom:
                let names = Calendar.current.shortWeekdaySymbols
                let days = schedule.customDays.sorted().filter { (1...7).contains($0) }.map { names[$0 - 1] }.joined(separator: ", ")
                return days + " · " + times
            }
        }
        if let h = intervalHours, h > 0 {
            return h == 1 ? AppLocalized("Checks every hour") : String(format: AppLocalized("Checks every %d hours"), h)
        }
        let time = NanoMuseDay.clock(hour: hour, minute: minute)
        switch repeatMode {
        case .once: return String(format: AppLocalized("Once · %@"), time)
        case .daily: return String(format: AppLocalized("Daily · %@"), time)
        case .weekdays: return String(format: AppLocalized("Weekdays · %@"), time)
        case .custom: return time
        }
    }
}

// MARK: - Store + runner

@MainActor
final class NanoMuseScheduler: ObservableObject {
    static let shared = NanoMuseScheduler()

    /// Also listed under BGTaskSchedulerPermittedIdentifiers in Info.plist.
    nonisolated static let backgroundTaskId = "io.github.nanomuse.app.scheduler"
    static let notificationCategory = "NANOMUSE_ROUTINE"

    @Published private(set) var routines: [NanoMuseRoutine] = []
    /// Ids being run right now.
    @Published private(set) var running: Set<String> = []
    @Published private(set) var notificationSettings = NivoRoutineNotificationSettings()
    @Published private(set) var persistenceError: String?
    private var isArchiveReadable = true

    private var file: URL { NanoMuseDirs.root.appendingPathComponent("routines.json") }
    private var settingsFile: URL { NanoMuseDirs.root.appendingPathComponent("routine-settings.json") }
    private var settlementsDirectory: URL { NanoMuseDirs.root.appendingPathComponent("routine-settlements", isDirectory: true) }
    private var catchUpTask: Task<Void, Never>?
    private var notificationsTask: Task<Void, Never>?
    private var tickTimer: Timer?

    private init() {
        load()
    }

    // MARK: Persistence

    private func load() {
        do {
            // nanoMuse: 回滚未完成时保留档案，不从可能只恢复一半的配置启动任务。
            guard !BackupRestoreJournal.hasPendingPersonalDataRecovery else { throw NivoLifeError.corruptStore }
            let loaded = try NivoRoutineArchive.read(file)
            let receipts = try NivoRoutineSettlementFiles.read(directory: settlementsDirectory)
            var settled = loaded
            for receipt in receipts { settled = try receipt.applying(to: settled) }
            let recovered = NivoRoutineRunRules.recovering(settled)
            if recovered != loaded { try NivoRoutineArchive.write(recovered, to: file) }
            notificationSettings = try NivoRoutineArchive.readSettings(settingsFile)
            routines = recovered
            isArchiveReadable = true
            persistenceError = nil
            // 收据清理失败不否定已提交档案，下次载入仍按同一运行身份幂等清理。
            for receipt in receipts { clearSettlement(receipt) }
        } catch {
            isArchiveReadable = false
            persistenceError = error.localizedDescription
        }
    }

    /// C12: the file changed under the store — another account's routines are in place (or
    /// none). The list and the notifications follow.
    func reload() {
        catchUpTask?.cancel()
        catchUpTask = nil
        running = []
        routines = []
        notificationSettings = NivoRoutineNotificationSettings()
        load()
        refreshNotifications()
    }

    /// 账户目录移动前撤销旧提醒，等待中的添加操作只清理自己的批次ID。
    func prepareAccountChange() async {
        catchUpTask?.cancel()
        catchUpTask = nil
        notificationsTask?.cancel()
        tickTimer?.invalidate()
        tickTimer = nil
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter {
            $0.identifier.hasPrefix("nanomuse-routine-") || $0.identifier.hasPrefix("nanomuse-due-")
                || $0.identifier.hasPrefix("nanomuse-result-")
        }.map(\.identifier))
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
            $0.request.content.categoryIdentifier == Self.notificationCategory
        }.map { $0.request.identifier })
    }

    private func persist(_ candidate: [NanoMuseRoutine]) throws {
        guard isArchiveReadable else { throw CocoaError(.fileReadCorruptFile) }
        guard !NanoMuseAccountData.shared.isChangingAccount else { throw NivoLifeError.accountChanged }
        guard !NivoPersonalBackupAccess.isBusy else { throw NivoPersonalBackupError.busy }
        try NivoRoutineArchive.write(candidate, to: file)
        routines = candidate
        persistenceError = nil
        refreshNotifications()
    }

    /// 静音设置跟随账户切换，只有落盘成功后才更新页面和提醒。
    func setQuietHours(_ text: String) throws {
        try requireReadable()
        guard !NanoMuseAccountData.shared.isChangingAccount else { throw NivoLifeError.accountChanged }
        guard !NivoPersonalBackupAccess.isBusy else { throw NivoPersonalBackupError.busy }
        let settings = NivoRoutineNotificationSettings(quietHours: text)
        try NivoRoutineArchive.writeSettings(settings, to: settingsFile)
        notificationSettings = settings
        refreshNotifications()
    }

    // MARK: CRUD

    /// 关闭提示不解除损坏文件的写保护，用户仍需恢复可读的档案。
    func clearPersistenceError() { persistenceError = nil }

    var visible: [NanoMuseRoutine] {
        routines.filter { !$0.hidden }.sorted { ($0.hour * 60 + $0.minute) < ($1.hour * 60 + $1.minute) }
    }

    func routine(id: String) -> NanoMuseRoutine? { routines.first { $0.id == id } }

    @discardableResult
    func create(_ routine: NanoMuseRoutine) -> NanoMuseRoutine? {
        do { return try saveRoutine(routine, creating: true) }
        catch { persistenceError = error.localizedDescription; return nil }
    }

    @discardableResult
    func update(_ routine: NanoMuseRoutine) -> Bool {
        do { _ = try saveRoutine(routine, creating: false); return true }
        catch { persistenceError = error.localizedDescription; return false }
    }

    /// 编辑时同时核对版本；任务运行期间打开的旧表单不能覆盖新运行记录。
    @discardableResult
    func saveRoutine(_ routine: NanoMuseRoutine, creating: Bool, isExecutionUpdate: Bool = false) throws -> NanoMuseRoutine {
        var candidate = routines
        var changed = routine
        if creating {
            guard !candidate.contains(where: { $0.id == routine.id }) else { throw NivoLifeError.operationConflict }
            changed.revision = 1
            candidate.append(changed)
        } else {
            guard let index = candidate.firstIndex(where: { $0.id == routine.id }) else { throw NivoLifeError.notFound(routine.id) }
            guard isExecutionUpdate || (candidate[index].pendingRun == nil && !running.contains(routine.id)) else {
                throw NivoLifeError.operationConflict
            }
            guard (candidate[index].revision ?? 0) == (routine.revision ?? 0) else {
                throw NivoLifeError.staleRevision(expected: routine.revision ?? 0, actual: candidate[index].revision ?? 0)
            }
            guard (routine.revision ?? 0) < Int64.max else { throw NivoLifeError.invalidField("revision") }
            changed.revision = (routine.revision ?? 0) + 1
            candidate[index] = changed
        }
        try persist(candidate)
        return changed
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard var r = routine(id: id) else { return }
        r.enabled = enabled
        update(r)
    }

    func delete(_ id: String) {
        do {
            guard let routine = routine(id: id) else { return }
            try removeRoutine(id, expectedRevision: routine.revision ?? 0)
        }
        catch { persistenceError = error.localizedDescription }
    }

    /// 删除核对版本并保留对应聊天，正在运行的脚本不能被删除后继续执行。
    func removeRoutine(_ id: String, expectedRevision: Int64) throws {
        guard let row = routine(id: id) else { throw NivoLifeError.notFound(id) }
        guard !running.contains(id) else { throw NivoChatAccessError.busy }
        guard (row.revision ?? 0) == expectedRevision else {
            throw NivoLifeError.staleRevision(expected: expectedRevision, actual: row.revision ?? 0)
        }
        try persist(routines.filter { $0.id != id })
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["nanomuse-result-" + id])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["nanomuse-result-" + id])
    }

    /// 命令仅返回已排队，实际成败由运行记录确认；同一任务只占一个队列位置。
    @discardableResult
    func enqueue(_ id: String, dryNotify: Bool = false) throws -> NivoRoutinePendingRun {
        guard !running.contains(id) else { throw NivoLifeError.operationConflict }
        guard let row = routine(id: id) else { throw NivoLifeError.notFound(id) }
        let changed = try NivoRoutineRunRules.enqueuing(row, now: Date(), dryNotify: dryNotify)
        let saved = try saveRoutine(changed, creating: false)
        guard let pending = saved.pendingRun else { throw NivoLifeError.corruptStore }
        catchUp(reason: "command")
        return pending
    }

    /// 工具列表也要报告加载故障，不能把读取失败伪装成没有任务。
    func requireReadable() throws {
        guard isArchiveReadable else { throw NivoLifeError.corruptStore }
    }

    /// Routines that belong to a goal.
    func forGoal(_ goalId: String) -> [NanoMuseRoutine] { routines.filter { $0.goalId == goalId } }

    // MARK: Lifecycle hooks (MinisApp)

    /// Call from the app's init: BGTaskScheduler wants the handler before launch finishes.
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskId, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in
                NanoMuseScheduler.shared.handleBackgroundRefresh(refresh)
            }
        }
    }

    /// The app is on screen: run what is due, and keep checking every minute while it stays up.
    func appBecameActive() {
        catchUp(reason: "active")
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.catchUp(reason: "tick") }
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskId)
    }

    /// The app is leaving the screen: ask for a refresh around the next due time, and make sure the reminders are set.
    func appWentBackground() {
        tickTimer?.invalidate()
        tickTimer = nil
        scheduleBackgroundRefresh()
        refreshNotifications()
    }

    /// The next due moment across all routines.
    func nextDue(after: Date = Date()) -> (routine: NanoMuseRoutine, at: Date)? {
        routines.compactMap { r in r.nextDue(after: after).map { (r, $0) } }.min { $0.1 < $1.1 }
    }

    func scheduleBackgroundRefresh() {
        guard let next = nextDue() else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskId)
        request.earliestBeginDate = max(next.at, Date().addingTimeInterval(15 * 60))
        try? BGTaskScheduler.shared.submit(request)
    }

    /// iOS woke us for a moment: there is no time for a model turn, so the
    /// routines that came due get a notification each, and the next refresh is asked for.
    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        task.expirationHandler = { }
        let now = Date()
        for r in routines where r.isDue(at: now) {
            postDueNotification(r, at: now)
        }
        scheduleBackgroundRefresh()
        task.setTaskCompleted(success: true)
    }

    // MARK: Running

    /// Run every routine that is due, one after the other.
    func catchUp(reason: String) {
        guard catchUpTask == nil, UIApplication.shared.applicationState == .active,
              !NanoMuseAccountData.shared.isChangingAccount else { return }
        let generation = NanoMuseAccountData.shared.generation
        let now = Date()
        let due = routines.filter { ($0.pendingRun != nil || $0.isDue(at: now)) && !running.contains($0.id) }
        guard !due.isEmpty else { return }
        catchUpTask = Task { @MainActor [self] in
            defer {
                if NanoMuseAccountData.shared.generation == generation {
                    catchUpTask = nil
                    let attempted = Set(due.map(\.id))
                    if routines.contains(where: { $0.pendingRun != nil && !attempted.contains($0.id) }) { catchUp(reason: "command") }
                }
            }
            for r in due {
                guard !Task.isCancelled, NanoMuseAccountData.shared.generation == generation else { return }
                _ = await run(r.id, trigger: reason)
            }
        }
    }

    /// Run one routine now (from the UI or the catch-up). Returns whether the turn finished without an error.
    @discardableResult
    func run(_ id: String, trigger: String = "manual") async -> Bool {
        let account = NanoMuseAccountData.shared
        guard !account.isChangingAccount, !NivoPersonalBackupAccess.isBusy, UIApplication.shared.applicationState == .active,
              var r = routine(id: id), !running.contains(id) else { return false }
        let owner = account.current
        let generation = account.generation
        // 旧训练已成为只读档案，启动补跑也不能抢在页面迁移前重新出题。
        if id == NanoMuseFeedFlow.routineId, r.hidden, r.sessionId == NanoMuseFeedFlow.sessionId {
            if r.enabled { setEnabled(id, false) }
            return false
        }
        running.insert(id)
        defer { if account.generation == generation { running.remove(id) } }
        // 请求交接和开始记录先一同落盘，崩溃后只恢复尚未开始的请求。
        let startedAt = Date()
        let startedUptime = ProcessInfo.processInfo.systemUptime
        let dryNotify = r.pendingRun?.dryNotify ?? false
        r = NivoRoutineRunRules.starting(r, now: startedAt, trigger: trigger)
        guard let started = r.runs.first, let runID = started.id else { return false }
        do { _ = try saveRoutine(r, creating: false, isExecutionUpdate: true) }
        catch { persistenceError = error.localizedDescription; return false }

        let outcome = await executeRoutine(r, generation: generation)
        guard account.current == owner, account.generation == generation, !account.isChangingAccount,
              var fresh = routine(id: id), let runIndex = fresh.runs.firstIndex(where: { $0.id == runID }) else { return false }
        let result = NivoRoutineRunRules.boundedResult(outcome.text)
        fresh.runs[runIndex] = NanoMuseRoutine.Run(at: startedAt, ok: outcome.ok, note: outcome.note.map { String($0.prefix(4_096)) },
            id: runID, sessionId: outcome.sessionId, finishedAt: Date(),
            duration: max(0, ProcessInfo.processInfo.systemUptime - startedUptime), trigger: started.trigger,
            result: result.text, status: outcome.ok ? "completed" : "failed", scheduledFor: started.scheduledFor,
            resultTruncated: result.truncated || outcome.resultTruncated,
            exitCode: outcome.exitCode, reportedStatus: outcome.reportedStatus, resultSource: outcome.resultSource,
            scriptDigest: outcome.scriptDigest, verifiedOutcome: outcome.verifiedOutcome, stdoutBytes: outcome.stdoutBytes,
            isDebug: r.debug, stdoutPreview: outcome.stdoutPreview, deliveryError: outcome.deliveryError)
        fresh.runs[runIndex].notification = NivoRoutineNotificationRules.decide(row: fresh, run: fresh.runs[runIndex],
            allRows: routines, settings: notificationSettings, now: Date(), dryNotify: dryNotify)
        let receipt = NivoRoutineSettlement(routineID: fresh.id, routineCreatedAt: fresh.createdAt, run: fresh.runs[runIndex])
        do {
            try NivoRoutineSettlementFiles.stage(receipt, directory: settlementsDirectory)
            try persist(receipt.applying(to: routines))
            clearSettlement(receipt)
            guard let committed = routine(id: id) else { return false }
            fresh = committed
        }
        catch { persistenceError = error.localizedDescription; return false }
        await deliverResult(fresh, runID: runID, generation: generation)
        guard account.generation == generation, !account.isChangingAccount else { return false }
        NanoMuseRoutineEvents.finished.send((fresh, outcome))
        return outcome.ok
    }

    /// 专属会话创建失败也进入统一结算，不留下永远显示运行中的记录。
    private func executeRoutine(_ row: NanoMuseRoutine, generation: UInt64) async -> NanoMuseHeadless.Outcome {
        do {
            try await NivoRoutineTargetValidation.validate(row, generation: generation)
            let dedicated = NivoRoutineConversationRules.usesDedicatedConversation(row)
            let sessionID: String?
            if dedicated {
                sessionID = try await NivoRoutineConversationCoordinator.session(routineID: row.id, generation: generation)
            } else { sessionID = row.execution?.target == .newSession ? nil : row.sessionId }
            if row.script != nil {
                let executionID = sessionID ?? ("nm-task-run-" + row.id)
                return await NivoScheduledScriptRuntime.run(row, sessionID: executionID, generation: generation)
            }
            let execution = dedicated ? (row.execution ?? NivoRoutineExecution()) : row.execution
            return await NanoMuseHeadless.run(prompt: prompt(for: row), sessionId: sessionID, title: row.label,
                source: NivoRoutineConversationRules.source, routine: row.label, execution: execution,
                requiresExistingSession: dedicated, scheduledTaskID: row.id, scheduledRunID: row.runs.first?.id)
        } catch {
            return NanoMuseHeadless.Outcome(ok: false, sessionId: nil, text: "", note: error.localizedDescription)
        }
    }

    private func clearSettlement(_ receipt: NivoRoutineSettlement) {
        do { try NivoRoutineSettlementFiles.clear(receipt, directory: settlementsDirectory) }
        catch { persistenceError = error.localizedDescription }
    }

    private func prompt(for r: NanoMuseRoutine) -> String {
        if let goalId = r.goalId, let goal = NanoMuseGoalStore.shared.goal(id: goalId) {
            return NanoMuseGoalFlow.checkPrompt(goal)
        }
        return r.prompt
    }

    // MARK: Notifications

    /// One pending calendar notification per enabled routine, at its next time: "open to run it".
    func refreshNotifications() {
        notificationsTask?.cancel()
        let generation = NanoMuseAccountData.shared.generation
        let batchID = UUID().uuidString
        notificationsTask = Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            guard !Task.isCancelled, let self, NanoMuseAccountData.shared.generation == generation else { return }
            let ours = pending.filter { $0.identifier.hasPrefix("nanomuse-routine-") }.map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: ours)
            let now = Date()
            // iOS keeps 64 pending requests per app; the soonest routines get the slots.
            let soon = self.routines
                .flatMap { r in NivoRoutineScheduleRules.notificationDates(r, after: now).map { (r, $0) } }
                .sorted { $0.1 < $1.1 }
                .prefix(20)
            for (r, at) in soon {
                guard !Task.isCancelled, NanoMuseAccountData.shared.generation == generation else { return }
                let content = self.notificationContent(for: r, at: at)
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let identifier = "nanomuse-routine-\(batchID)-\(r.id)-\(Int(at.timeIntervalSince1970))"
                try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                if Task.isCancelled || NanoMuseAccountData.shared.generation != generation {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    return
                }
            }
        }
    }

    private func postDueNotification(_ r: NanoMuseRoutine, at now: Date) {
        let content = notificationContent(for: r, at: now)
        let due = r.nextDue(after: now) ?? now
        let request = UNNotificationRequest(identifier: "nanomuse-due-\(r.id)-\(Int(due.timeIntervalSince1970))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func notificationContent(for r: NanoMuseRoutine, at date: Date) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if let goalId = r.goalId, let goal = NanoMuseGoalStore.shared.goal(id: goalId) {
            content.title = String(format: AppLocalized("Check-in: %@"), goal.title)
        } else {
            content.title = r.label.isEmpty ? AppLocalized("Routine") : r.label
        }
        content.body = AppLocalized("Open nanoMuse to run it. The phone cannot run the agent while the app is asleep.")
        if !NivoRoutineNotificationRules.isQuiet(notificationSettings.quietHours, at: date) { content.sound = .default }
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = ["nanomuse.routine": r.id, "nivoRoom": "routines"]
        return content
    }

    /// 每个任务使用固定通知ID；系统成功接收后才记录提交时间，权限拒绝不算已经通知。
    private func deliverResult(_ row: NanoMuseRoutine, runID: String, generation: UInt64) async {
        guard let run = row.runs.first(where: { $0.id == runID }), run.notification?.shouldNotify == true else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard NanoMuseAccountData.shared.generation == generation, !NanoMuseAccountData.shared.isChangingAccount,
              routine(id: row.id) != nil else { return }
        var decision = run.notification!
        let identifier = "nanomuse-result-" + row.id
        if [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
            let content = UNMutableNotificationContent()
            content.title = row.execution?.notification?.title ?? row.label
            let body = NivoRoutineNotificationRules.normalized(run.result ?? "")
            content.body = String((body.isEmpty ? (run.note ?? AppLocalized(run.ok ? "Completed" : "Failed")) : body).prefix(2_000))
            if decision.silentReason == nil { content.sound = .default }
            content.categoryIdentifier = Self.notificationCategory
            content.threadIdentifier = "nanomuse-routine-results"
            content.userInfo = ["nanomuse.routine": row.id, "nivoRoom": "routines"]
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                decision.submittedAt = Date()
            } catch { decision.deliveryError = String(error.localizedDescription.prefix(300)) }
        } else { decision.deliveryError = "notification_permission_denied" }
        guard NanoMuseAccountData.shared.generation == generation, !NanoMuseAccountData.shared.isChangingAccount else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            return
        }
        guard var current = routine(id: row.id), let index = current.runs.firstIndex(where: { $0.id == runID }) else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            return
        }
        current.runs[index].notification = decision
        do { _ = try saveRoutine(current, creating: false, isExecutionUpdate: true) }
        catch { persistenceError = error.localizedDescription }
    }

    /// Ask once; iOS keeps the answer.
    func requestNotificationPermission() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }
}

// MARK: - Events

enum NanoMuseRoutineEvents {
    /// A routine finished; the feed and the goals listen.
    static let finished = NanoMuseSignal<(NanoMuseRoutine, NanoMuseHeadless.Outcome)>()
}

/// A tiny broadcaster: observers by id, no Combine.
final class NanoMuseSignal<Value> {
    private var handlers: [UUID: (Value) -> Void] = [:]

    @discardableResult
    func observe(_ handler: @escaping (Value) -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func cancel(_ id: UUID) { handlers[id] = nil }

    func send(_ value: Value) { handlers.values.forEach { $0(value) } }
}

// MARK: - Headless runs

/// Runs one prompt in a session with the app's own chat pipeline and waits
/// for the turn to end — what the Shortcuts intents do (`QuickTaskIntent`).
enum NanoMuseHeadless {
    @MainActor private static var active: [UUID: AIChatViewModel] = [:]

    /// 账户文件迁移前取消由定时任务发起的执行，旧结果不能写回新账户。
    @MainActor static func cancelForAccountChange() {
        for model in active.values { model.cancel() }
        active.removeAll()
    }
    struct Outcome {
        var ok: Bool
        var sessionId: String?
        var text: String
        var note: String?
        var exitCode: Int?
        var reportedStatus: String?
        var resultSource: String?
        var scriptDigest: String?
        var verifiedOutcome: String?
        var stdoutBytes: Int64?
        var resultTruncated = false
        var stdoutPreview: String?
        var deliveryError: String?
    }

    /// Creates the session when `sessionId` is nil or gone; the turn's last assistant text comes back.
    /// With `routine` (the routine's label) the turn is marked as the routine's, not the person's:
    /// its row is a quiet line in the chat and the model is told so for this one turn
    /// (`NanoMuseRoutineWakes`).
    @MainActor
    static func run(prompt: String, sessionId: String?, title: String?, source: String, routine: String? = nil,
                    execution: NivoRoutineExecution? = nil, timeout: TimeInterval = 10 * 60,
                    requiresExistingSession: Bool = false, scheduledTaskID: String? = nil, scheduledRunID: String? = nil) async -> Outcome {
        await NanoMuseAccountData.shared.start()
        let owner = NanoMuseAccountData.shared.current
        let generation = NanoMuseAccountData.shared.generation
        func isCurrent() -> Bool {
            !Task.isCancelled && !NanoMuseAccountData.shared.isChangingAccount
                && NanoMuseAccountData.shared.current == owner && NanoMuseAccountData.shared.generation == generation
        }
        func unavailable(_ session: String?) -> Outcome {
            Outcome(ok: false, sessionId: session, text: "", note: AppLocalized("The account changed. Open this page again."))
        }
        guard isCurrent(), !NivoPersonalBackupAccess.isBusy else { return unavailable(sessionId) }
        guard ProviderConfigStore.shared.defaultPrimaryGroupId != nil || !ProviderConfigStore.shared.modelEntries.isEmpty else {
            return Outcome(ok: false, sessionId: sessionId, text: "", note: AppLocalized("Add a model first; routines are run by your agent."))
        }
        let vm: AIChatViewModel
        var sid = sessionId
        if let sid, await ChatStore.shared.sessionExists(id: sid) {
            guard isCurrent(), NanoMuseAccountData.shared.shows(sid) else { return unavailable(sid) }
            let cached = ViewModelCache.shared.getOrCreate(for: sid)
            vm = cached.vm
            if cached.isNew { await vm.loadSession() }
        } else {
            guard isCurrent() else { return unavailable(sid) }
            if requiresExistingSession || (execution != nil && execution?.target != .newSession) {
                return Outcome(ok: false, sessionId: sid, text: "", note: AppLocalized("This item no longer exists. Reload the list."))
            }
            vm = ViewModelCache.shared.createDraft()
            vm.sessionSource = source
            vm.suppressGeneralCompletionNotification = true
            let created = await vm.ensureSessionReturningId()
            guard isCurrent() else { return unavailable(created) }
            if let title, !title.isEmpty {
                await ChatStore.shared.updateSessionTitle(created, title: String(title.prefix(60)))
            }
            ViewModelCache.shared.cacheDraft(vm, sessionId: created)
            sid = created
        }
        let deadline = Date().addingTimeInterval(timeout)
        while vm.isProcessing && Date() < deadline && isCurrent() {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard isCurrent() else { return unavailable(sid) }
        guard !vm.isProcessing else { return Outcome(ok: false, sessionId: sid, text: "", note: AppLocalized("Took too long")) }
        // 自动运行不覆盖目标对话中尚未发送的草稿、附件和排队消息。
        guard vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              vm.attachments.isEmpty, vm.promptQueue.isEmpty, vm.pendingSendText == nil else {
            return Outcome(ok: false, sessionId: sid, text: "", note: AppLocalized("Send or clear the conversation draft before running this routine."))
        }
        do {
            if let sid, let execution { try await NivoRoutineModelBinding.apply(execution, sessionID: sid, model: vm) }
            else { try NivoRoutineModelBinding.requireUsable(vm.resolveCurrentEntry(), store: .shared) }
        } catch {
            return Outcome(ok: false, sessionId: sid, text: "", note: error.localizedDescription)
        }
        guard isCurrent() else { return unavailable(sid) }
        guard vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              vm.attachments.isEmpty, vm.promptQueue.isEmpty, vm.pendingSendText == nil else {
            return Outcome(ok: false, sessionId: sid, text: "", note: AppLocalized("Send or clear the conversation draft before running this routine."))
        }
        guard !vm.isProcessing, !vm.isTruncatingForRetry else {
            return Outcome(ok: false, sessionId: sid, text: "", note: AppLocalized("Could not start the routine. Try again."))
        }
        let lease: NivoScheduledRunScopes.Lease?
        do {
            if let scheduledTaskID, let scheduledRunID, let sid {
                lease = try NivoScheduledRunScopes.shared.enter(taskID: scheduledTaskID, runID: scheduledRunID,
                    sessionID: sid, owner: owner, isScript: false)
            } else { lease = nil }
        } catch { return Outcome(ok: false, sessionId: sid, text: "", note: error.localizedDescription) }
        vm.nmScheduledRunID = lease?.runID
        defer {
            vm.nmScheduledRunID = nil
            if let lease { NivoScheduledRunScopes.shared.leave(lease) }
        }
        let runID = UUID()
        active[runID] = vm
        let previousNotificationMode = vm.suppressGeneralCompletionNotification
        vm.suppressGeneralCompletionNotification = true
        defer {
            active.removeValue(forKey: runID)
            vm.suppressGeneralCompletionNotification = previousNotificationMode
        }
        let wake = routine.map { NanoMuseRoutineWakes.Wake(label: String($0.trimmingCharacters(in: .whitespaces).prefix(60)), at: Date()) }
        if let wake, let session = sid {
            NanoMuseSessionAddenda.add(session: session, tag: NanoMuseRoutineWakes.addendumTag, text: NanoMuseRoutineWakes.framing(label: wake.label, at: wake.at), turns: 1)
        }
        if let lease {
            NanoMuseSessionAddenda.add(session: lease.sessionID, tag: "scheduled-report",
                text: "This is a scheduled task. After doing the work, use minis-scheduled report --status success or --status failure --reason TEXT only when the outcome is verified. You may hand over a concise result with --result TEXT. Do not invent completion. If uncertain, leave the status unreported. The final response contains the useful result, not report receipts. Reply NO_OUTPUT when there is nothing to show.", turns: 1)
        }
        defer { if let lease { NanoMuseSessionAddenda.remove(session: lease.sessionID, tag: "scheduled-report") } }
        if execution?.target == .rerun {
            guard let messageID = execution?.messageID, let id = UUID(uuidString: messageID),
                  vm.messages.contains(where: { $0.id == id && $0.role == .user }) else {
                if let sid { NanoMuseSessionAddenda.remove(session: sid, tag: NanoMuseRoutineWakes.addendumTag) }
                return Outcome(ok: false, sessionId: sid, text: "", note: AppLocalized("This item no longer exists. Reload the list."))
            }
            vm.retryFromMessage(id, scheduledRunID: lease?.runID)
            while vm.isTruncatingForRetry && !vm.isProcessing && isCurrent() && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        } else {
            vm.inputText = prompt
            vm.send(scheduledRunID: lease?.runID)
        }
        guard vm.isProcessing else {
            if let session = sid { NanoMuseSessionAddenda.remove(session: session, tag: NanoMuseRoutineWakes.addendumTag) }
            return Outcome(ok: false, sessionId: sid, text: "", note: vm.errorMessage ?? AppLocalized("Could not start the routine. Try again."))
        }
        // `send` appends the user row before it suspends: mark it now, so it is drawn as the
        // routine's line from its first frame and remembered under its row id once persisted.
        // A send that did not start (the guard in `send`) leaves no mark and no framing.
        if let wake, let session = sid {
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if vm.isProcessing, let row = vm.messages.last(where: { $0.role == .user }), row.nmRoutine == nil, row.content == trimmed {
                row.nmRoutine = wake
            } else if !vm.isProcessing {
                NanoMuseSessionAddenda.remove(session: session, tag: NanoMuseRoutineWakes.addendumTag)
            }
        }
        // Wait for the loop to end, with a ceiling.
        var finished = !vm.isProcessing
        while !finished && Date() < deadline && isCurrent() {
            try? await Task.sleep(nanoseconds: 500_000_000)
            finished = !vm.isProcessing
        }
        guard isCurrent() else { vm.cancel(); return unavailable(sid) }
        if !finished { vm.cancel() }
        let report = lease.flatMap { NivoScheduledRunScopes.shared.snapshot($0) } ?? NivoScheduledReport()
        let text = report.result ?? SendPromptIntent.extractResponseText(from: vm)
        let failed = vm.errorMessage != nil || vm.messages.last?.error != nil || !finished || vm.userDidCancel
        let verified = report.outcome(failed: failed, scriptExit: nil, outputRequired: false, hasOutput: !text.isEmpty)
        let note = failed ? (vm.errorMessage ?? (finished ? nil : AppLocalized("Took too long"))) : report.reason
        return Outcome(ok: verified != "failure", sessionId: sid ?? vm.sessionId, text: text, note: note,
            reportedStatus: report.status, resultSource: report.result == nil ? "final_message" : "self_report", verifiedOutcome: verified)
    }
}
