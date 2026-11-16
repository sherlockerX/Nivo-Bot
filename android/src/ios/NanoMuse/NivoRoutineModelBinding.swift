import Foundation

/// 定时任务显式指定模型时必须可用，失效配置不能悄悄改用其他收费模型。
@MainActor
enum NivoRoutineModelBinding {
    /// 无副作用预检只解析配置，不发模型请求或写入会话。
    static func validate(_ execution: NivoRoutineExecution, sessionID: String, storedModelID: String? = nil) throws {
        if execution.target == .newSession {
            _ = try selection(execution, sessionID: sessionID)
            return
        }
        let store = ProviderConfigStore.shared
        if let kind = execution.modelKind, let id = execution.modelID {
            _ = try resolve(kind: kind, id: id, sessionID: sessionID, store: store)
            return
        }
        if let source = store.binding(for: sessionID)?.primarySource {
            if case .group(let id, _) = source { _ = try resolve(kind: .group, id: id, sessionID: sessionID, store: store) }
            else { try requireUsable(store.entry(for: source.preferredReference), store: store) }
            return
        }
        if let modelID = storedModelID, !modelID.isEmpty {
            _ = try resolve(kind: .entry, id: modelID, sessionID: sessionID, store: store)
            return
        }
        if let groupID = store.defaultPrimaryGroupId {
            _ = try resolve(kind: .group, id: groupID, sessionID: sessionID, store: store)
            return
        }
        guard store.modelEntries.contains(where: { isUsable($0, store: store) }) else {
            throw NivoLifeError.invalidField("routine_model_unavailable")
        }
    }
    /// 同时更新配置、会话模型字段和已缓存聊天对象，失败时尽力恢复原配置。
    static func apply(_ execution: NivoRoutineExecution, sessionID: String, model: AIChatViewModel) async throws {
        guard execution.target == .newSession || execution.modelKind != nil else {
            try requireUsable(model.resolveCurrentEntry(), store: .shared)
            return
        }
        let account = NanoMuseAccountData.shared
        let generation = account.generation
        let store = ProviderConfigStore.shared
        let selected = try selection(execution, sessionID: sessionID)
        let source = selected.source
        let entry = selected.entry
        let previous = store.binding(for: sessionID)
        let inference = store.inferenceConfig(for: sessionID)
        let binding = SessionModelBinding(sessionId: sessionID, primarySource: source, subModelSource: previous?.subModelSource)
        let encoded = String(decoding: try JSONEncoder().encode(binding), as: UTF8.self)
        try await store.nmSetBranchConfiguration(sessionID: sessionID, binding: binding, inference: inference)
        do { try await ChatStore.shared.nmSetRoutineModel(sessionID: sessionID, modelID: entry.model.id, binding: encoded) }
        catch {
            if account.generation == generation {
                try? await store.nmSetBranchConfiguration(sessionID: sessionID, binding: previous, inference: inference)
            }
            throw error
        }
        guard account.generation == generation, !account.isChangingAccount else { throw NivoLifeError.accountChanged }
        model.cachedSessionModelId = entry.model.id
        model.selectedModel = entry.model
    }

    /// 预检、创建和每次运行使用同一选择规则，取消显式模型后恢复当前默认选择。
    static func selection(_ execution: NivoRoutineExecution, sessionID: String) throws -> (source: SessionModelSource, entry: ModelEntry) {
        let store = ProviderConfigStore.shared
        let source: SessionModelSource
        if let kind = execution.modelKind, let identifier = execution.modelID {
            source = try resolve(kind: kind, id: identifier, sessionID: sessionID, store: store)
        } else if let groupID = store.defaultPrimaryGroupId {
            source = try resolve(kind: .group, id: groupID, sessionID: sessionID, store: store)
        } else if let entry = store.nmLatestChatEntry {
            source = .directEntry(modelEntryId: entry.uuid, compositeKey: entry.id)
        } else { throw NivoLifeError.invalidField("routine_model_unavailable") }
        guard let entry = store.entry(for: source.preferredReference) else {
            throw NivoLifeError.invalidField("routine_model_unavailable")
        }
        return (source, entry)
    }

    private static func resolve(kind: NivoRoutineExecution.ModelKind, id: String,
                                sessionID: String, store: ProviderConfigStore) throws -> SessionModelSource {
        if kind == .group {
            guard let group = store.group(for: id),
                  let entryID = ModelGroupRouter.resolve(group: group, sessionId: sessionID, store: store) else {
                throw NivoLifeError.invalidField("routine_model_unavailable")
            }
            try requireUsable(store.entry(for: entryID), store: store)
            return .group(groupId: id, resolvedEntryId: entryID)
        }
        let entry: ModelEntry
        if let exact = store.entry(for: id) { entry = exact }
        else {
            // 安卓旧命令使用厂商模型名；只有唯一可用来源才接受，重名时要求选择明确的条目ID。
            let matching = store.modelEntries.filter { $0.model.id == id && isUsable($0, store: store) }
            guard matching.count == 1, let selected = matching.first else {
                throw NivoLifeError.invalidField(matching.isEmpty ? "routine_model_unavailable" : "routine_model_ambiguous")
            }
            entry = selected
        }
        try requireUsable(entry, store: store)
        return .directEntry(modelEntryId: entry.uuid, compositeKey: entry.id)
    }

    /// 用于运行前的最终校验，防止预检后配置改变或聊天默认选择落到非文本模型。
    static func requireUsable(_ entry: ModelEntry?, store: ProviderConfigStore) throws {
        guard let entry, isUsable(entry, store: store) else { throw NivoLifeError.invalidField("routine_model_unavailable") }
    }

    private static func isUsable(_ entry: ModelEntry, store: ProviderConfigStore) -> Bool {
        store.nmIsUsableChatEntry(entry)
    }
}
