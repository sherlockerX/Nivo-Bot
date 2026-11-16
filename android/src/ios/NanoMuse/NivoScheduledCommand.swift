import Foundation

/// minis-scheduled的参数保持argv边界，不做shell拼接、展开或隐式脚本执行。
struct NivoScheduledCommand: Sendable {
    var action: String
    var options: [String: [String]]

    var isReadOnly: Bool { ["list", "logs", "probe"].contains(action) || (action == "settings" && options.isEmpty) }
    func value(_ key: String) -> String? { options[key]?.first }

    /// 只接受已实现的选项；脚本与提示词必须由调用方明确选择。
    static func parse(_ arguments: [String]) throws -> Self {
        guard arguments.count <= 100, arguments.reduce(0, { $0 + $1.utf8.count }) <= 120_000 else {
            throw NivoLifeError.invalidField("arguments")
        }
        let aliases = ["add": "create", "remove": "delete", "rm": "delete"]
        let requestedAction = arguments.first ?? "list"
        let action = aliases[requestedAction] ?? requestedAction
        let actions: Set<String> = ["list", "create", "update", "delete", "enable", "disable", "run", "logs", "probe", "settings", "report"]
        guard actions.contains(action) else { throw NivoLifeError.invalidField("action") }
        let flags: Set<String> = ["disabled", "auto-disable-on-failure", "silent", "dry-notify", "require-output", "log-stdout", "debug", "session-output"]
        var options: [String: [String]] = [:]
        var index = 1
        while index < arguments.count {
            let token = arguments[index]
            guard token.hasPrefix("--") else { throw NivoLifeError.invalidField("option") }
            let parts = token.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, !first.isEmpty else { throw NivoLifeError.invalidField("option") }
            let name = String(first)
            guard allowed(action).contains(name), ["time", "script-arg"].contains(name) || options[name] == nil else {
                throw NivoLifeError.invalidField("unsupported_or_duplicate_option:" + name)
            }
            index += 1
            if flags.contains(name) {
                let value = parts.count == 2 ? String(parts[1]) : "true"
                guard ["true", "false"].contains(value) else { throw NivoLifeError.invalidField(name) }
                options[name] = [value]
                continue
            }
            if parts.count == 2 { options[name, default: []].append(String(parts[1])); continue }
            guard index < arguments.count else { throw NivoLifeError.invalidField(name) }
            options[name, default: []].append(arguments[index])
            index += 1
        }
        return Self(action: action, options: options)
    }

    /// 创建与修改共用配置校验；未提供的修改字段保持不变。
    func applying(to original: NanoMuseRoutine?, now: Date = Date()) throws -> NanoMuseRoutine {
        var row = original ?? NanoMuseRoutine(label: value("label") ?? "", prompt: "", hour: 9, minute: 0,
                                              repeatMode: .once, createdAt: now)
        var schedule = row.schedule ?? NivoRoutineSchedule()
        var execution = row.execution ?? NivoRoutineExecution(target: row.sessionId == nil ? .newSession : .append)
        if let label = value("label") { row.label = label }
        if let prompt = value("prompt") { row.prompt = prompt }
        try applyScript(to: &row)
        if let raw = options["time"] {
            schedule.times = try raw.map {
                guard let parsed = NivoRoutineTime.parse($0) else { throw NivoLifeError.invalidField("time") }
                return parsed
            }.sorted()
            guard let first = schedule.times.first else { throw NivoLifeError.invalidField("time") }
            row.hour = first.hour
            row.minute = first.minute
        } else if original == nil { throw NivoLifeError.invalidField("time_required") }
        if let mode = value("repeat") {
            guard let repeatMode = NanoMuseRoutine.Repeat(rawValue: mode) else { throw NivoLifeError.invalidField("repeat") }
            row.repeatMode = repeatMode
        }
        if let days = value("days") { schedule.customDays = try parseDays(days) }
        if let start = value("start") { schedule.startDay = try NivoJigsawQuery.day(start) }
        if let end = value("end") { schedule.endDay = try NivoJigsawQuery.day(end) }
        if let interval = value("interval-minutes") {
            guard let minutes = Int(interval) else { throw NivoLifeError.invalidField("interval_minutes") }
            schedule.intervalMinutes = minutes
        }
        if let target = value("target") {
            let targets: [String: NivoRoutineExecution.Target] = ["new": .newSession, "follow-up": .append, "rerun": .rerun]
            guard let selected = targets[target] else { throw NivoLifeError.invalidField("target") }
            execution.target = selected
        }
        if let session = value("session") { row.sessionId = session }
        if let message = value("message") { execution.messageID = message }
        if execution.target == .newSession { row.sessionId = nil }
        if let entry = value("model") { execution.modelKind = .entry; execution.modelID = entry }
        if let group = value("model-group") {
            guard value("model") == nil else { throw NivoLifeError.invalidField("model") }
            execution.modelKind = .group
            execution.modelID = group
        }
        if let disabled = value("disabled") { row.enabled = disabled != "true" }
        if let autoDisable = value("auto-disable-on-failure") { execution.autoDisableOnFailure = autoDisable == "true" }
        if let raw = value("failure-threshold") {
            guard let count = Int(raw) else { throw NivoLifeError.invalidField("failure_threshold") }
            execution.failureThreshold = count
        }
        execution.notification = try notificationOptions(previous: execution.notification)
        row.schedule = schedule
        row.execution = execution
        if row.label.isEmpty { row.label = row.script?.id ?? String(row.prompt.prefix(40)) }
        try NivoRoutineScheduleRules.validate(row)
        return row
    }

