import Foundation

/// 每个模型回合固定账户代次、聊天和课次，迟到的回复不能落入新的课次。
struct NivoCoachTurnCapture: Sendable {
    var scope: NivoLifeScope
    var generation: UUID
    var chatSessionID: String
    var lessonID: String
    var userMessageID: String
}

/// 对照来源只跨actor传递文本签名，不读取或传递碎片照片和聊天图片。
struct NivoCoachSourceSnapshot: Sendable {
    var sessionID: String
    var role: String
    var text: String
    var digest: String
    var createdAt: Int64
    var sortOrder: Int
}

/// 会话存在性和消息来源必须在同一次数据库读取中取得，读取失败不能解释为删除。
struct NivoCoachSourceBundle: Sendable {
    var sessionExists: Bool
    var messages: [String: NivoCoachSourceSnapshot]
}

/// 对照SQLite原始消息恢复失效关系，覆盖删除后崩溃或应用重启造成的通知缺口。
@MainActor
enum NivoCoachReconciliation {
    /// 档案页和主聊天发布全部进度前先对照所有已绑定专题，未绑定草稿不触发聊天读取。
    static func reconcileAll(scope: NivoLifeScope, generation: UUID) async throws {
        let state = try await NivoCoachV2Store.shared.snapshot(ownerKey: scope.ownerKey)
        for topic in state.topics where topic.status == "active" && !topic.chatSessionID.isEmpty {
            try await reconcile(chatSessionID: topic.chatSessionID, scope: scope, generation: generation)
        }
    }

    /// 只检查选定专题；只读查询和课程页都在发布进度前调用。
    static func reconcile(chatSessionID: String, scope: NivoLifeScope, generation: UUID) async throws {
        try requireScope(scope)
        let state = try await NivoCoachV2Store.shared.snapshot(ownerKey: scope.ownerKey)
        guard let topic = state.topics.first(where: { !$0.chatSessionID.isEmpty && $0.chatSessionID == chatSessionID }), topic.status == "active" else { return }
        let sources = state.sessions.filter { $0.topicID == topic.id }.flatMap(\.turns).filter { !$0.originMessageID.isEmpty && !$0.sourceInvalidated }
        let grouped = Dictionary(grouping: sources, by: \.originMessageID)
        let bundle = try await ChatStore.shared.nmCoachSources(chatSessionID: chatSessionID, identifiers: Set(grouped.keys))
        try requireScope(scope)
        if !bundle.sessionExists {
            try await NivoCoachV2Store.shared.invalidateConversation(chatSessionID: chatSessionID, reason: "conversation_deleted",
                ownerKey: scope.ownerKey, generation: generation)
            return
        }
        var invalid = Set<String>()
        // 同一SQLite行可能包含多个来源摘录，逐行一次读取，避免按证据重复查询。
        for (identifier, turns) in grouped {
            let row = bundle.messages[identifier]
            guard let row else { invalid.insert(identifier); continue }
            if turns.contains(where: { turn in
                let roleMatches = turn.role == "user" ? row.role == "user" : row.role == "assistant"
                return !roleMatches || row.sessionID != (turn.originChatSessionID ?? chatSessionID) ||
                    !row.text.contains(turn.text) || (turn.sourceDigest != nil && turn.sourceDigest != row.digest)
            }) {
                invalid.insert(identifier)
            }
        }
        if !invalid.isEmpty {
            try await NivoCoachV2Store.shared.invalidateSourceMessages(chatSessionID: chatSessionID, messageIDs: invalid,
                ownerKey: scope.ownerKey, generation: generation)
        }
        try requireScope(scope)
    }

    /// 账户及代次同时验证，切走再回来仍视为不同的一次使用上下文。
    static func requireScope(_ scope: NivoLifeScope) throws {
        guard NivoLifeModel.shared.accessScope == scope, NanoMuseAccountData.shared.current == scope.ownerKey else { throw NivoLifeError.accountChanged }
    }

    /// 排除推理、工具输入输出和图片，只取聊天里真实显示的文本。
    static func text(_ row: RawMessage) -> String {
        row.parts.compactMap { part in if case .text(let text) = part { return text }; return nil }.joined(separator: "\n")
    }
}

@MainActor
extension AIChatViewModel {
    /// 在调用模型前自动归档真实用户消息，不要求用户额外按一次提交。
    func nmPrepareCoachTurn() async throws {
        nmCoachTurnCapture = nil
        guard sessionSource == NivoCoachConversationIdentity.source || NivoCoachChatContext.shared.isPractice(sessionId) else { return }
        guard let scope = NivoLifeModel.shared.accessScope, let chatID = sessionId,
              let message = messages.last(where: { $0.role == .user && !$0.isQueued }),
              let user = await nmSavedUserTurn(message) else { throw NivoCoachConversationError.storage }
        try NivoCoachReconciliation.requireScope(scope)
        // 当前用户行已由保存来源校验确认，标记其真实ID供档案跳转使用。
        message.nmSourceMessageIDs.insert(user.id)
        let generation = try await NivoCoachV2Store.shared.access(ownerKey: scope.ownerKey)
        try await NivoCoachReconciliation.reconcile(chatSessionID: chatID, scope: scope, generation: generation)
        let state = try await NivoCoachV2Store.shared.snapshot(ownerKey: scope.ownerKey)
        try NivoCoachReconciliation.requireScope(scope)
        guard sessionId == chatID, let topic = state.topics.first(where: { $0.chatSessionID == chatID }),
              topic.status == "active" else { throw NivoLifeError.invalidTransition("archived_topic") }
        let prior = state.sessions.first { $0.topicID == topic.id && $0.turns.contains { $0.role == "user" && $0.originMessageID == user.id } }
        let lessonID = prior?.id ?? state.sessions.last(where: { $0.topicID == topic.id })?.id
        guard let lessonID, let digest = user.sourceDigest else { throw NivoCoachConversationError.storage }
        let entry = NivoCoachArchiveEntry(ownerKey: scope.ownerKey, chatID: chatID, lessonID: lessonID,
            messageID: user.id, role: "user", text: user.text, digest: digest)
        let staged = try await NivoCoachV2Store.shared.stageArchive(entry, generation: generation)
        try await NivoCoachV2Store.shared.registerConversationUser(user, expectedSessionID: staged.lessonID, generation: generation)
        try await NivoCoachV2Store.shared.finishArchive(staged, generation: generation)
        try NivoCoachReconciliation.requireScope(scope)
        guard sessionId == chatID else { throw NivoLifeError.accountChanged }
        nmCoachTurnCapture = NivoCoachTurnCapture(scope: scope, generation: generation, chatSessionID: chatID,
            lessonID: staged.lessonID, userMessageID: user.id)
        await NivoCoachChatContext.shared.refresh(sessionID: chatID)
    }

