import Foundation
import UIKit

/// 原生定时任务命令绑定内核会话和当前账户，权限弹窗期间切换账户会撤销本次操作。
@objc(NivoScheduledOffloadBridge)
final class NivoScheduledOffloadBridge: NSObject {
    @objc static func execute(arguments: [String], context: UInt64,
                              completion: @escaping @Sendable (String, Int32) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + 55
        Task { @MainActor in
            do {
                let command = try NivoScheduledCommand.parse(arguments)
                if command.action == "report" {
                    let response = try report(command, context: context)
                    completion(response, 0)
                    return
                }
                let account = NanoMuseAccountData.shared
                let generation = account.generation
                guard let sessionID = MinisFsRouter.shared.sid(for: context) else { throw NivoLifeError.accountChanged }
                try requireCurrent(sessionID: sessionID, generation: generation, deadline: deadline)
                let permission = await OffloadPermissionManager.shared.checkPermission(for: "minis-scheduled",
                    sessionId: sessionID, fullCommand: "minis-scheduled " + arguments.joined(separator: " "))
                guard case .allowed = permission else { throw NivoScheduledExecutionError.permissionDenied }
                try requireCurrent(sessionID: sessionID, generation: generation, deadline: deadline)
                let result = try await handle(command, generation: generation) {
                    try requireCurrent(sessionID: sessionID, generation: generation, deadline: deadline)
                }
                try requireCurrent(sessionID: sessionID, generation: generation, deadline: deadline)
                if command.action == "logs", command.value("format") == "text", let text = result["text"] as? String {
                    completion(text + "\n", 0)
                    return
                }
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                completion(String(decoding: data, as: UTF8.self) + "\n", 0)
            } catch {
                let isArgumentError: Bool
                if let lifeError = error as? NivoLifeError, case .invalidField = lifeError { isArgumentError = true }
                else { isArgumentError = false }
                completion(NivoLifeToolFailure.output(error) + "\n", isArgumentError ? 2 : 1)
            }
        }
    }

