import Foundation

/// 经典布局的模块跳转先准备目标聊天，再导航；保留已有草稿和附件，不自动发送。
@MainActor
enum NivoClassicChatLauncher {
    /// 主聊天才管理课程与目标，普通点子使用独立对话，所有异步步骤绑定同一账户代次。
    static func prepare(scope: NivoLifeScope, usesMain: Bool, prompt: (String) -> String) async throws -> String {
        try requireScope(scope)
        let reservation = try NivoScheduledRunScopes.shared.beginConversationEdit(["classic-open-" + UUID().uuidString])
        defer { NivoScheduledRunScopes.shared.endConversationEdit(reservation) }
        let prepared = try await resolveModel(scope: scope, usesMain: usesMain)
        defer { NivoScheduledRunScopes.shared.endConversationEdit(prepared.reservation) }
        let model = prepared.model
        try requireScope(scope)
        guard let identifier = model.sessionId, model.editingMessageIndex == nil,
              !model.isProcessing, !model.isLoadingSession else { throw NivoChatAccessError.busy }
        let text = prompt(identifier)
        if !text.isEmpty {
            if !model.inputText.isEmpty { model.inputText += "\n\n" }
            model.inputText += text
        }
        if usesMain { UserDefaults.standard.set(identifier, forKey: NanoMuseMainChat.key) }
        return identifier
    }

    private static func resolveModel(scope: NivoLifeScope, usesMain: Bool) async throws -> PreparedModel {
        if usesMain, let identifier = UserDefaults.standard.string(forKey: NanoMuseMainChat.key),
           NanoMuseSync.shared.shows(identifier),
           let session = await ChatStore.shared.getSession(identifier),
           NivoMainChatRules.isEligible(isRemote: session.isRemote, source: session.source) {
            try requireScope(scope)
            guard !SessionActivityTracker.isActiveThreadSafe(identifier) else { throw NivoChatAccessError.busy }
            let cached = ViewModelCache.shared.getOrCreate(for: identifier)
            return try await reserve(cached.vm, identifier: identifier, needsLoad: cached.isNew, scope: scope)
        }
        try requireScope(scope)
        let model = ViewModelCache.shared.createDraft()
        let identifier = await model.ensureSessionReturningId()
        try requireScope(scope)
        return try await reserve(model, identifier: identifier, needsLoad: false, scope: scope)
    }

    /// 占位从加载、存在性检查一直保留到追加草稿，异步返回的窗口也不允许删除或启动任务。
    private static func reserve(_ model: AIChatViewModel, identifier: String, needsLoad: Bool,
                                scope: NivoLifeScope) async throws -> PreparedModel {
        let reservation = try NivoChatAccountAccess.beginConversationEdit([identifier])
        do {
            if needsLoad { await model.loadSession() }
            try requireScope(scope)
            let saved = try await ChatStore.shared.nmCoachSources(chatSessionID: identifier, identifiers: [])
            try requireScope(scope)
            guard saved.sessionExists else { throw NivoLifeError.notFound(identifier) }
            try NanoMuseAccountData.shared.claim(identifier, owner: scope.ownerKey)
            return PreparedModel(model: model, reservation: reservation)
        } catch {
            NivoScheduledRunScopes.shared.endConversationEdit(reservation)
            throw error
        }
    }

    private static func requireScope(_ scope: NivoLifeScope) throws {
        try NivoCoachReconciliation.requireScope(scope)
        try NivoChatAccountAccess.require(sessionID: nil)
    }

    /// 调用者负责在草稿写入结束后释放实际聊天的占位。
    private struct PreparedModel {
        let model: AIChatViewModel
        let reservation: UUID
    }
}
