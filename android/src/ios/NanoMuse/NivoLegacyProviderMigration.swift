import Foundation

/// 将旧的单提供商配置增量加入现有配置，所有秘密只在本次操作的内存和Keychain中。
@MainActor
enum NivoLegacyProviderMigration {
    typealias Slot = NivoProviderMigrationPlan.Slot
    static let configurationFlag = "io.github.nanomuse.app.provider-migration-v1-done"
    static let oauthFlag = "io.github.nanomuse.app.provider-migration-oauth-v2-done"

    /// 一项旧凭证及其附属资料；不编码到恢复日志或调试日志。
    struct Source {
        let slot: Slot
        let provider: ProviderType
        let credential: ProviderCredential
        let label: String
        let legacyMode: String
        let service: String
        let raw: Data
        let value: Data
        var metadata: [String: String] = [:]
        var legacyAccount: String { credential == .apiKey ? "api-key" : "token" }
    }

    private struct LegacySettings: Decodable {
        var primaryModelIds: [String]
        var subModelIds: [String]
    }

    /// 先等待启动恢复与数据库权威快照，再固定迁移身份、提交配置并清理旧来源。
    static func run(store: ProviderConfigStore) async throws {
        await NanoMuseAccountData.shared.start()
        let journal = NivoProviderMigrationJournal(fileURL: ProviderConfigStore.configFileURLForBackup
            .deletingLastPathComponent().appendingPathComponent("provider-legacy-migration.json"))
        let initial = try journal.read()
        try await store.nmWaitForMigrationBaseline(retryingFailedWrites: initial?.phase != .completed)
        if initial?.phase == .completed { return }
        let lease = try NivoPersonalBackupAccess.beginProviderRestore(personalLeaseID: nil)
        defer { NivoPersonalBackupAccess.endProviderRestore(lease); store.nmEndRestore(lease) }
        try await store.nmBeginRestore(lease, retryingFailedWrites: true)
        let existing = try journal.read()
        let sources = try readSources(store: store, pending: existing)
        let targets = try existing?.targets ?? selectTargets(sources: sources, config: store.config)
        let plan = try journal.prepare(targets: targets)
        let candidate = try configuration(current: store.config, sources: sources, plan: plan)
        try await NivoProviderMigrationTransaction.run(journal: journal, plan: plan,
            prepareCredentials: { try install(sources: sources, plan: plan) },
            persistConfiguration: { try await store.nmCommitLegacyMigration(candidate, token: lease) },
            verifyCredentials: {
                try verify(sources: sources, plan: plan)
                try verifyPlannedTargets(plan, config: store.config)
            },
            cleanupLegacy: { try cleanup(sources: sources) })
        UserDefaults.standard.set(true, forKey: configurationFlag)
        UserDefaults.standard.set(true, forKey: oauthFlag)
    }

    private static func readSources(store: ProviderConfigStore, pending: NivoProviderMigrationPlan?) throws -> [Source] {
        var result: [Source] = []
        for slot in Slot.allCases {
            let spec = specification(slot)
            let wasPlanned = pending?.targets[slot.rawValue] != nil
            if spec.credential == .apiKey, UserDefaults.standard.bool(forKey: configurationFlag), !wasPlanned { continue }
            guard let raw = try NivoProviderOAuthKeychain.readLegacy(service: spec.service, account: spec.legacyAccount) else { continue }
            let value = try canonical(raw, credential: spec.credential, provider: spec.provider)
            // 旧版已确认完成且现有登录可用时不重新加入历史账户，未完成日志始终优先恢复。
            let metadata = slot == .geminiOAuth ? try geminiMetadata() : [:]
            let needsGeminiMetadata = !metadata.isEmpty
            if spec.credential == .oauth, UserDefaults.standard.bool(forKey: oauthFlag), !wasPlanned, !needsGeminiMetadata,
               try hasAuthenticatedInstance(spec.provider, config: store.config) { continue }
            var source = Source(slot: slot, provider: spec.provider, credential: spec.credential,
                label: spec.label, legacyMode: spec.legacyMode, service: spec.service, raw: raw, value: value)
            source.metadata = metadata
            result.append(source)
        }
        // 令牌已在上次清理中删除但附属资料还未清理时，使用计划绑定的原目标继续核对。
        if let target = pending?.targets[Slot.geminiOAuth.rawValue],
           !result.contains(where: { $0.slot == .geminiOAuth }) {
            let metadata = try geminiMetadata()
            if !metadata.isEmpty {
                guard let raw = try ProviderKeychainHelper.loadRawOAuthTokenStrict(instanceId: target) else {
                    throw NivoOAuthPersistenceError.verificationFailed
                }
                let spec = specification(.geminiOAuth)
                result.append(Source(slot: .geminiOAuth, provider: .gemini, credential: .oauth,
                    label: spec.label, legacyMode: spec.legacyMode, service: spec.service,
                    raw: Data(), value: try canonical(raw, credential: .oauth, provider: .gemini), metadata: metadata))
            }
        }
        return result
    }

