import Foundation

/// 由已确认的提供商快照生成删除计划，模型复合键与V3主键分别保留。
enum NivoProviderDeletionConfiguration {
    /// 只有受这次删除影响而变空的组才删除，用户主动建立的空组保持原样。
    static func plan(instanceID: String, config: ProviderConfig, ruleIDs: [String], now: Date) -> NivoProviderDeletion.Plan {
        let entries = config.modelEntries.filter { $0.providerInstanceId == instanceID }
        let references = Set(entries.flatMap { [$0.id, $0.uuid] })
        let affected = config.modelGroups.filter { $0.memberEntryIds.contains(where: references.contains) }
        let removedGroups = affected.filter { $0.memberEntryIds.allSatisfy { references.contains($0) } }.map(\.id)
        let observed = config.instances.filter { $0.id == instanceID }.map(\.createdAt)
            + entries.compactMap(\.userModifiedAt)
            + affected.flatMap { Array($0.addedMembers.values) + Array($0.removedMembers.values) }
        return .init(instanceID: instanceID, entryIDs: Array(Set(entries.map(\.id))).sorted(),
            entryUUIDs: Array(Set(entries.map(\.uuid))).sorted(), groupIDs: removedGroups.sorted(),
            updatedGroupIDs: affected.map(\.id).filter { !removedGroups.contains($0) }.sorted(),
            ruleIDs: ruleIDs.sorted(), deletedAt: NivoProviderEditClock.next(after: observed, now: now))
    }

    /// 以同一计划重复删除时不再产生新时间戳，不影响其他提供商及未涉及的默认值。
    static func applying(_ plan: NivoProviderDeletion.Plan, to original: ProviderConfig) -> ProviderConfig {
        var result = original
        let entries = Set(plan.entryIDs + plan.entryUUIDs)
        let groups = Set(plan.groupIDs)
        result.instances.removeAll { $0.id == plan.instanceID }
        result.modelEntries.removeAll { $0.providerInstanceId == plan.instanceID }
        result.modelGroups = result.modelGroups.filter { !groups.contains($0.id) }.map { group in
            var candidate = group
            for member in group.memberEntryIds where entries.contains(member) {
                candidate.removedMembers[member] = max(plan.deletedAt, candidate.removedMembers[member] ?? .distantPast)
                candidate.addedMembers[member] = nil
            }
            candidate.memberEntryIds.removeAll { entries.contains($0) }
            return candidate
        }
        result.agentLoopModelEntryIds.removeAll { entries.contains($0) }
        result.agentLoopGroupIds.removeAll { groups.contains($0) }
        if let id = result.defaultPrimaryGroupId, groups.contains(id) { result.defaultPrimaryGroupId = nil }
        if let id = result.defaultSubGroupId, groups.contains(id) { result.defaultSubGroupId = nil }
        if let id = result.voiceInputGroupId, groups.contains(id) { result.voiceInputGroupId = nil }
        if let id = result.voiceOutputGroupId, groups.contains(id) { result.voiceOutputGroupId = nil }
        if let id = result.visionGroupId, groups.contains(id) { result.visionGroupId = nil }
        result.sessionBindings = repairedBindings(original.sessionBindings, entries: entries, removedGroups: groups, groups: result.modelGroups)
        record([plan.instanceID], at: plan.deletedAt, in: &result.deletedInstances)
        record(Array(entries), at: plan.deletedAt, in: &result.deletedModelEntries)
        record(plan.groupIDs, at: plan.deletedAt, in: &result.deletedModelGroups)
        return result
    }

    private static func repairedBindings(_ original: [String: SessionModelBinding], entries: Set<String>,
                                         removedGroups: Set<String>, groups: [ModelGroup]) -> [String: SessionModelBinding] {
        var result: [String: SessionModelBinding] = [:]
        for (id, binding) in original {
            guard let primary = repairedSource(binding.primarySource, entries: entries, removedGroups: removedGroups, groups: groups) else { continue }
            var candidate = binding
            candidate.primarySource = primary
            candidate.subModelSource = binding.subModelSource.flatMap {
                repairedSource($0, entries: entries, removedGroups: removedGroups, groups: groups)
            }
            result[id] = candidate
        }
        return result
    }

    private static func repairedSource(_ source: SessionModelSource, entries: Set<String>,
                                       removedGroups: Set<String>, groups: [ModelGroup]) -> SessionModelSource? {
        switch source {
        case .directEntry(let id, let composite):
            return entries.contains(id) || composite.map(entries.contains) == true ? nil : source
        case .group(let id, let resolved):
            guard !removedGroups.contains(id) else { return nil }
            guard entries.contains(resolved) else { return source }
            guard let fallback = groups.first(where: { $0.id == id })?.memberEntryIds.first else { return nil }
            return .group(groupId: id, resolvedEntryId: fallback)
        }
    }

    private static func record(_ ids: [String], at date: Date, in values: inout [ProviderConfigTombstone]) {
        var byID = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { lhs, rhs in lhs.deletedAt > rhs.deletedAt ? lhs : rhs })
        for id in ids { byID[id] = .init(id: id, deletedAt: max(date, byID[id]?.deletedAt ?? .distantPast)) }
        values = byID.values.sorted { $0.id < $1.id }
    }
}