    @MainActor private static func report(_ command: NivoScheduledCommand, context: UInt64) throws -> String {
        let account = NanoMuseAccountData.shared
        guard let lease = NivoScheduledRunScopes.shared.lease(context: context), account.isReady,
              !account.isChangingAccount, account.current == lease.owner, !NivoPersonalBackupAccess.isBusy else {
            throw NivoLifeError.invalidField("NOT_IN_TASK_RUN")
        }
        let report = try NivoScheduledRunScopes.shared.report(context: context, status: command.value("status"),
            reason: command.value("reason"), result: command.value("result"))
        if lease.isScript { return "" }
        let response: [String: Any] = ["accepted": true, "outcome": report.status ?? "unknown",
            "result_bytes": report.result?.utf8.count ?? 0]
        return String(decoding: try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }

    @MainActor private static func requireCurrent(sessionID: String, generation: UInt64, deadline: TimeInterval) throws {
        let account = NanoMuseAccountData.shared
        guard account.isReady, !account.isChangingAccount, account.generation == generation, account.shows(sessionID),
              UIApplication.shared.applicationState == .active, !NivoPersonalBackupAccess.isBusy,
              ProcessInfo.processInfo.systemUptime < deadline else { throw NivoLifeError.accountChanged }
    }

    @MainActor private static func handle(_ command: NivoScheduledCommand, generation: UInt64,
                                          revalidate: @MainActor () throws -> Void) async throws -> [String: Any] {
        guard generation == NanoMuseAccountData.shared.generation, !NanoMuseAccountData.shared.isChangingAccount else {
            throw NivoLifeError.accountChanged
        }
        let scheduler = NanoMuseScheduler.shared
        try scheduler.requireReadable()
        if command.action == "settings" {
            if let value = command.value("quiet-hours") { try scheduler.setQuietHours(value) }
            return ["quiet_hours": scheduler.notificationSettings.quietHours]
        }
        if command.action == "list" {
            return ["tasks": try scheduler.routines.map(json), "count": scheduler.routines.count,
                    "view_url": "minis://settings/routines", "execution": "foreground_only"]
        }
        if command.action == "create" {
            var row = try command.applying(to: nil)
            if let id = command.value("id") {
                guard UUID(uuidString: id) != nil else { throw NivoLifeError.invalidField("id") }
                row.id = id
            }
            if row.enabled { try await NivoRoutineTargetValidation.validate(row, generation: generation) }
            try revalidate()
            let saved = try scheduler.saveRoutine(row, creating: true)
            return ["created": try json(saved)]
        }
        guard let id = command.value("id"), let row = scheduler.routine(id: id) else { throw NivoLifeError.notFound("routine") }
        if command.action == "logs" { return try logs(row, command: command) }
        if command.action == "probe" {
            do { try await NivoRoutineTargetValidation.validate(row, generation: generation); try revalidate() }
            catch { return ["can_run": false, "error": String(describing: error), "execution": "foreground_only"] }
            var checked: [String: Any] = ["can_run": !scheduler.running.contains(id) && row.pendingRun == nil
                && scheduler.routine(id: id)?.revision == row.revision,
                "revision": row.revision ?? 0, "execution": "foreground_only", "mode": row.script == nil ? "prompt" : "script"]
            if let script = row.script {
                checked["script"] = script.id
                checked["interpreter"] = script.interpreter
                checked["approval"] = "checked_at_run"
            }
            return checked
        }
        // 写入前必须使用刚查询的版本，终端与页面同时编辑不会互相覆盖。
        guard let expected = command.value("expected-revision").flatMap(Int64.init), expected == (row.revision ?? 0) else {
            throw NivoLifeError.staleRevision(expected: command.value("expected-revision").flatMap(Int64.init) ?? -1, actual: row.revision ?? 0)
        }
        if command.action == "run" {
            try await NivoRoutineTargetValidation.validate(row, generation: generation)
            try revalidate()
            guard let current = scheduler.routine(id: id), current.revision == row.revision else {
                throw NivoLifeError.staleRevision(expected: row.revision ?? 0, actual: scheduler.routine(id: id)?.revision ?? -1)
            }
            guard !scheduler.running.contains(id) else { throw NivoLifeError.operationConflict }
            let pending = try scheduler.enqueue(id, dryNotify: command.value("dry-notify") == "true")
            return ["id": id, "run_id": pending.id, "accepted": true, "status": "queued",
                    "revision": scheduler.routine(id: id)?.revision ?? 0,
                    "instruction": "Query logs for the actual result. Queued does not mean completed."]
        }
        if command.action == "delete" {
            try scheduler.removeRoutine(id, expectedRevision: row.revision ?? 0)
            return ["deleted": id]
        }
        var updated = row
        if command.action == "update" { updated = try command.applying(to: row) }
        else { updated.enabled = command.action == "enable" }
        if updated.enabled { try await NivoRoutineTargetValidation.validate(updated, generation: generation) }
        try revalidate()
        return ["updated": try json(scheduler.saveRoutine(updated, creating: false))]
    }

    private static func json(_ row: NanoMuseRoutine) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var object = try JSONSerialization.jsonObject(with: encoder.encode(row)) as? [String: Any] ?? [:]
        object.removeValue(forKey: "runs")
        object["run_count"] = row.runs.count
        object["revision"] = row.revision ?? 0
        object["nextDueAt"] = row.nextDue(after: Date()).map { $0.timeIntervalSince1970 * 1_000 as Any } ?? NSNull()
        return object
    }

    private static func logs(_ row: NanoMuseRoutine, command: NivoScheduledCommand) throws -> [String: Any] {
        guard let limit = Int(command.value("last") ?? "20"), (1...1_000).contains(limit),
              [nil, "json", "text"].contains(command.value("format")) else { throw NivoLifeError.invalidField("logs_options") }
        let since: Date?
        if let raw = command.value("since") {
            if let date = ISO8601DateFormatter().date(from: raw) { since = date }
            else { since = NivoLifeDay.date(try NivoJigsawQuery.day(raw)) }
        } else { since = nil }
        let rows = Array(row.runs.filter { since == nil || $0.at >= since! }.prefix(limit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var output: [String: Any] = ["id": row.id, "runs": try JSONSerialization.jsonObject(with: encoder.encode(rows)),
            "count": rows.count, "status": rows.isEmpty ? "empty" : "ok", "retention_limit": 50]
        if command.value("format") == "text" {
            output["text"] = rows.map { run in
                "\(ISO8601DateFormatter().string(from: run.at)) \(run.status ?? (run.ok ? "completed" : "failed")) run=\(run.id ?? "legacy")"
            }.joined(separator: "\n")
        }
        if let pending = row.pendingRun { output["pending"] = try JSONSerialization.jsonObject(with: encoder.encode(pending)) }
        return output
    }
}