    /// 来源已被上次成功清理时仍要核对目标凭证，不能只凭阶段确认完成。
    private static func verifyPlannedTargets(_ plan: NivoProviderMigrationPlan, config: ProviderConfig) throws {
        for (rawSlot, target) in plan.targets {
            guard let slot = Slot(rawValue: rawSlot), config.instances.contains(where: { $0.id == target }) else {
                throw NivoPersonalBackupError.snapshotChanged
            }
            guard try readDestination(target, source: specification(slot)) != nil else {
                throw NivoOAuthPersistenceError.verificationFailed
            }
        }
    }

    private static func hasAuthenticatedInstance(_ provider: ProviderType, config: ProviderConfig) throws -> Bool {
        for instance in config.instances where instance.providerType == provider && instance.credentialType == .oauth {
            if try ProviderKeychainHelper.loadRawOAuthTokenStrict(instanceId: instance.id) != nil { return true }
        }
        return false
    }

    private static func selectTargets(sources: [Source], config: ProviderConfig) throws -> [String: String] {
        var result: [String: String] = [:]
        for source in sources {
            var matches: [String] = []
            var empty: [String] = []
            for instance in config.instances where instance.providerType == source.provider
                && instance.credentialType == source.credential && instance.customBaseURL == nil {
                let value = try readDestination(instance.id, source: source)
                if value == source.value { matches.append(instance.id) }
                else if value == nil { empty.append(instance.id) }
            }
            // 只复用唯一明确匹配或唯一未配置OAuth实例，不任意覆盖另一个账户。
            let target = matches.count == 1 ? matches[0]
                : (matches.isEmpty && empty.count == 1 && source.credential == .oauth ? empty[0] : UUID().uuidString)
            result[source.slot.rawValue] = target
        }
        return result
    }

    /// 新记录按日志固定身份加入；已有实例、模型和默认选择全部保留。
    static func configuration(current: ProviderConfig, sources: [Source], plan: NivoProviderMigrationPlan) throws -> ProviderConfig {
        var result = current
        for (rawSlot, identifier) in plan.targets {
            guard let slot = Slot(rawValue: rawSlot) else { throw CocoaError(.fileReadCorruptFile) }
            let spec = specification(slot)
            if let saved = result.instances.first(where: { $0.id == identifier }) {
                guard saved.providerType == spec.provider, saved.credentialType == spec.credential else {
                    throw NivoPersonalBackupError.snapshotChanged
                }
                continue
            }
            guard plan.phase == .prepared, sources.contains(where: { $0.slot == slot }) else {
                throw NivoPersonalBackupError.snapshotChanged
            }
            result.instances.append(ProviderInstance(id: identifier, label: spec.label,
                providerType: spec.provider, credentialType: spec.credential, createdAt: plan.createdAt))
            result.modelEntries.append(contentsOf: models(spec.provider).map { ModelEntry(providerInstanceId: identifier, model: $0) })
        }
        try addDefaultGroups(to: &result, sources: sources, plan: plan)
        return result
    }

    private static func addDefaultGroups(to config: inout ProviderConfig, sources: [Source], plan: NivoProviderMigrationPlan) throws {
        guard config.defaultPrimaryGroupId == nil, config.modelGroups.isEmpty else { return }
        guard let raw = try NivoProviderOAuthKeychain.readLegacy(service: "io.github.nanomuse.app.active-provider", account: "auth-mode"),
              let active = String(data: raw, encoding: .utf8),
              let source = sources.first(where: { $0.legacyMode == active }), let target = plan.targets[source.slot.rawValue] else { return }
        let entries = config.modelEntries.filter { $0.providerInstanceId == target }
        guard !entries.isEmpty else { return }
        let settings: LegacySettings
        if let data = UserDefaults.standard.data(forKey: "io.github.nanomuse.app.agent-model-settings") {
            settings = try JSONDecoder().decode(LegacySettings.self, from: data)
        } else { settings = LegacySettings(primaryModelIds: [LLMModel.claudeSonnet46.id], subModelIds: []) }
        let primary = entries.filter { settings.primaryModelIds.contains($0.model.id) }
        config.modelGroups.append(ModelGroup(id: plan.primaryGroupID, name: "Default",
            memberEntryIds: (primary.isEmpty ? entries : primary).map(\.id)))
        config.defaultPrimaryGroupId = plan.primaryGroupID
        let sub = entries.filter { settings.subModelIds.contains($0.model.id) }
        if !sub.isEmpty, settings.subModelIds != settings.primaryModelIds, config.defaultSubGroupId == nil {
            config.modelGroups.append(ModelGroup(id: plan.subGroupID, name: "Sub Tasks", memberEntryIds: sub.map(\.id)))
            config.defaultSubGroupId = plan.subGroupID
        }
    }