    /// 只有最终答案和对应SQLite行都存在时才归档教练正文，错误或中断不伪装成完成。
    func nmRecordCoachReply(messageID: String, displayMessageID: UUID, text: String,
                            captured: NivoCoachTurnCapture?) async {
        guard let captured, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try NivoCoachReconciliation.requireScope(captured.scope)
            guard sessionId == captured.chatSessionID, let row = try await ChatStore.shared.nmLoadEvidenceMessage(id: messageID),
                  row.sessionId == captured.chatSessionID, row.role == .assistant,
                  NivoCoachReconciliation.text(row).contains(text) else { throw NivoLifeError.invalidField("saved_coach_reply") }
            try NivoCoachReconciliation.requireScope(captured.scope)
            guard sessionId == captured.chatSessionID else { throw NivoLifeError.accountChanged }
            // 读盘期间可能开始新回合，只标记调用前固定的展示行；行已移除时保留档案，不猜测位置。
            messages.first(where: { $0.id == displayMessageID && $0.role == .assistant })?
                .nmSourceMessageIDs.insert(messageID)
            let staged = NivoCoachArchiveEntry(ownerKey: captured.scope.ownerKey, chatID: captured.chatSessionID,
                lessonID: captured.lessonID, messageID: messageID, role: "assistant", text: text,
                digest: NivoUserTurnEvidence.digest(row))
            try await NivoCoachV2Store.shared.stageArchive(staged, generation: captured.generation)
            try await NivoCoachV2Store.shared.recordConversationReply(chatSessionID: captured.chatSessionID, messageID: messageID,
                text: text, expectedSessionID: captured.lessonID, ownerKey: captured.scope.ownerKey,
                generation: captured.generation, sourceDigest: NivoUserTurnEvidence.digest(row),
                sourceCreatedAt: Int64(row.createdAt.timeIntervalSince1970 * 1_000))
            try await NivoCoachV2Store.shared.finishArchive(staged, generation: captured.generation)
            try NivoCoachReconciliation.requireScope(captured.scope)
            NotificationCenter.default.post(name: .nivoCoachStateChanged, object: captured.scope.ownerKey)
        } catch { if NivoLifeModel.shared.accessScope == captured.scope { errorMessage = NivoLifeModel.message(error) } }
    }

    /// 在聊天行写入前保存归档意图，只处理用户正文或已确认的最终回复。
    func nmStageCoachMessage(_ row: RawMessage, finalText: String?,
                             capturedReply: NivoCoachTurnCapture?) async throws -> NivoCoachArchiveEntry? {
        guard sessionSource == NivoCoachConversationIdentity.source || NivoCoachChatContext.shared.isPractice(row.sessionId) else { return nil }
        guard let scope = NivoLifeModel.shared.accessScope, sessionId == row.sessionId,
              NanoMuseSync.shared.shows(row.sessionId) else { throw NivoLifeError.accountChanged }
        let userMessage = messages.last { $0.role == .user && !$0.isQueued }
        if row.role == .user {
            guard let userMessage, !userMessage.isCompactedHistory, userMessage.nmRoutine == nil,
                  userMessage.nmFromDevice == nil else { return nil }
        }
        let user = NivoUserTurnEvidence.validated(row, text: userMessage?.content ?? "",
            sessionID: row.sessionId, owner: scope.ownerKey)
        let text = row.role == .user ? user?.text : finalText
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        try NivoCoachReconciliation.requireScope(scope)
        let generation = try await NivoCoachV2Store.shared.access(ownerKey: scope.ownerKey)
        let state = try await NivoCoachV2Store.shared.snapshot(ownerKey: scope.ownerKey)
        try NivoCoachReconciliation.requireScope(scope)
        guard sessionId == row.sessionId,
              let topic = state.topics.first(where: { $0.chatSessionID == row.sessionId && $0.status == "active" }),
              let lesson = state.sessions.last(where: { $0.topicID == topic.id }) else {
            throw NivoLifeError.invalidTransition("archived_topic")
        }
        let lessonID: String
        if row.role == .assistant {
            guard let captured = capturedReply, captured.scope == scope, captured.generation == generation,
                  captured.chatSessionID == row.sessionId else { throw NivoLifeError.accountChanged }
            lessonID = captured.lessonID
        } else { lessonID = lesson.id }
        let entry = NivoCoachArchiveEntry(ownerKey: scope.ownerKey, chatID: row.sessionId, lessonID: lessonID,
            messageID: row.id, role: row.role.rawValue, text: text, digest: NivoUserTurnEvidence.digest(row))
        return try await NivoCoachV2Store.shared.stageArchive(entry, generation: generation)
    }
}
