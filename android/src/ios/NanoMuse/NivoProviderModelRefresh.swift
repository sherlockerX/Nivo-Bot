import Foundation

/// 模型发现只生成候选，普通刷新与密钥轮换使用同一合并规则，提交前不发布配置。
@MainActor
enum NivoProviderModelRefresh {
    /// 保留模型身份、用户覆盖、自定义条目及语音模板，目录缺项不推导远端删除。
    static func replacing(in current: ProviderConfig, instanceID: String,
                          models rawModels: [LLMModel], now: Date = Date()) -> ProviderConfig {
        var candidate = current
        var seen = Set<String>()
        let models = rawModels.filter { seen.insert($0.id).inserted }
        let existing = current.modelEntries.filter { $0.providerInstanceId == instanceID }
        let previousByModel = preferredEntries(existing)
        let template = VoiceProviderTemplate.template(forBaseURL:
            current.instances.first { $0.id == instanceID }?.effectiveCustomBaseURL)
        let modalities = voiceModalities(template?.mockModels ?? [])
        let fetchedIDs = Set(models.map(\.id))
        let refreshed = models.map { model in
            entry(for: model, previous: previousByModel[model.id], instanceID: instanceID,
                  modality: modalities[model.id])
        }
        let custom = existing.filter { $0.isCustom && !fetchedIDs.contains($0.baseModel.id) }.map {
            ModelEntry(uuid: $0.uuid, providerInstanceId: instanceID,
                model: $0.baseModel.withInferredModality(), overrides: $0.overrides,
                isCustom: true, isHidden: $0.isHidden, userModifiedAt: $0.userModifiedAt)
        }
        let voice = existing.filter {
            !$0.isCustom && !fetchedIDs.contains($0.baseModel.id) && modalities[$0.baseModel.id] != nil
        }
        candidate.modelEntries.removeAll { $0.providerInstanceId == instanceID }
        candidate.modelEntries.append(contentsOf: refreshed + custom + voice)
        // 突然缩小的目录可能是服务端异常，保留不可用引用让用户决定，不主动改组。
        let hasSuspiciousShrink = existing.count >= 4 && models.count * 2 < existing.count
        if !hasSuspiciousShrink {
            let removed = Set(existing.map(\.id)).subtracting(candidate.modelEntries.map(\.id))
            removeReferences(removed, from: &candidate, now: now)
        }
        return candidate
    }

    private static func preferredEntries(_ entries: [ModelEntry]) -> [String: ModelEntry] {
        var result: [String: ModelEntry] = [:]
        for entry in entries {
            if entry.isCustom, let previous = result[entry.baseModel.id], !previous.isCustom { continue }
            result[entry.baseModel.id] = entry
        }
        return result
    }

    private static func voiceModalities(_ models: [LLMModel]) -> [String: ModelModality] {
        models.reduce(into: [:]) { result, model in
            guard let modality = model.modalityOverride,
                  modality.contains(.audioInput) || modality.contains(.audioOutput) else { return }
            result[model.id] = modality
        }
    }

    private static func entry(for model: LLMModel, previous: ModelEntry?, instanceID: String,
                              modality: ModelModality?) -> ModelEntry {
        let resolved = modality.map { model.withInferredModality().withModalityOverride($0) }
            ?? model.withInferredModality()
        return ModelEntry(uuid: previous?.uuid ?? UUID().uuidString, providerInstanceId: instanceID,
            model: resolved, overrides: previous?.overrides ?? ModelOverrides(), isCustom: false,
            isHidden: previous?.isHidden ?? false, userModifiedAt: previous?.userModifiedAt)
    }

    private static func removeReferences(_ identifiers: Set<String>, from config: inout ProviderConfig, now: Date) {
        guard !identifiers.isEmpty else { return }
        for index in config.modelGroups.indices {
            let members = config.modelGroups[index].memberEntryIds.filter { identifiers.contains($0) }
            for member in members {
                let observed = [config.modelGroups[index].addedMembers[member],
                    config.modelGroups[index].removedMembers[member]].compactMap { $0 }
                config.modelGroups[index].removedMembers[member] = NivoProviderEditClock.next(after: observed, now: now)
                config.modelGroups[index].addedMembers[member] = nil
            }
            config.modelGroups[index].memberEntryIds.removeAll { identifiers.contains($0) }
        }
        config.agentLoopModelEntryIds.removeAll { identifiers.contains($0) }
    }
}
