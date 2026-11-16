import Foundation
import UIKit

/// 预检只检查脚本快照、解释器和时区数据，实际执行前再次检查账户并请求版本审批。
@MainActor
enum NivoScheduledScriptRuntime {
    /// 检查现有文件和运行环境，不执行脚本，不连接模型供应商。
    @discardableResult
    static func probe(_ script: NivoRoutineScript, sessionID: String, generation: UInt64) async throws -> NivoScheduledTimezone {
        try requireCurrent(generation)
        try await prepareKernel()
        try requireCurrent(generation)
        try await ISHExecutionCoordinator.shared.prepareScheduled(sessionID: sessionID)
        // 旧rootfs中的脚本先迁入持久home，随后才冻结并检查正文。
        try requireCurrent(generation)
        _ = try await Task.detached(priority: .utility) { try NivoScheduledScriptFiles.read(script) }.value
        try requireCurrent(generation)
        let zone = try NivoScheduledTimezone(.current)
        var command = "test -x '" + script.interpreter + "' || exit 126"
        if let dataPath = zone.requiredDataPath {
            command += "; test -r '" + dataPath + "' || exit 127"
        }
        let checked = try await ISHExecutionCoordinator.shared.execute(sessionId: sessionID, command: command,
            timeout: 15, lineCallback: { _ in }, pidCallback: { _ in })
        try requireCurrent(generation)
        if checked.exitCode == 126 { throw NivoScheduledSetupError.interpreter }
        if checked.exitCode == 127 { throw NivoScheduledSetupError.timezone }
        guard checked.exitCode == 0 else { throw NivoLifeError.invalidField("SCRIPT_ENVIRONMENT_UNAVAILABLE") }
        return zone
    }

    /// 保存当前审批的同一正文并由真实退出码结算，不用模型生成执行结论。
    static func run(_ row: NanoMuseRoutine, sessionID: String, generation: UInt64) async -> NanoMuseHeadless.Outcome {
        let sessionless = row.debug == true && (row.execution?.target ?? .newSession) == .newSession
        var outcome = NanoMuseHeadless.Outcome(ok: false, sessionId: sessionless ? nil : sessionID, text: "", note: nil)
        do {
            guard let script = row.script, let runID = row.runs.first?.id else { throw NivoLifeError.invalidField("script_run") }
            let timezone = try await probe(script, sessionID: sessionID, generation: generation)
            let version = try await Task.detached(priority: .utility) { try NivoScheduledScriptFiles.read(script) }.value
            try requireCurrent(generation)
            guard !SessionActivityTracker.shared.resolvedActiveSessionIds.contains(sessionID),
                  ViewModelCache.shared.get(for: sessionID)?.isProcessing != true,
                  ViewModelCache.shared.get(for: sessionID)?.isTruncatingForRetry != true else { throw NivoLifeError.operationConflict }
            let lease = try NivoScheduledRunScopes.shared.enter(taskID: row.id, runID: runID, sessionID: sessionID,
                owner: NanoMuseAccountData.shared.current, isScript: true)
            defer { NivoScheduledRunScopes.shared.leave(lease) }
            try await NivoScheduledScriptApproval.shared.authorize(taskID: row.id, label: row.label, version: version, generation: generation)
            try requireCurrent(generation)
            guard UIApplication.shared.applicationState == .active else { throw CancellationError() }
            let result = try await NivoScheduledProcess.execute(version, lease: lease,
                trigger: row.runs.first?.trigger ?? "manual", timezone: timezone)
            try requireCurrent(generation)
            let report = NivoScheduledRunScopes.shared.snapshot(lease) ?? NivoScheduledReport()
            let stdout = NivoRoutineNotificationRules.normalized(result.stdout)
            let reported = report.result.map(NivoRoutineNotificationRules.normalized).flatMap { $0.isEmpty ? nil : $0 }
            let verified = report.outcome(failed: result.captureError != nil || result.timedOut, scriptExit: result.exitCode,
                outputRequired: script.requireOutput, hasOutput: result.stdoutBytes > 0)
            outcome.ok = verified != "failure"
            outcome.text = reported ?? stdout
            outcome.note = result.captureError ?? (result.timedOut ? AppLocalized("Took too long") : nil)
                ?? (verified == "failure" ? report.reason ?? (result.stderr.isEmpty ? "SCRIPT_RUN_FAILED" : result.stderr) : nil)
            outcome.exitCode = result.exitCode
            outcome.verifiedOutcome = verified
            outcome.reportedStatus = report.status
            outcome.resultSource = reported == nil ? (stdout.isEmpty ? "none" : "script_stdout") : "self_report"
            outcome.scriptDigest = version.digest
            outcome.resultTruncated = reported == nil && result.truncated
            outcome.stdoutBytes = result.stdoutBytes
            outcome.stdoutPreview = script.logStdout ? result.stdout : nil
            if !sessionless {
                do {
                    try await ChatStore.shared.nmAppendRoutineOutput(sessionID: sessionID, runID: runID, label: row.label,
                        output: outcome.text.isEmpty ? AppLocalized("The script produced no output.") : outcome.text,
                        error: outcome.note)
                    try requireCurrent(generation)
                    ViewModelCache.shared.markStale(sessionId: sessionID)
                    if let model = ViewModelCache.shared.get(for: sessionID), !model.isProcessing {
                        await model.reloadMessagesFromDB(reason: "scheduled-script")
                    }
                } catch {
                    // 原生结果仍进入结算收据，聊天保存失败不重写真实退出码或重新执行脚本。
                    outcome.deliveryError = String(error.localizedDescription.prefix(4_096))
                }
            }
        } catch {
            outcome.ok = false
            outcome.verifiedOutcome = "failure"
            outcome.note = error.localizedDescription
        }
        return outcome
    }

