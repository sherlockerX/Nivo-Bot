import Foundation

/// 模型编辑只构造候选配置，持久化与发布由仓库统一确认。
@MainActor
enum NivoProviderModelEditConfiguration {
    /// 新增前检查父提供商和双重身份，用户输入不提前进入可见配置。
    static func adding(_ entry: ModelEntry, to original: ProviderConfig) throws -> ProviderConfig {
        try requireOwner(entry, in: original)
        try NivoProviderModelIdentity.validateAddition(identity(entry), in: original.modelEntries.map(identity))
        var candidate = original
        candidate.modelEntries.append(ModelEntry(uuid: entry.uuid, providerInstanceId: entry.providerInstanceId,
            model: entry.baseModel.withInferredModality(), overrides: entry.overrides, isCustom: entry.isCustom,
            isHidden: entry.isHidden, userModifiedAt: Date()))
        return candidate
    }

    /// 使用UUID定位；有旧表单快照时拒绝覆盖已被另一页面或刷新改变的模型。
    static func updating(_ entry: ModelEntry, expected: ModelEntry? = nil,
                         in original: ProviderConfig, now: Date = Date()) throws -> ProviderConfig {
        try requireOwner(entry, in: original)
        let index = try NivoProviderModelIdentity.replacementIndex(for: identity(entry), in: original.modelEntries.map(identity))
        let prior = original.modelEntries[index]
        guard expected == nil || prior == expected,
              prior.isCustom || prior.baseModel.id == entry.baseModel.id else { throw NivoProviderModelIdentity.Failure.changed }
        var candidate = original
        var updated = entry
        updated.userModifiedAt = NivoProviderEditClock.next(after: [prior.userModifiedAt].compactMap { $0 }, now: now)
        candidate.modelEntries[index] = updated
        if prior.id != updated.id { renameReferences(from: prior, to: updated.id, in: &candidate, now: now) }
        return candidate
    }

    private static func identity(_ entry: ModelEntry) -> NivoProviderModelIdentity {
        .init(uuid: entry.uuid, providerID: entry.providerInstanceId, modelID: entry.baseModel.id)
    }

    private static func requireOwner(_ entry: ModelEntry, in config: ProviderConfig) throws {
        guard config.instances.contains(where: { $0.id == entry.providerInstanceId }),
              !config.deletedInstances.contains(where: { $0.id == entry.providerInstanceId }) else {
            throw NivoProviderModelIdentity.Failure.changed
        }
    }

    private static func renameReferences(from original: ModelEntry, to target: String,
                                         in config: inout ProviderConfig, now: Date) {
        let aliases: Set<String> = [original.id, original.uuid, original.legacyColonCompositeKey]
        for index in config.modelGroups.indices {
            var group = config.modelGroups[index]
            let oldMembers = group.memberEntryIds.filter(aliases.contains)
            guard !oldMembers.isEmpty else { continue }
            let observed = aliases.flatMap { [group.addedMembers[$0], group.removedMembers[$0]].compactMap { $0 } }
                + [group.addedMembers[target], group.removedMembers[target]].compactMap { $0 }
            let timestamp = NivoProviderEditClock.next(after: observed, now: now)
            // 别名历史可能未归一化；一起写移除事件，避免后续成员合并重新带回旧ID。
            for member in aliases {
                group.addedMembers[member] = nil
                group.removedMembers[member] = timestamp
            }
            group.memberEntryIds = NivoProviderModelIdentity.remap(group.memberEntryIds, aliases: aliases, target: target)
            group.addedMembers[target] = timestamp
            group.removedMembers[target] = nil
            config.modelGroups[index] = group
        }
        config.agentLoopModelEntryIds = NivoProviderModelIdentity.remap(config.agentLoopModelEntryIds, aliases: aliases, target: target)
        for (identifier, var binding) in config.sessionBindings {
            binding.primarySource = renamed(binding.primarySource, aliases: aliases, target: target)
            binding.subModelSource = binding.subModelSource.map { renamed($0, aliases: aliases, target: target) }
            config.sessionBindings[identifier] = binding
        }
    }

    private static func renamed(_ source: SessionModelSource, aliases: Set<String>, target: String) -> SessionModelSource {
        switch source {
        case .directEntry(let identifier, let composite):
            guard aliases.contains(identifier) || composite.map(aliases.contains) == true else { return source }
            return .directEntry(modelEntryId: target, compositeKey: composite == nil ? nil : target)
        case .group(let groupID, let resolved):
            return aliases.contains(resolved) ? .group(groupId: groupID, resolvedEntryId: target) : source
        }
    }
}

extension NivoProviderModelIdentity.Failure: LocalizedError {
    /// 使用已有界面翻译，不暴露底层存储路径或任何凭据。
    var errorDescription: String? {
        switch self {
        case .duplicateModelID(let identifier): return AppLocalized("Model ID \"\(identifier)\" already exists.")
        case .changed: return AppLocalized("This item changed. Reload before saving.")
        case .invalidID: return AppLocalized("Could not save")
        }
    }
}
