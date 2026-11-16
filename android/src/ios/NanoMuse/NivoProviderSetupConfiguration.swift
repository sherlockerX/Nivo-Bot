import Foundation

/// 新增服务商先构造完整候选，密钥尚未写入时即可验证模型及实例身份。
@MainActor
enum NivoProviderSetupConfiguration {
    /// 已有实例按锁内最新配置生成候选，网络探测期间的用户设置与模型覆盖继续保留。
    static func updating(instance: ProviderInstance, current: ProviderConfig,
                         models: [LLMModel], defaultChatModel: String?) throws -> NivoPreparedProviderImport {
        guard current.instances.first(where: { $0.id == instance.id }) == instance,
              !current.deletedInstances.contains(where: { $0.id == instance.id }) else {
            throw NivoPersonalBackupError.snapshotChanged
        }
        try validateModels(models)
        var candidate = models.isEmpty ? current : NivoProviderModelRefresh.replacing(
            in: current, instanceID: instance.id, models: models)
        adoptDefault(instance: instance, wanted: defaultChatModel, in: &candidate)
        return .init(instance: instance, configuration: candidate, credentials: [])
    }

    /// 即使某个组失去最后一个本实例成员也必须上传其变化；目录缺项仍只作本机刷新。
    static func syncPlan(_ prepared: NivoPreparedProviderImport, previous: ProviderConfig) -> NivoProviderSetupSyncSQL.Plan {
        let entries = prepared.configuration.modelEntries.filter { $0.providerInstanceId == prepared.instance.id }
        let references = Set(entries.flatMap { [$0.id, $0.uuid] })
        let previousGroups = previous.modelGroups.reduce(into: [String: ModelGroup]()) { $0[$1.id] = $1 }
        let groups = prepared.configuration.modelGroups.filter {
            $0 != previousGroups[$0.id] || $0.memberEntryIds.contains(where: references.contains)
        }
        return .init(instanceID: prepared.instance.id, entryIDs: entries.map(\.uuid), groupIDs: groups.map(\.id))
    }

    /// 复用新增页的模型种子规则，配置提交前不启动网络刷新或发布列表。
    static func prepare(instance: ProviderInstance, apiKey: String?, current: ProviderConfig,
                        models: [LLMModel] = [], defaultChatModel: String? = nil) throws -> NivoPreparedProviderImport {
        try validateNew(instance, current: current)
        guard instance.credentialType == .apiKey else { throw NivoOAuthPersistenceError.invalidValue }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard key.utf8.count <= 1_048_576, !key.isEmpty || instance.allowsEmptyAPIKey else {
            throw NivoCredentialRestoreError.invalidValue
        }
        let credentials: [NivoCredentialRestore.Item] = key.isEmpty ? [] : [
            .init(target: .init(kind: .providerAPIKey, owner: instance.id), data: Data(key.utf8))
        ]
        let candidate = try configuration(instance: instance, current: current,
            seeds: VoiceProviderTemplate.mockEntries(for: instance), models: models, defaultChatModel: defaultChatModel)
        return .init(instance: instance, configuration: candidate, credentials: credentials)
    }

    /// 浏览器授权保留原有暂存凭证供失败重试；手动令牌随配置一起进入可回滚提交。
    static func prepareOAuth(instance: ProviderInstance, manualToken: String?, current: ProviderConfig,
                             models: [LLMModel] = [], defaultChatModel: String? = nil) throws -> NivoPreparedProviderImport {
        try validateNew(instance, current: current)
        guard instance.credentialType == .oauth, instance.providerType != .openAIResponses else {
            throw NivoOAuthPersistenceError.invalidValue
        }
        var credentials: [NivoCredentialRestore.Item] = []
        if let manualToken {
            let token = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, token.utf8.count <= 1_048_576 else { throw NivoCredentialRestoreError.invalidValue }
            credentials.append(.init(target: .init(kind: .providerManualToken, owner: instance.id), data: Data(token.utf8)))
        }
        let builtIn = instance.providerType == .openAI ? LLMModel.allOpenAICodexOAuth : instance.providerType.builtInModels
        let seeds = models.isEmpty ? ModelsDevAPI.enrichModels(builtIn).map { ModelEntry(providerInstanceId: instance.id, model: $0) } : []
        let candidate = try configuration(instance: instance, current: current, seeds: seeds,
            models: models, defaultChatModel: defaultChatModel)
        return .init(instance: instance, configuration: candidate, credentials: credentials)
    }

    private static func validateNew(_ instance: ProviderInstance, current: ProviderConfig) throws {
        guard instance.providerType != .unsupported, !instance.id.isEmpty, instance.id.utf8.count <= 512,
              !instance.id.contains("\0"), !instance.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !current.instances.contains(where: { $0.id == instance.id }),
              !current.deletedInstances.contains(where: { $0.id == instance.id }) else {
            throw NivoPersonalBackupError.snapshotChanged
        }
    }

    private static func configuration(instance: ProviderInstance, current: ProviderConfig, seeds: [ModelEntry],
                                      models: [LLMModel], defaultChatModel: String?) throws -> ProviderConfig {
        try validateModels(models)
        var candidate = current
        candidate.instances.append(instance)
        var seen = Set<String>()
        // 模型列表优先，语音模板保留音频标记，防止文字接口的能力推断覆盖语音能力。
        let templateModalities = seeds.reduce(into: [String: ModelModality]()) { values, entry in
            guard let modality = entry.baseModel.modalityOverride,
                  modality.contains(.audioInput) || modality.contains(.audioOutput) else { return }
            values[entry.baseModel.id] = modality
        }
        let fetched = models.map { model in
            let resolved = templateModalities[model.id].map { model.withModalityOverride($0) } ?? model.withInferredModality()
            return ModelEntry(providerInstanceId: instance.id, model: resolved)
        }
        let entries = (fetched + seeds)
            .filter { seen.insert($0.baseModel.id).inserted }
        candidate.modelEntries.append(contentsOf: entries)
        adoptDefault(instance: instance, wanted: defaultChatModel, in: &candidate)
        return candidate
    }

    private static func validateModels(_ models: [LLMModel]) throws {
        guard models.count <= 100_000,
              models.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 4096 && !$0.id.contains("\0") }) else {
            throw NivoOAuthPersistenceError.invalidValue
        }
    }

    private static func adoptDefault(instance: ProviderInstance, wanted: String?, in candidate: inout ProviderConfig) {
        let entries = candidate.modelEntries.filter { $0.providerInstanceId == instance.id && !$0.isHidden }
        guard let wanted, let chat = preferredChat(entries, wanted: wanted),
              !candidate.modelGroups.contains(where: { $0.memberEntryIds.contains(chat.id) || $0.memberEntryIds.contains(chat.uuid) }) else { return }
        let group = ModelGroup(name: instance.label, memberEntryIds: [chat.id])
        candidate.modelGroups.append(group)
        if candidate.defaultPrimaryGroupId == nil { candidate.defaultPrimaryGroupId = group.id }
    }

    private static func preferredChat(_ entries: [ModelEntry], wanted: String) -> ModelEntry? {
        entries.first { $0.model.id == wanted }
            ?? entries.first { !wanted.isEmpty && $0.model.id.hasSuffix("/" + wanted) }
            ?? entries.first { $0.model.id.lowercased().contains("deepseek") && NanoMuseVision.deepSeekSees($0.model.id.lowercased()) == true }
            ?? entries.first { NanoMuseModelSlots.chats($0) }
    }
}