    private static func install(sources: [Source], plan: NivoProviderMigrationPlan) throws {
        for source in sources {
            guard let target = plan.targets[source.slot.rawValue] else { throw NivoPersonalBackupError.snapshotChanged }
            try NivoOAuthPersistence.copyMissing(source.value,
                read: { try readDestination(target, source: source) },
                write: { value in
                    if source.credential == .apiKey {
                        guard let key = String(data: value, encoding: .utf8) else { throw NivoOAuthPersistenceError.invalidValue }
                        try NivoCredentialSyncKeychain.saveLocalProvider(key, instanceID: target)
                    } else { try ProviderKeychainHelper.saveRawOAuthToken(value, instanceId: target) }
                })
            for (account, value) in source.metadata {
                try NivoOAuthPersistence.copyMissing(Data(value.utf8),
                    read: { try NivoProviderOAuthKeychain.read(instanceID: target, account: account) },
                    write: { _ in try ProviderKeychainHelper.saveOAuthString(value, instanceId: target, account: account) })
            }
        }
    }

    private static func verify(sources: [Source], plan: NivoProviderMigrationPlan) throws {
        for source in sources {
            guard let target = plan.targets[source.slot.rawValue], try readDestination(target, source: source) == source.value else {
                throw NivoOAuthPersistenceError.verificationFailed
            }
            for (account, value) in source.metadata {
                guard try ProviderKeychainHelper.loadOAuthStringStrict(instanceId: target, account: account) == value else {
                    throw NivoOAuthPersistenceError.verificationFailed
                }
            }
        }
    }

    private static func cleanup(sources: [Source]) throws {
        for source in sources where source.credential == .oauth {
            if !source.raw.isEmpty {
                try NivoProviderOAuthKeychain.removeLegacy(service: source.service, account: source.legacyAccount, expected: source.raw)
            }
            for (account, value) in source.metadata {
                let key = account == "oauth-email" ? GeminiOAuthManager.legacyEmailKey : GeminiOAuthManager.legacyProjectIDKey
                guard UserDefaults.standard.string(forKey: key) == value else { throw NivoPersonalBackupError.snapshotChanged }
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private static func readDestination(_ target: String, source: Source) throws -> Data? {
        if source.credential == .apiKey { return try NivoCredentialSyncKeychain.providerValue(instanceID: target) }
        guard let data = try ProviderKeychainHelper.loadRawOAuthTokenStrict(instanceId: target) else { return nil }
        return try canonical(data, credential: source.credential, provider: source.provider)
    }

    private static func canonical(_ data: Data, credential: ProviderCredential, provider: ProviderType) throws -> Data {
        guard !data.isEmpty, data.count <= 1_048_576 else { throw NivoOAuthPersistenceError.invalidValue }
        if credential == .apiKey {
            guard String(data: data, encoding: .utf8) != nil else { throw NivoOAuthPersistenceError.invalidValue }
            return data
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            switch provider {
            case .anthropic: return try encoder.encode(JSONDecoder().decode(ClaudeTokenStorage.self, from: data))
            case .gemini: return try encoder.encode(JSONDecoder().decode(GeminiTokenStorage.self, from: data))
            case .openAI: return try encoder.encode(JSONDecoder().decode(CodexTokenStorage.self, from: data))
            default: throw NivoOAuthPersistenceError.invalidValue
            }
        } catch { throw NivoOAuthPersistenceError.invalidValue }
    }

    private static func geminiMetadata() throws -> [String: String] {
        var result: [String: String] = [:]
        for (account, key) in [("oauth-email", GeminiOAuthManager.legacyEmailKey), ("oauth-gcp-project", GeminiOAuthManager.legacyProjectIDKey)] {
            guard let object = UserDefaults.standard.object(forKey: key) else { continue }
            guard let value = object as? String, !value.isEmpty else { throw NivoOAuthPersistenceError.invalidValue }
            result[account] = value
        }
        return result
    }

    private static func models(_ provider: ProviderType) -> [LLMModel] {
        switch provider {
        case .anthropic: return LLMModel.allAnthropic
        case .gemini: return LLMModel.allGemini
        case .openAI: return LLMModel.allOpenAI
        default: return []
        }
    }

    private static func specification(_ slot: Slot) -> Source {
        let values: (ProviderType, ProviderCredential, String, String, String)
        switch slot {
        case .anthropicAPI: values = (.anthropic, .apiKey, "Anthropic API Key", "API Key", "anthropic-api-key")
        case .anthropicOAuth: values = (.anthropic, .oauth, "Claude OAuth", "OAuth", "claude-oauth")
        case .geminiAPI: values = (.gemini, .apiKey, "Gemini API Key", "Gemini API Key", "gemini-api-key")
        case .geminiOAuth: values = (.gemini, .oauth, "Gemini OAuth", "Gemini OAuth", "gemini-oauth")
        case .openAIAPI: values = (.openAI, .apiKey, "OpenAI API Key", "OpenAI API Key", "openai-api-key")
        case .openAIOAuth: values = (.openAI, .oauth, "Codex OAuth", "Codex OAuth", "openai-oauth")
        }
        return Source(slot: slot, provider: values.0, credential: values.1, label: values.2,
            legacyMode: values.3, service: "io.github.nanomuse.app." + values.4, raw: Data(), value: Data())
    }
}
