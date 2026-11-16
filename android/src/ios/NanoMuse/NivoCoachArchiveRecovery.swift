import Foundation

/// 整理队列始终回查真实聊天来源，来源变化时只丢弃旧意图，不重造原话。
@MainActor
enum NivoCoachArchiveRecovery {
    /// 同一聊天按SQLite顺序处理；单条失败保留队列，并汇总错误供界面重试。
    static func retry(chatID: String, scope: NivoLifeScope, generation: UUID) async throws -> String? {
        try NivoCoachReconciliation.requireScope(scope)
        let pending = try await NivoCoachV2Store.shared.pendingArchives(chatSessionID: chatID,
            ownerKey: scope.ownerKey, generation: generation)
        guard !pending.entries.isEmpty else { return pending.failures.isEmpty ? nil : pending.failures.joined(separator: "\n") }
        let sources = try await ChatStore.shared.nmCoachSources(chatSessionID: chatID, identifiers: Set(pending.entries.map(\.messageID)))
        let state = try await NivoCoachV2Store.shared.snapshot(ownerKey: scope.ownerKey)
        try NivoCoachReconciliation.requireScope(scope)
        let isActive = state.topics.contains { $0.chatSessionID == chatID && $0.status == "active" }
        let entries = pending.entries.sorted {
            let first = sources.messages[$0.messageID]?.sortOrder ?? Int.max
            let second = sources.messages[$1.messageID]?.sortOrder ?? Int.max
            return first == second ? $0.messageID < $1.messageID : first < second
        }
        var failures = pending.failures
        for entry in entries {
            do {
                try NivoCoachReconciliation.requireScope(scope)
                try await apply(entry, source: sources.messages[entry.messageID], isActive: isActive,
                                sessionExists: sources.sessionExists, generation: generation)
            } catch {
                try NivoCoachReconciliation.requireScope(scope)
                failures.append(NivoLifeModel.message(error))
            }
        }
        return failures.isEmpty ? nil : Array(Set(failures)).sorted().joined(separator: "\n")
    }

    /// 档案页恢复所有专题的待整理来源，读取错误只影响该次展示，不覆盖磁盘内容。
    static func retryAll(scope: NivoLifeScope, generation: UUID) async throws -> String? {
        let state = try await NivoCoachV2Store.shared.snapshot(ownerKey: scope.ownerKey)
        var failures: [String] = []
        for topic in state.topics where !topic.chatSessionID.isEmpty {
            if let error = try await retry(chatID: topic.chatSessionID, scope: scope, generation: generation) { failures.append(error) }
        }
        return failures.isEmpty ? nil : Array(Set(failures)).sorted().joined(separator: "\n")
    }

    private static func apply(_ entry: NivoCoachArchiveEntry, source: NivoCoachSourceSnapshot?,
                              isActive: Bool, sessionExists: Bool, generation: UUID) async throws {
        let store = NivoCoachV2Store.shared
        guard isActive, sessionExists else { try await store.finishArchive(entry, generation: generation); return }
        // 暂存先于SQLite插入；使用明确的写入租约覆盖发送早期尚未设置活动标志的窗口。
        guard let source else {
            if !NivoCoachArchiveWrites.contains(entry.messageID), !SessionActivityTracker.isActiveThreadSafe(entry.chatID) {
                try await store.finishArchive(entry, generation: generation)
            }
            return
        }
        guard source.sessionID == entry.chatID, source.role == entry.role,
              source.digest == entry.digest, source.text.contains(entry.text) else {
            try await store.finishArchive(entry, generation: generation)
            return
        }
        if entry.role == "user" {
            let user = NivoSavedUserTurn(id: entry.messageID, text: entry.text, ownerKey: entry.ownerKey,
                chatSessionID: entry.chatID, createdAt: source.createdAt, sourceDigest: entry.digest)
            try await store.registerConversationUser(user, expectedSessionID: entry.lessonID, generation: generation)
        } else {
            try await store.recordConversationReply(chatSessionID: entry.chatID, messageID: entry.messageID,
                text: entry.text, expectedSessionID: entry.lessonID, ownerKey: entry.ownerKey,
                generation: generation, sourceDigest: entry.digest, sourceCreatedAt: source.createdAt)
        }
        try await store.finishArchive(entry, generation: generation)
    }
}