    private func applyScript(to row: inout NanoMuseRoutine) throws {
        if let id = value("script") { row.script = NivoRoutineScript(id: id) }
        if let arguments = options["script-arg"] {
            guard row.script != nil else { throw NivoLifeError.invalidField("SCRIPT_REQUIRED") }
            row.script?.arguments = arguments
        }
        if let requireOutput = value("require-output") {
            guard row.script != nil else { throw NivoLifeError.invalidField("SCRIPT_REQUIRED") }
            row.script?.requireOutput = requireOutput == "true"
        }
        if let logStdout = value("log-stdout") {
            guard row.script != nil else { throw NivoLifeError.invalidField("SCRIPT_REQUIRED") }
            row.script?.logStdout = logStdout == "true"
        }
        if let debug = value("debug") { row.debug = debug == "true" }
        if let sessionOutput = value("session-output") { row.sessionOutput = sessionOutput == "true" }
    }

    private func notificationOptions(previous: NivoRoutineNotificationOptions?) throws -> NivoRoutineNotificationOptions? {
        guard value("notify") != nil || value("notify-title") != nil || value("silent") != nil else { return previous }
        var options = previous ?? NivoRoutineNotificationOptions()
        if let raw = value("notify") {
            guard let policy = NivoRoutineNotificationOptions.Policy(rawValue: raw) else { throw NivoLifeError.invalidField("notify") }
            options.policy = policy
        }
        if let title = value("notify-title") { options.title = title.isEmpty ? nil : title }
        if let silent = value("silent") { options.isSilent = silent == "true" }
        return options
    }

    private func parseDays(_ raw: String) throws -> [Int] {
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let values = try raw.split(separator: ",", omittingEmptySubsequences: false).map { text -> Int in
            guard let index = names.firstIndex(of: text.trimmingCharacters(in: .whitespaces).lowercased()) else {
                throw NivoLifeError.invalidField("days")
            }
            return index + 1
        }
        return Array(Set(values)).sorted()
    }

    private static func allowed(_ action: String) -> Set<String> {
        if action == "list" { return [] }
        if action == "settings" { return ["quiet-hours"] }
        if action == "report" { return ["status", "reason", "result"] }
        if action == "logs" { return ["id", "last", "since", "format"] }
        if action == "run" { return ["id", "expected-revision", "dry-notify"] }
        if ["create", "update"].contains(action) {
            return ["id", "expected-revision", "label", "prompt", "time", "repeat", "days", "target", "session", "message",
                    "model", "model-group", "start", "end", "disabled", "auto-disable-on-failure", "failure-threshold", "interval-minutes",
                    "notify", "notify-title", "silent", "script", "script-arg", "require-output", "log-stdout", "debug", "session-output"]
        }
        return ["id", "expected-revision"]
    }
}
