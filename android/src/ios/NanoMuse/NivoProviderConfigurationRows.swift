import Foundation

/// 将可编辑配置编码为有类型的行快照；远端密钥、扩展字段与旧ID映射不属于页面覆盖范围。
enum NivoProviderConfigurationRows {
    typealias Row = NivoProviderSQLPatch.Row

    /// 稳定编码保证字典键顺序不会被误判为用户修改。
    static func snapshot(_ config: ProviderConfig) throws -> NivoProviderSQLPatch.Snapshot {
        .init(rows: [
            .instances: config.instances.enumerated().map { instance($0.element, order: $0.offset) },
            .entries: try config.modelEntries.enumerated().map { try entry($0.element, order: $0.offset) },
            .groups: try config.modelGroups.enumerated().map { try group($0.element, order: $0.offset) },
            .local: selectors(config),
            .bindings: try config.sessionBindings.sorted { $0.key < $1.key }.map {
                ["session_id": .text($0.key), "binding_json": .text(try json($0.value))]
            },
            .inference: try config.sessionInferenceConfigs.sorted { $0.key < $1.key }.map {
                ["session_id": .text($0.key), "config_json": .text(try json($0.value))]
            },
            .agentLoop: selections(config.agentLoopModelEntryIds, kind: "entry")
                + selections(config.agentLoopGroupIds, kind: "group"),
        ])
    }

    private static func instance(_ value: ProviderInstance, order: Int) -> Row {
        ["id": .text(value.id), "label": .text(value.label),
         "provider_type": .text(value.unknownProviderTypeRaw ?? value.providerType.rawValue),
         "credential_type": .text(value.credentialType.rawValue),
         "custom_base_url": .text(value.customBaseURL),
         "append_v1_suffix": .integer(value.appendV1Suffix ? 1 : 0),
         "image_endpoint_mode": .text(value.imageEndpointMode.rawValue),
         "image_endpoint_resolved": .text(value.imageEndpointResolved?.rawValue),
         "is_enabled": .integer(value.isEnabled ? 1 : 0), "sort_order": .integer(Int64(order)),
         "created_at": .real(value.createdAt.timeIntervalSince1970),
         "custom_user_agent": .text(value.customUserAgent), "azure_mode": .integer(value.azureMode ? 1 : 0)]
    }

    private static func entry(_ value: ModelEntry, order: Int) throws -> Row {
        ["id": .text(value.uuid), "provider_instance_id": .text(value.providerInstanceId),
         "base_model_json": .text(try json(value.baseModel)),
         "overrides_json": .text(value.overrides.isEmpty ? nil : try json(value.overrides)),
         "is_custom": .integer(value.isCustom ? 1 : 0), "is_hidden": .integer(value.isHidden ? 1 : 0),
         "user_modified_at": .real(value.userModifiedAt?.timeIntervalSince1970),
         "sort_order": .integer(Int64(order))]
    }

    private static func group(_ value: ModelGroup, order: Int) throws -> Row {
        ["id": .text(value.id), "name": .text(value.name), "strategy": .text(value.strategy.rawValue),
         "fallback_strategy": .text(value.fallbackStrategy.rawValue),
         "default_thinking_level": .text(value.defaultThinkingLevel?.rawValue),
         "context_limit_tokens": .integer(value.contextLimitTokens.map(Int64.init)),
         "context_limit_remembered": .integer(value.lastContextLimitTokens.map(Int64.init)),
         "member_entry_ids_json": .text(try json(value.memberEntryIds)),
         "added_members_json": .text(try json(value.addedMembers.mapValues { $0.timeIntervalSince1970 })),
         "removed_members_json": .text(try json(value.removedMembers.mapValues { $0.timeIntervalSince1970 })),
         "sort_order": .integer(Int64(order))]
    }

    private static func selectors(_ config: ProviderConfig) -> [Row] {
        let values = ["defaultPrimaryGroupId": config.defaultPrimaryGroupId,
                      "defaultSubGroupId": config.defaultSubGroupId,
                      "voiceInputGroupId": config.voiceInputGroupId,
                      "voiceOutputGroupId": config.voiceOutputGroupId,
                      "visionGroupId": config.visionGroupId]
        return values.keys.sorted().compactMap { key in
            guard let value = values[key] ?? nil else { return nil }
            return ["key": .text(key), "value": .text(value)]
        }
    }

    private static func selections(_ identifiers: [String], kind: String) -> [Row] {
        identifiers.enumerated().map {
            ["kind": .text(kind), "target_id": .text($0.element), "sort_order": .integer(Int64($0.offset))]
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
