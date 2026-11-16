import Foundation

/// 预检读取真实会话与消息，不能只根据账户可见性将已删除的目标判定为可运行。
@MainActor
enum NivoRoutineTargetValidation {
    /// 异步读取后重新核对账户代次；调用方在正式写入前仍要检查最新任务版本。
    static func validate(_ row: NanoMuseRoutine, generation: UInt64) async throws {
        try requireCurrent(generation)
        try NivoRoutineScheduleRules.validate(row)
        if let script = row.script {
            let sessionID = row.sessionId ?? row.dedicatedSessionID ?? ("nm-task-run-" + row.id)
            if row.execution?.target == .append {
                guard let id = row.sessionId, NanoMuseAccountData.shared.shows(id),
                      let session = await ChatStore.shared.getSession(id), !session.isRemote else {
                    throw NivoLifeError.notFound("session")
                }
            }
            try await NivoScheduledScriptRuntime.probe(script, sessionID: sessionID, generation: generation)
            try requireCurrent(generation)
            return
        }
        let execution = row.execution ?? NivoRoutineExecution(target: row.sessionId == nil ? .newSession : .append)
        guard execution.target != .newSession else {
            let id = row.dedicatedSessionID ?? NivoRoutineConversationRules.initialSession(
                owner: NanoMuseAccountData.shared.current, routineID: row.id)
            try NivoRoutineModelBinding.validate(execution, sessionID: id)
            return
        }
        guard let id = row.sessionId, NanoMuseAccountData.shared.shows(id) else { throw NivoLifeError.accountChanged }
        guard let session = await ChatStore.shared.getSession(id), !session.isRemote else { throw NivoLifeError.notFound("session") }
        try requireCurrent(generation)
        if execution.target == .rerun {
            let messages = await ChatStore.shared.loadMessages(sessionId: id)
            try requireCurrent(generation)
            guard messages.contains(where: { $0.id == execution.messageID && NivoChatBranchRules.isUserTurn($0) }) else {
                throw NivoLifeError.notFound("message")
            }
        }
        try NivoRoutineModelBinding.validate(execution, sessionID: id, storedModelID: session.modelId)
    }

    private static func requireCurrent(_ generation: UInt64) throws {
        guard NanoMuseAccountData.shared.generation == generation, !NanoMuseAccountData.shared.isChangingAccount,
              !NivoPersonalBackupAccess.isBusy else { throw NivoLifeError.accountChanged }
    }
}