    private static func requireCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation()
        let account = NanoMuseAccountData.shared
        guard account.isReady, account.generation == generation, !account.isChangingAccount,
              !NivoPersonalBackupAccess.isBusy else { throw NivoLifeError.accountChanged }
    }

    private static func prepareKernel() async throws {
        if ISHKernel.shared.isBooted { return }
        let helper = ViewModelCache.shared.createDraft()
        helper.ensureKernelBooted()
        let deadline = ProcessInfo.processInfo.systemUptime + 60
        while !ISHKernel.shared.isBooted {
            try Task.checkCancellation()
            if case .failed(let reason) = helper.kernelStatus { throw NivoLifeError.invalidField(reason) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NivoLifeError.invalidField("KERNEL_START_TIMEOUT") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

/// 独立argv执行器，结束、超时和取消竞争时只交付一次结果。
enum NivoScheduledProcess {
    /// 只在本次进程注入任务标识，可信上报仍以宿主的内核context为依据。
    static func execute(_ version: NivoScheduledScriptVersion, lease: NivoScheduledRunScopes.Lease,
                        trigger: String, timezone: NivoScheduledTimezone,
                        timeout: TimeInterval = 600) async throws -> NivoScheduledProcessResult {
        let context = MinisFsRouter.shared.executionContext(for: lease.sessionID)
        defer {
            NivoScheduledRunScopes.shared.unbind(context: context)
            MinisFsRouter.shared.releaseExecutionContext(context)
        }
        try NivoScheduledRunScopes.shared.bind(context: context, to: lease)
        let state = NivoScheduledProcessWaiter { _ in
            ISHShellExecutor.cancelExecutionContext(context)
        }
        let environmentStore = await MainActor.run { EnvVarStore.shared }
        var environment = try environmentStore.allAsDict()
        environment["HOME"] = "/var/minis/home"
        environment["TZ"] = timezone.environmentValue
        environment["MINIS_CHAT_SESSION_ID"] = lease.sessionID
        environment["MINIS_TASK_ID"] = lease.taskID
        environment["MINIS_RUN_ID"] = lease.runID
        environment["MINIS_TRIGGER"] = trigger
        let fixedEnvironment = environment
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.start(continuation, timeout: timeout)
                DispatchQueue.global(qos: .userInitiated).async {
                    guard state.beginLaunch() else { return }
                    let pid = ISHShellExecutor.executeExecutable(version.script.interpreter, arguments: version.invocationArguments,
                        environment: fixedEnvironment, stdinData: nil, fsContext: context,
                        maximumCaptureBytes: 128 * 1_024, lineCallback: nil) { result in
                        state.complete(NivoScheduledProcessResult(stdout: result.output, stderr: result.errorOutput,
                            exitCode: Int(result.exitCode), stdoutBytes: Int64(clamping: result.stdoutBytes),
                            truncated: result.outputTruncated, captureError: result.captureError,
                            timedOut: result.error == .timeout))
                    }
                    state.didLaunch(pid)
                }
            }
        } onCancel: { state.cancel() }
    }
}

/// 环境缺项给出可执行的准备方向，不把依赖缺失误报为脚本业务失败。
private enum NivoScheduledSetupError: LocalizedError {
    case interpreter, timezone
    var errorDescription: String? {
        switch self {
        case .interpreter: return AppLocalized("The script interpreter is unavailable. Install it in the app's shell and try again.")
        case .timezone: return AppLocalized("Time zone data is unavailable. Install tzdata in the app's shell and try again.")
        }
    }
}
