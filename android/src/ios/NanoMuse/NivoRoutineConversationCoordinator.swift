import Foundation

/// 首次运行创建任务对话，后续复用；删除对话后的新一轮运行才分配新身份。
@MainActor
enum NivoRoutineConversationCoordinator {
    /// 调度器已登记running后调用，账户切换和任务编辑均不能插入创建过程。
    static func session(routineID: String, generation: UInt64) async throws -> String {
        try requireCurrent(generation)
        let scheduler = NanoMuseScheduler.shared
        guard var row = scheduler.routine(id: routineID), NivoRoutineConversationRules.usesDedicatedConversation(row) else {
            throw NivoLifeError.notFound(routineID)
        }
        let owner = NanoMuseAccountData.shared.current
        var identifier = row.dedicatedSessionID ?? NivoRoutineConversationRules.initialSession(owner: owner, routineID: row.id)
        let sources = try await ChatStore.shared.nmCoachSources(chatSessionID: identifier, identifiers: [])
        try requireCurrent(generation)
        if !sources.sessionExists, await ChatStore.shared.deletedSessionTombstone(identifier) != nil {
            identifier = UUID().uuidString
        }
        try requireCurrent(generation)
        guard NanoMuseAccountData.shared.shows(identifier) else { throw NivoLifeError.accountChanged }
        if row.dedicatedSessionID != identifier {
            row.dedicatedSessionID = identifier
            row = try scheduler.saveRoutine(row, creating: false, isExecutionUpdate: true)
        }
        let modelID: String
        let encoded: String?
        if row.script != nil {
            modelID = "scheduled-script"
            encoded = nil
        } else {
            let selected = try NivoRoutineModelBinding.selection(row.execution ?? NivoRoutineExecution(), sessionID: identifier)
            let binding = SessionModelBinding(sessionId: identifier, primarySource: selected.source, subModelSource: nil)
            encoded = String(decoding: try JSONEncoder().encode(binding), as: UTF8.self)
            modelID = selected.entry.model.id
        }
        let request = NivoManagedChatCreation(id: identifier, title: String(row.label.prefix(120)),
            modelID: modelID, modelBinding: encoded,
            folderID: NivoRoutineConversationRules.folder(owner: owner), folderName: AppLocalized("Scheduled tasks"),
            memoryEnabled: UserDefaults.standard.object(forKey: "memory.global.enabled") as? Bool ?? true)
        try NanoMuseAccountData.shared.claim(identifier, owner: owner)
        do { _ = try await ChatStore.shared.nmEnsureRoutineConversation(request) }
        catch is NivoCoachConversationError { throw CreationFailure() }
        try requireCurrent(generation)
        try NanoMuseAccountData.shared.claim(identifier, owner: owner)
        NotificationCenter.default.post(name: .sessionDidUpdate, object: nil)
        return identifier
    }

    private static func requireCurrent(_ generation: UInt64) throws {
        guard NanoMuseAccountData.shared.generation == generation, !NanoMuseAccountData.shared.isChangingAccount,
              !NivoPersonalBackupAccess.isBusy else { throw NivoLifeError.accountChanged }
    }

    private struct CreationFailure: LocalizedError {
        var errorDescription: String? { AppLocalized("Could not start the routine. Try again.") }
    }
}
