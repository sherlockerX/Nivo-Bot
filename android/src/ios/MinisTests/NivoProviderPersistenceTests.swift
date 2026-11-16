import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// Apple应用目标直接验证提供商仓库，使用独立SQLite文件，不修改共享配置。
@MainActor
final class NivoProviderPersistenceTests: XCTestCase {
    /// 替换密钥不改变用户模型身份、人工命名、隐藏状态与既有会话绑定。
    func testProviderUpdateKeepsModelIdentityAndUserOverrides() throws {
        var current = fixture()
        current.modelEntries[0].overrides.displayName = "fixture-override"
        current.modelEntries[0].isHidden = true
        let original = current.modelEntries[0]
        let prepared = try NivoProviderSetupConfiguration.updating(instance: current.instances[0], current: current,
            models: [original.baseModel, original.baseModel], defaultChatModel: nil)
        let saved = try XCTUnwrap(prepared.configuration.modelEntries.first)
        XCTAssertEqual(saved.uuid, original.uuid)
        XCTAssertEqual(saved.overrides, original.overrides)
        XCTAssertTrue(saved.isHidden)
        XCTAssertEqual(prepared.configuration.modelEntries.count, 1)
        XCTAssertEqual(prepared.configuration.sessionBindings, current.sessionBindings)
        XCTAssertTrue(prepared.credentials.isEmpty)
    }

    /// 模型下架造成空组也要上传组历史，同时不产生远端模型删除。
    func testProviderUpdateQueuesAnEmptiedGroupWithCausalRemoval() throws {
        var current = fixture()
        let entry = current.modelEntries[0]
        let future = Date(timeIntervalSince1970: 9_000_000_000)
        current.modelGroups = [.init(id: "emptied", name: "fixture", memberEntryIds: [entry.id],
            addedMembers: [entry.id: future])]
        let model = LLMModel(id: "replacement", displayName: "Fixture", provider: "OpenAI")
        let prepared = try NivoProviderSetupConfiguration.updating(instance: current.instances[0], current: current,
            models: [model], defaultChatModel: nil)
        let group = try XCTUnwrap(prepared.configuration.modelGroups.first)
        XCTAssertTrue(group.memberEntryIds.isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(group.removedMembers[entry.id]), future)
        XCTAssertNil(group.addedMembers[entry.id])
        XCTAssertTrue(prepared.configuration.agentLoopModelEntryIds.isEmpty)
        XCTAssertEqual(NivoProviderSetupConfiguration.syncPlan(prepared, previous: current).groupIDs, [group.id])
    }

    /// 暂时缩小的接口目录保留不可用引用，自定义模型不会被目录裁剪。
    func testProviderUpdatePreservesCustomModelsAndSuspiciousShrinkReferences() throws {
        var current = fixture()
        let provider = current.instances[0]
        current.modelEntries += (1...4).map { index in
            ModelEntry(providerInstanceId: provider.id,
                model: LLMModel(id: "fixture-\(index)", displayName: "Fixture", provider: "OpenAI"), isCustom: index == 4)
        }
        current.modelGroups = [.init(name: "fixture", memberEntryIds: current.modelEntries.map(\.id))]
        let prepared = try NivoProviderSetupConfiguration.updating(instance: provider, current: current,
            models: [current.modelEntries[0].baseModel], defaultChatModel: nil)
        XCTAssertEqual(prepared.configuration.modelEntries.count, 2)
        XCTAssertTrue(prepared.configuration.modelEntries.contains { $0.baseModel.id == "fixture-4" && $0.isCustom })
        XCTAssertEqual(prepared.configuration.modelGroups, current.modelGroups)
    }

    /// 更新的来源实例已被改名或删除时不能把旧网络结果保存到新配置。
    func testProviderUpdateRejectsChangedInstanceAndPreservesUnavailableModelCatalog() throws {
        var current = fixture()
        let source = current.instances[0]
        let unchanged = try NivoProviderSetupConfiguration.updating(instance: source, current: current,
            models: [], defaultChatModel: nil)
        XCTAssertEqual(unchanged.configuration, current)
        current.instances[0].label = "later"
        XCTAssertThrowsError(try NivoProviderSetupConfiguration.updating(instance: source, current: current,
            models: [], defaultChatModel: nil))
    }

    /// 接口未列出的语音种子仍在，接口同名型号不能覆盖模板中的音频能力。
    func testProviderUpdateKeepsVoiceSeedsAndTheirModalities() throws {
        let template = try XCTUnwrap(VoiceProviderTemplate.all.first)
        let instance = ProviderInstance(id: "voice", label: "fixture", providerType: template.providerType,
            credentialType: .apiKey, customBaseURL: template.baseURL, appendV1Suffix: template.appendV1)
        var current = ProviderConfig.empty
        current.instances = [instance]
        current.modelEntries = VoiceProviderTemplate.mockEntries(for: instance)
        let seed = try XCTUnwrap(current.modelEntries.first)
        let reported = LLMModel(id: seed.baseModel.id, displayName: "Fixture", provider: "fixture", modalityOverride: [.textInput, .textOutput])
        let prepared = try NivoProviderSetupConfiguration.updating(instance: instance, current: current,
            models: [reported], defaultChatModel: nil)
        let saved = try XCTUnwrap(prepared.configuration.modelEntries.first { $0.id == seed.id })
        XCTAssertEqual(saved.baseModel.modalityOverride, seed.baseModel.modalityOverride)
        XCTAssertEqual(Set(prepared.configuration.modelEntries.map(\.uuid)), Set(current.modelEntries.map(\.uuid)))
    }

    /// 正式端点不能通过绕过表单校验创建空密钥提供商。
    func testProviderSetupRejectsEmptyKeyForOfficialEndpoint() throws {
        let instance = ProviderInstance(label: "fixture", providerType: .openAI, credentialType: .apiKey)
        XCTAssertThrowsError(try NivoProviderSetupConfiguration.prepare(instance: instance, apiKey: "", current: fixture()))
    }

    /// 首次配置的模型与默认组进入同一候选，已有默认选择继续保留。
    func testProviderSetupIncludesFetchedModelsAndPreservesExistingDefault() throws {
        var current = fixture()
        current.defaultPrimaryGroupId = "existing-group"
        let instance = ProviderInstance(id: "new-provider", label: "fixture", providerType: .openAI, credentialType: .apiKey)
        let model = LLMModel(id: "fixture-text", displayName: "Fixture", provider: "OpenAI", modalityOverride: [.textInput, .textOutput])
        let prepared = try NivoProviderSetupConfiguration.prepare(instance: instance, apiKey: "fixture-value", current: current,
            models: [model, model], defaultChatModel: model.id)
        let entries = prepared.configuration.modelEntries.filter { $0.providerInstanceId == instance.id }
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(prepared.configuration.modelGroups.contains { $0.memberEntryIds == entries.map(\.id) })
        XCTAssertEqual(prepared.configuration.defaultPrimaryGroupId, "existing-group")
        XCTAssertEqual(prepared.credentials.map(\.target.kind), [.providerAPIKey])
    }

    /// 手动授权令牌也先形成待提交凭证，准备失败时不会写正式Keychain。
    func testManualOAuthSetupPreparesCredentialAndBuiltInModels() throws {
        let instance = ProviderInstance(id: "manual-provider", label: "fixture", providerType: .anthropic, credentialType: .oauth)
        let prepared = try NivoProviderSetupConfiguration.prepareOAuth(instance: instance, manualToken: "fixture-token", current: fixture())
        XCTAssertEqual(prepared.credentials.map(\.target.kind), [.providerManualToken])
        XCTAssertEqual(prepared.credentials.first?.target.owner, instance.id)
        XCTAssertFalse(prepared.configuration.modelEntries.filter { $0.providerInstanceId == instance.id }.isEmpty)
        XCTAssertThrowsError(try NivoProviderSetupConfiguration.prepareOAuth(instance: instance, manualToken: "  ", current: fixture()))
    }

    /// 已取得模型目录时采用实际列表，不重新加入已经不再提供的OAuth内置型号。
    func testOAuthSetupWithFetchedModelsDoesNotAddFallbackModels() throws {
        let instance = ProviderInstance(id: "oauth-provider", label: "fixture", providerType: .openAI, credentialType: .oauth)
        let model = LLMModel(id: "fixture-only", displayName: "Fixture", provider: "OpenAI", modalityOverride: [.textInput, .textOutput])
        let prepared = try NivoProviderSetupConfiguration.prepareOAuth(instance: instance, manualToken: nil,
            current: fixture(), models: [model], defaultChatModel: model.id)
        XCTAssertEqual(prepared.configuration.modelEntries.filter { $0.providerInstanceId == instance.id }.map(\.baseModel.id), [model.id])
        XCTAssertTrue(prepared.credentials.isEmpty)
    }

    /// 服务商列表遗漏音频标记时，新增也必须保留模板中的真实语音能力。
    func testSetupKeepsVoiceTemplateCapabilitiesWhenAPIReportsTextOnly() throws {
        let template = try XCTUnwrap(VoiceProviderTemplate.all.first)
        let voice = try XCTUnwrap(template.mockModels.first)
        let instance = ProviderInstance(id: "voice-provider", label: "fixture", providerType: template.providerType,
            credentialType: .apiKey, customBaseURL: template.baseURL, appendV1Suffix: template.appendV1)
        let model = LLMModel(id: voice.id, displayName: "Fixture", provider: "fixture", modalityOverride: [.textInput, .textOutput])
        let prepared = try NivoProviderSetupConfiguration.prepare(instance: instance, apiKey: "fixture-value",
            current: fixture(), models: [model])
        let saved = try XCTUnwrap(prepared.configuration.modelEntries.first { $0.providerInstanceId == instance.id && $0.baseModel.id == voice.id })
        XCTAssertEqual(saved.baseModel.modalityOverride, voice.modalityOverride)
    }


    /// 无密钥端点仍构造完整配置候选，不生成空秘密或提前修改原配置。
    func testKeylessProviderSetupKeepsExistingConfigurationAndNoCredentialWrite() throws {
        let current = fixture()
        let instance = ProviderInstance(id: "keyless", label: "fixture-keyless", providerType: .openAI,
            credentialType: .apiKey, customBaseURL: "http://localhost:11434")
        let prepared = try NivoProviderSetupConfiguration.prepare(instance: instance, apiKey: "", current: current)
        XCTAssertEqual(prepared.configuration.instances.map(\.id), ["provider", "keyless"])
        XCTAssertEqual(prepared.configuration.sessionBindings, current.sessionBindings)
        XCTAssertTrue(prepared.credentials.isEmpty)
        XCTAssertEqual(current.instances.map(\.id), ["provider"])
    }

    /// 同一身份不能把已有服务商或删除历史变成新建请求，避免覆盖原凭证。
    func testProviderSetupRejectsExistingOrDeletedIdentityBeforeCredentialPlan() throws {
        var current = fixture()
        let instance = try XCTUnwrap(current.instances.first)
        XCTAssertThrowsError(try NivoProviderSetupConfiguration.prepare(instance: instance, apiKey: nil, current: current))
        current.instances.removeAll()
        current.deletedInstances = [.init(id: instance.id, deletedAt: Date())]
        XCTAssertThrowsError(try NivoProviderSetupConfiguration.prepare(instance: instance, apiKey: nil, current: current))
    }

    /// 删除同时清理两类模型标识，其他提供商和主动创建的空组均保留。
    func testProviderDeletionKeepsUnrelatedEmptyGroupAndRepairsSelection() throws {
        var original = fixture()
        let removed = try XCTUnwrap(original.instances.first)
        let entry = try XCTUnwrap(original.modelEntries.first)
        original.modelGroups = [ModelGroup(id: "removed", name: "fixture", memberEntryIds: [entry.id]),
            ModelGroup(id: "empty", name: "empty", memberEntryIds: [])]
        original.defaultPrimaryGroupId = "removed"
        original.voiceOutputGroupId = "removed"
        original.agentLoopGroupIds = ["removed", "empty"]
        original.agentLoopModelEntryIds = [entry.uuid, entry.id]
        let plan = NivoProviderDeletionConfiguration.plan(instanceID: removed.id, config: original,
            ruleIDs: ["custom-rule"], now: Date())
        let candidate = NivoProviderDeletionConfiguration.applying(plan, to: original)
        XCTAssertEqual(plan.entryUUIDs, [entry.uuid])
        XCTAssertEqual(plan.entryIDs, [entry.id])
        XCTAssertEqual(candidate.modelGroups.map(\.id), ["empty"])
        XCTAssertNil(candidate.defaultPrimaryGroupId)
        XCTAssertNil(candidate.voiceOutputGroupId)
        XCTAssertEqual(candidate.agentLoopGroupIds, ["empty"])
        XCTAssertTrue(candidate.agentLoopModelEntryIds.isEmpty)
        XCTAssertEqual(Set(candidate.deletedModelEntries.map(\.id)), Set([entry.uuid, entry.id]))
    }

    /// 混合分组保留其他模型，并修正原来解析到已删除模型的会话绑定。
    func testProviderDeletionRepairsMixedGroupAndSubModelBinding() throws {
        var original = fixture()
        let removed = try XCTUnwrap(original.instances.first)
        let entry = try XCTUnwrap(original.modelEntries.first)
        original.modelGroups = [ModelGroup(id: "mixed", name: "fixture", memberEntryIds: [entry.id, "other-entry"])]
        original.sessionBindings["bound"] = .init(sessionId: "bound",
            primarySource: .group(groupId: "mixed", resolvedEntryId: entry.id),
            subModelSource: .directEntry(modelEntryId: entry.uuid))
        let plan = NivoProviderDeletionConfiguration.plan(instanceID: removed.id, config: original, ruleIDs: [], now: Date())
        let candidate = NivoProviderDeletionConfiguration.applying(plan, to: original)
        XCTAssertEqual(plan.updatedGroupIDs, ["mixed"])
        XCTAssertEqual(candidate.modelGroups.first?.memberEntryIds, ["other-entry"])
        XCTAssertEqual(candidate.sessionBindings["bound"]?.primarySource, .group(groupId: "mixed", resolvedEntryId: "other-entry"))
        XCTAssertNil(candidate.sessionBindings["bound"]?.subModelSource)
        XCTAssertEqual(candidate.modelGroups.first?.removedMembers[entry.id], plan.deletedAt)
        XCTAssertEqual(NivoProviderDeletionConfiguration.applying(plan, to: candidate), candidate)
    }

    /// 普通删除与其他恢复一样等待实际数据库及JSON保存，单元测试不访问共享凭证。
    func testProviderDeletionPersistsDatabaseAndJSONBeforePublishing() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.json")
        let original = fixture()
        try JSONEncoder().encode(original).write(to: url)
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.sqlite"))
        try await database.nmBulkReplace(from: original)
        let store = ProviderConfigStore(fileURL: url, database: database)
        let token = UUID()
        try await store.nmBeginRestore(token)
        defer { store.nmEndRestore(token) }
        let proposed = try await store.nmPrepareProviderDeletion(instanceID: original.instances[0].id, token: token)
        let plan = try XCTUnwrap(proposed)
        try await store.nmPersistProviderDeletion(plan, token: token)
        XCTAssertFalse(store.config.instances.contains { $0.id == plan.instanceID })
        let saved = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved, store.config)
        let persisted = try await database.nmDumpProviderConfig()
        XCTAssertFalse(persisted.instances.contains { $0.id == plan.instanceID })
    }

    /// 数据库已删除但JSON写入失败时不发布成功，重放同一计划补齐镜像及墓碑。
    func testProviderDeletionRetriesAfterJSONFailure() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.json")
        let original = fixture()
        try JSONEncoder().encode(original).write(to: url)
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.sqlite"))
        try await database.nmBulkReplace(from: original)
        let store = ProviderConfigStore(fileURL: url, database: database)
        let token = UUID()
        try await store.nmBeginRestore(token)
        defer { store.nmEndRestore(token) }
        let proposed = try await store.nmPrepareProviderDeletion(instanceID: original.instances[0].id, token: token)
        let plan = try XCTUnwrap(proposed)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do { try await store.nmPersistProviderDeletion(plan, token: token); XCTFail("应传播镜像写入错误") }
        catch {}
        XCTAssertEqual(store.config, original)
        try FileManager.default.removeItem(at: url)
        try await store.nmPersistProviderDeletion(plan, token: token)
        let saved = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: url))
        XCTAssertTrue(saved.instances.isEmpty)
        XCTAssertTrue(saved.deletedInstances.contains { $0.id == plan.instanceID })
    }

    /// 较新规则正文不能解码时仍保留其删除ID，不遗漏同步墓碑。
    func testProviderDeletionInventoryIncludesUnsupportedRules() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.sqlite")
        let database = try ProviderConfigDB(url: url)
        try executeSQL(url, sql: """
            INSERT INTO provider_thinking_rules
                (id, instance_id, sort_order, scope_kind, wire_format_json, updated_at)
            VALUES ('future-rule', 'provider', 0, 'future', '{unknown}', 500)
            """)
        let inventory = try await database.nmProviderDeletionInventory(instanceID: "provider")
        XCTAssertEqual(inventory.ruleIDs, ["future-rule"])
        XCTAssertGreaterThan(inventory.lastModified.timeIntervalSince1970, 500)
        try await database.nmDeleteProviderRules(instanceID: "provider")
        let after = try await database.nmProviderDeletionInventory(instanceID: "provider")
        XCTAssertTrue(after.ruleIDs.isEmpty)
    }

    /// 删除已经提交后重载权威数据库，JSON中的旧协议墓碑不能被空数据库覆盖。
    func testProviderDeletionReloadKeepsLegacyDeletionMetadata() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.json")
        var original = fixture()
        original.instances.append(.init(id: "kept-provider", label: "fixture-kept", providerType: .openAI, credentialType: .apiKey))
        try JSONEncoder().encode(original).write(to: url)
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.sqlite"))
        try await database.nmBulkReplace(from: original)
        let store = ProviderConfigStore(fileURL: url, database: database)
        let token = UUID()
        try await store.nmBeginRestore(token)
        defer { store.nmEndRestore(token) }
        let proposed = try await store.nmPrepareProviderDeletion(instanceID: original.instances[0].id, token: token)
        let plan = try XCTUnwrap(proposed)
        try await store.nmPersistProviderDeletion(plan, token: token)
        let expected = store.config
        try await store.nmReloadFromDisk()
        XCTAssertEqual(store.config.deletedInstances, expected.deletedInstances)
        XCTAssertEqual(store.config.deletedModelEntries, expected.deletedModelEntries)
        XCTAssertEqual(store.config.instances.map(\.id), ["kept-provider"])
    }

    /// 分组字段可能晚于成员历史，删除计划仍须晚于数据库中已见的组版本。
    func testProviderDeletionPlanObservesGroupDatabaseVersion() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.json")
        let databaseURL = root.appendingPathComponent("provider.sqlite")
        var original = fixture()
        original.modelGroups = [ModelGroup(id: "affected", name: "fixture", memberEntryIds: original.modelEntries.map(\.id))]
        try JSONEncoder().encode(original).write(to: url)
        let database = try ProviderConfigDB(url: databaseURL)
        try await database.nmBulkReplace(from: original)
        let observed = Date().addingTimeInterval(10_000).timeIntervalSince1970
        try executeSQL(databaseURL, sql: "UPDATE provider_model_groups SET updated_at=\(observed) WHERE id='affected'")
        let store = ProviderConfigStore(fileURL: url, database: database)
        let token = UUID()
        try await store.nmBeginRestore(token)
        defer { store.nmEndRestore(token) }
        let proposed = try await store.nmPrepareProviderDeletion(instanceID: original.instances[0].id, token: token)
        let plan = try XCTUnwrap(proposed)
        XCTAssertGreaterThan(plan.deletedAt.timeIntervalSince1970, observed)
        XCTAssertEqual(plan.groupIDs, ["affected"])
    }

    /// 尾部模型损坏时，候选解析不能提前添加前面的实例或模型。
    func testJSONImportRejectsInvalidModelWithoutChangingStore() throws {
        let root = try directory()
        let store = ProviderConfigStore(fileURL: root.appendingPathComponent("provider.json"))
        let before = store.config
        let input = #"{"providerType":"openAI","label":"fixture","apiKey":"fixture-value","models":[{"modelId":"valid"},{}]}"#
        XCTAssertThrowsError(try store.nmPrepareInstanceImport(input))
        XCTAssertEqual(store.config, before)
    }

    /// 单份候选保留完整模型列表，解析过程没有发布配置或写入凭证。
    func testJSONImportPreparesAllModelsAndCredentialsBeforeMutation() throws {
        let root = try directory()
        let store = ProviderConfigStore(fileURL: root.appendingPathComponent("provider.json"))
        let input = #"{"providerType":"openAI","label":"fixture","apiKey":"fixture-value","models":[{"modelId":"first"},{"modelId":"second"}]}"#
        let prepared = try store.nmPrepareInstanceImport(input)
        XCTAssertEqual(prepared.configuration.instances.count, 1)
        XCTAssertEqual(prepared.configuration.modelEntries.map(\.baseModel.id), ["first", "second"])
        XCTAssertEqual(prepared.credentials.map(\.target.kind), [.providerAPIKey])
        XCTAssertTrue(store.config.instances.isEmpty)
        XCTAssertNil(ProviderKeychainHelper.loadAPIKey(instanceId: prepared.instance.id))
    }

    /// 分享中的重复模型仍按首条去重，不能因改为单次提交而丢失原addEntry规则。
    func testJSONImportKeepsFirstDuplicateModelAndItsUserRevision() throws {
        let root = try directory()
        let store = ProviderConfigStore(fileURL: root.appendingPathComponent("provider.json"))
        let input = #"{"providerType":"openAI","label":"fixture","models":[{"modelId":"same","displayName":"first"},{"modelId":"same","displayName":"second"}]}"#
        let prepared = try store.nmPrepareInstanceImport(input)
        XCTAssertEqual(prepared.configuration.modelEntries.count, 1)
        XCTAssertEqual(prepared.configuration.modelEntries.first?.baseModel.displayName, "first")
        XCTAssertNotNil(prepared.configuration.modelEntries.first?.userModifiedAt)
    }

    /// 不可解析的OAuth不能降级为仅导入API密钥或空认证方式。
    func testJSONImportRejectsMalformedCredentialBeforeMutation() throws {
        let root = try directory()
        let store = ProviderConfigStore(fileURL: root.appendingPathComponent("provider.json"))
        for payload in [
            #"{"providerType":"openAI","label":"fixture","apiKey":"fixture-value","oauthToken":"bad"}"#,
            #"{"providerType":"openAI","label":"fixture","credentialType":"unsupported"}"#,
            #"{"providerType":"openAI","label":"fixture","models":{}}"#
        ] {
            XCTAssertThrowsError(try store.nmPrepareInstanceImport(payload))
            XCTAssertTrue(store.config.instances.isEmpty)
        }
    }

    /// 旧配置迁移仅加入计划中的缺项，现有模型和默认选择保持原值。
    func testLegacyMigrationPlanPreservesCurrentConfiguration() throws {
        var original = fixture()
        original.modelGroups = [ModelGroup(id: "current-group", name: "fixture-group", memberEntryIds: original.modelEntries.map(\.id))]
        original.defaultPrimaryGroupId = "current-group"
        let plan = NivoProviderMigrationPlan(targets: ["geminiOAuth": "provider-migration-fixture"])
        let source = NivoLegacyProviderMigration.Source(slot: .geminiOAuth, provider: .gemini, credential: .oauth,
            label: "Gemini OAuth", legacyMode: "Gemini OAuth", service: "fixture", raw: Data(), value: Data())
        let candidate = try NivoLegacyProviderMigration.configuration(current: original, sources: [source], plan: plan)
        XCTAssertEqual(candidate.instances.first, original.instances.first)
        XCTAssertEqual(candidate.sessionBindings, original.sessionBindings)
        XCTAssertEqual(candidate.defaultPrimaryGroupId, original.defaultPrimaryGroupId)
        XCTAssertEqual(candidate.modelGroups, original.modelGroups)
        XCTAssertEqual(candidate.instances.count, original.instances.count + 1)
        let retried = try NivoLegacyProviderMigration.configuration(current: candidate, sources: [source], plan: plan)
        XCTAssertEqual(retried, candidate)
    }

    /// 已确认配置的目标被删除后重试不会悄悄重新创建它。
    func testCommittedMigrationDoesNotResurrectDeletedProvider() throws {
        var plan = NivoProviderMigrationPlan(targets: ["geminiOAuth": "deleted-fixture"])
        plan.phase = .configurationSaved
        XCTAssertThrowsError(try NivoLegacyProviderMigration.configuration(current: fixture(), sources: [], plan: plan))
    }

    /// 迁移等待JSON与数据库成功后才发布缓存，失败可再次提交同一身份。
    func testLegacyMigrationPersistenceFailureCanRetrySamePlan() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.json")
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        let store = ProviderConfigStore(fileURL: url, database: database)
        let lease = UUID()
        try await store.nmBeginRestore(lease, retryingFailedWrites: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do {
            try await store.nmCommitLegacyMigration(fixture(), token: lease)
            XCTFail("JSON未落盘不得返回成功")
        } catch {}
        XCTAssertTrue(store.config.instances.isEmpty)
        store.nmEndRestore(lease)
        try FileManager.default.removeItem(at: url)
        let retryLease = UUID()
        try await store.nmBeginRestore(retryLease, retryingFailedWrites: true)
        defer { store.nmEndRestore(retryLease) }
        try await store.nmCommitLegacyMigration(fixture(), token: retryLease)
        let saved = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.instances.map(\.id), ["provider"])
        XCTAssertEqual(store.config.instances.map(\.id), ["provider"])
        let persisted = try await database.nmDumpProviderConfig()
        XCTAssertEqual(persisted.instances.map(\.id), ["provider"])
    }

    func testBulkReplaceForeignKeyFailurePreservesOriginalProviderAndBinding() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        let original = fixture()
        try await database.nmBulkReplace(from: original)
        var invalid = original
        invalid.instances = []
        do {
            try await database.nmBulkReplace(from: invalid)
            XCTFail("外键失败后不得提交删除")
        } catch {}
        let restored = await database.dumpProviderConfig()
        XCTAssertEqual(restored.instances.map(\.id), original.instances.map(\.id))
        XCTAssertEqual(restored.modelEntries.map(\.id), original.modelEntries.map(\.id))
        XCTAssertEqual(restored.sessionBindings, original.sessionBindings)
    }

    func testRollbackRestoresThinkingRulesAndLocalSelectionAlongWithProviders() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        let original = fixture()
        try await database.nmBulkReplace(from: original)
        let wrote = try await database.nmUpsertThinkingRule(id: "rule", instanceId: "provider", sortOrder: 0,
            scopeKind: "allModels", scopePattern: nil, wireFormatJson: "{}", echoField: nil,
            echoTiming: nil, label: "original", createdAt: 1, updatedAt: 1)
        XCTAssertTrue(wrote)
        let saved = root.appendingPathComponent("snapshot.db")
        let live = try await database.nmSnapshotForRollback(to: saved)
        try await database.nmBulkReplace(from: .empty)
        _ = try await database.nmUpsertThinkingRule(id: "rule", instanceId: "provider", sortOrder: 0,
            scopeKind: "allModels", scopePattern: nil, wireFormatJson: "{}", echoField: nil,
            echoTiming: nil, label: "imported", createdAt: 1, updatedAt: 2)
        try await database.nmRestoreSnapshot(from: saved, expectedURL: live)
        let restored = await database.dumpProviderConfig()
        let rules = await database.thinkingRuleRow(id: "rule")
        XCTAssertEqual(restored.instances.map(\.id), original.instances.map(\.id))
        XCTAssertEqual(restored.agentLoopModelEntryIds, original.agentLoopModelEntryIds)
        XCTAssertEqual(rules?["label"] as? String, "original")
    }

    func testExplicitRestoreWaitsForJSONAndRejectsSyncPublicationDuringRestore() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.json")
        let store = ProviderConfigStore(fileURL: url)
        let identifier = UUID()
        try await store.nmBeginRestore(identifier)
        defer { store.nmEndRestore(identifier) }
        try await store.nmApplyRestoredConfiguration(fixture())
        store.applyMergedConfigFromSync(.empty)
        try await store.nmWaitForConfigurationWrites()
        let saved = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.instances.map(\.id), ["provider"])
        XCTAssertEqual(store.config.instances.map(\.id), ["provider"])
    }

    func testSynchronizedConfigurationReturnsOnlyAfterJSONIsSaved() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.json")
        let store = ProviderConfigStore(fileURL: url)
        try await store.nmCommitSynchronizedConfiguration(fixture(), expectedRevision: store.configRevision)
        let saved = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved, store.config)
        XCTAssertEqual(saved.instances.map(\.id), ["provider"])
    }

    func testSynchronizedConfigurationRejectsChangedRevisionWithoutOverwriting() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.json")
        let store = ProviderConfigStore(fileURL: url)
        let oldRevision = store.configRevision
        store.applyConfig(fixture())
        try await store.nmWaitForConfigurationWrites()
        do {
            try await store.nmCommitSynchronizedConfiguration(.empty, expectedRevision: oldRevision)
            XCTFail("旧同步基线不得覆盖本地修改")
        } catch {
            XCTAssertEqual(error as? NivoPersonalBackupError, .snapshotChanged)
        }
        let saved = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.instances.map(\.id), ["provider"])
    }

    func testSynchronizedConfigurationPropagatesJSONWriteFailure() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.json")
        let store = ProviderConfigStore(fileURL: url)
        let incoming = fixture()
        // 用目录占据目标文件位置，真实文件写入必须失败。
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do {
            try await store.nmCommitSynchronizedConfiguration(incoming, expectedRevision: store.configRevision)
            XCTFail("真实写盘失败不得返回同步成功")
        } catch {}
        XCTAssertTrue(try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        // 故障解除后收到相同快照，也必须重试落盘，不能被内存no-op短路。
        try FileManager.default.removeItem(at: url)
        try await store.nmCommitSynchronizedConfiguration(incoming, expectedRevision: store.configRevision)
        let saved = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.instances.map(\.id), ["provider"])
    }

    func testRestoreRejectsThinkingRuleWritesWithoutChangingDatabase() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        try await database.nmBulkReplace(from: fixture())
        let original = ThinkingRule(kind: .custom, scope: .allModels, wireFormat: .omitEverything, label: "original")
        let inserted = await database.upsertThinkingRule(original, instanceId: "provider", sortOrder: 0)
        XCTAssertTrue(inserted)
        let store = ProviderConfigStore(fileURL: root.appendingPathComponent("provider.json"), database: database)
        let identifier = UUID()
        try await store.nmBeginRestore(identifier)
        defer { store.nmEndRestore(identifier) }
        var changed = original
        changed.label = "changed"
        let saved = await store.saveThinkingRule(changed, instanceId: "provider", sortOrder: 1)
        let deleted = await store.deleteThinkingRule(id: original.id, instanceId: "provider")
        let reordered = await store.reorderThinkingRules(instanceId: "provider", orderedIds: [original.id])
        XCTAssertFalse(saved)
        XCTAssertFalse(deleted)
        XCTAssertFalse(reordered)
        let remaining = await database.thinkingRuleRow(id: original.id)
        XCTAssertEqual(remaining?["label"] as? String, "original")
    }

    func testInboundProviderUpdateRetainsExistingModelsAndSkipsOlderVersion() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        let original = fixture()
        try await database.nmBulkReplace(from: original)
        let timestamp = Date().timeIntervalSince1970 + 100
        let applied = try await updateProvider(database, label: "changed", timestamp: timestamp)
        let skipped = try await updateProvider(database, label: "older", timestamp: timestamp - 1)
        XCTAssertTrue(applied)
        XCTAssertFalse(skipped)
        let saved = await database.dumpProviderConfig()
        XCTAssertEqual(saved.instances.first?.label, "changed")
        XCTAssertEqual(saved.modelEntries.map(\.id), original.modelEntries.map(\.id))
    }

    func testInboundModelForeignKeyFailureIsThrownAndExistingModelsRemain() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        let original = fixture()
        try await database.nmBulkReplace(from: original)
        do {
            _ = try await database.upsertEntryFromInbound(id: "missing/model", providerInstanceId: "missing",
                baseModelJson: try modelJSON("model"), overridesJson: nil, isCustom: false, isHidden: false,
                userModifiedAt: nil, sortOrder: 0, updatedAt: 2, extrasJson: nil)
            XCTFail("缺少提供商的模型记录必须失败并等待重放")
        } catch let error as NivoSQLiteWriteError {
            XCTAssertEqual(error, .sqlite(operation: "provider_row", code: SQLITE_CONSTRAINT))
        }
        let saved = await database.dumpProviderConfig()
        XCTAssertEqual(saved.modelEntries.map(\.id), original.modelEntries.map(\.id))
    }

    func testInboundProviderWriteTriggerFailureIsNotReportedAsVersionSkip() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.db")
        let database = try ProviderConfigDB(url: url)
        try await database.nmBulkReplace(from: fixture())
        try executeSQL(url, sql: """
            CREATE TRIGGER reject_provider_update BEFORE UPDATE ON provider_instances
            BEGIN SELECT RAISE(ABORT, 'test-write'); END;
            """)
        do {
            _ = try await updateProvider(database, label: "blocked", timestamp: Date().timeIntervalSince1970 + 100)
            XCTFail("写入失败必须抛出，不能作为本机较新返回false")
        } catch is NivoSQLiteWriteError {}
        let saved = await database.dumpProviderConfig()
        XCTAssertEqual(saved.instances.first?.label, "fixture")
        XCTAssertEqual(saved.modelEntries.count, 1)
    }

    func testCanonicalModelDeletionRollsBackBothIdentitiesOnFailure() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.db")
        let database = try ProviderConfigDB(url: url)
        try await database.nmBulkReplace(from: fixture())
        let ids: Set<String> = ["legacy", "provider/model"]
        for id in ids {
            _ = try await database.upsertEntryFromInbound(id: id, providerInstanceId: "provider",
                baseModelJson: try modelJSON("model"), overridesJson: nil, isCustom: true, isHidden: false,
                userModifiedAt: nil, sortOrder: 0, updatedAt: 2, extrasJson: nil)
        }
        try executeSQL(url, sql: """
            CREATE TRIGGER reject_model_delete BEFORE DELETE ON provider_model_entries
            WHEN OLD.id = 'provider/model' BEGIN SELECT RAISE(ABORT, 'test-delete'); END;
            """)
        do {
            try await database.deleteEntryRows(ids: ids)
            XCTFail("第二个删除失败时必须回滚第一个删除")
        } catch is NivoSQLiteWriteError {}
        for id in ids {
            let row = await database.entryRow(id: id)
            XCTAssertNotNil(row)
        }
        try executeSQL(url, sql: "DROP TRIGGER reject_model_delete")
        try await database.deleteEntryRows(ids: ids)
        for id in ids {
            let row = await database.entryRow(id: id)
            XCTAssertNil(row)
        }
    }

    func testThinkingRuleWaitsForPersistedProviderAndCanReplay() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        do {
            _ = try await inboundThinkingRule(database)
            XCTFail("父提供商尚未抵达时必须保留规则供重放")
        } catch is NivoSQLiteWriteError {}
        try await database.nmBulkReplace(from: fixture())
        let applied = try await inboundThinkingRule(database)
        let repeated = try await inboundThinkingRule(database)
        XCTAssertTrue(applied)
        XCTAssertFalse(repeated)
        let row = await database.thinkingRuleRow(id: "inbound-rule")
        XCTAssertNotNil(row)
    }

    func testDatabaseRefreshDoesNotRewriteProviderRowsOrTheirTimestamps() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.db")
        let database = try ProviderConfigDB(url: url)
        try await database.nmBulkReplace(from: fixture())
        try executeSQL(url, sql: """
            UPDATE provider_instances SET updated_at=123, extras_json='{"future":true}' WHERE id='provider';
            CREATE TRIGGER reject_refresh_delete BEFORE DELETE ON provider_instances
            BEGIN SELECT RAISE(ABORT, 'refresh-must-not-write'); END;
            CREATE TRIGGER reject_refresh_update BEFORE UPDATE ON provider_instances
            BEGIN SELECT RAISE(ABORT, 'refresh-must-not-write'); END;
            """)
        let store = ProviderConfigStore(fileURL: root.appendingPathComponent("mirror.json"), database: database)
        try await store.nmRefreshFromDatabase()
        XCTAssertEqual(store.config.instances.map(\.id), ["provider"])
        let row = await database.instanceRow(id: "provider")
        XCTAssertEqual(row?["updated_at"] as? Double, 123)
        XCTAssertEqual(row?["extras_json"] as? String, "{\"future\":true}")
        let saved = try JSONDecoder().decode(ProviderConfig.self,
            from: Data(contentsOf: root.appendingPathComponent("mirror.json")))
        XCTAssertEqual(saved, store.config)
    }

    func testBrokenDatabaseReadPreservesCurrentCacheAndJSONMirror() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.db")
        let mirror = root.appendingPathComponent("mirror.json")
        let database = try ProviderConfigDB(url: url)
        try await database.nmBulkReplace(from: fixture())
        let store = ProviderConfigStore(fileURL: mirror, database: database)
        try await store.nmRefreshFromDatabase()
        let original = store.config
        let originalFile = try Data(contentsOf: mirror)
        try executeSQL(url, sql: "DROP TABLE provider_model_groups")
        do {
            try await store.nmRefreshFromDatabase()
            XCTFail("缺表不能作为空分组发布")
        } catch is NivoSQLiteWriteError {}
        XCTAssertEqual(store.config, original)
        XCTAssertEqual(try Data(contentsOf: mirror), originalFile)
    }

    func testCorruptModelPayloadRejectsSnapshotAndKeepsStoredRecord() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.db")
        let database = try ProviderConfigDB(url: url)
        let original = fixture()
        try await database.nmBulkReplace(from: original)
        try executeSQL(url, sql: "UPDATE provider_model_entries SET base_model_json='broken'")
        do {
            _ = try await database.nmDumpProviderConfig()
            XCTFail("损坏模型不能静默跳过后成为可写回的快照")
        } catch {
            XCTAssertEqual(error as? NivoPersonalBackupError, .invalidPackage)
        }
        let row = await database.entryRow(id: original.modelEntries[0].uuid)
        XCTAssertEqual(row?["base_model_json"] as? String, "broken")
    }

    func testLegacyIDMapSurvivesFullConfigurationWriteAndDatabaseReopen() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.db")
        let database = try ProviderConfigDB(url: url)
        let expected = ["legacy-entry": "provider/fixture-model"]
        _ = try await database.nmLearnLegacyUuids(expected)
        try await database.nmBulkReplace(from: fixture())
        let reopened = try ProviderConfigDB(url: url)
        let saved = try await reopened.nmLegacyUuidMap()
        XCTAssertEqual(saved, expected)
    }

    func testLearningLegacyIDDoesNotSaveStaleCacheOverIncomingModels() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        let store = ProviderConfigStore(fileURL: root.appendingPathComponent("mirror.json"), database: database)
        var original = fixture()
        original.modelGroups = [ModelGroup(id: "group", name: "group", memberEntryIds: ["legacy-entry"])]
        store.applyConfig(original)
        try await store.nmWaitForConfigurationWrites()
        let incoming = LLMModel(id: "incoming", displayName: "incoming", provider: "OpenAI")
        let encoded = String(decoding: try JSONEncoder().encode(incoming), as: UTF8.self)
        _ = try await database.upsertEntryFromInbound(id: "provider/incoming", providerInstanceId: "provider",
            baseModelJson: encoded, overridesJson: nil, isCustom: true, isHidden: false,
            userModifiedAt: nil, sortOrder: 1, updatedAt: Date().timeIntervalSince1970 + 10, extrasJson: nil)
        try await store.learnLegacyUuids(["legacy-entry": "provider/incoming"])
        try await store.nmWaitForConfigurationWrites()
        let persisted = try await database.nmDumpProviderConfig()
        XCTAssertTrue(persisted.modelEntries.contains { $0.id == "provider/incoming" })
        try await store.nmRefreshFromDatabase()
        XCTAssertEqual(store.config.modelGroups.first?.memberEntryIds, ["provider/incoming"])
        // 缓存归一化不反写数据库中的整组记录。
        let group = await database.groupRow(id: "group")
        XCTAssertEqual(group?["member_entry_ids_json"] as? String, "[\"legacy-entry\"]")
    }

    func testReadOnlyMirrorFailureCanRetrySameSnapshotWithoutDatabaseRewrite() async throws {
        let root = try directory()
        let mirror = root.appendingPathComponent("mirror.json")
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        try await database.nmBulkReplace(from: fixture())
        let store = ProviderConfigStore(fileURL: mirror, database: database)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: false)
        do { try await store.nmRefreshFromDatabase(); XCTFail("镜像写入必须失败") }
        catch {}
        try FileManager.default.removeItem(at: mirror)
        try await store.nmRefreshFromDatabase()
        let saved = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: mirror))
        XCTAssertEqual(saved, store.config)
        XCTAssertEqual(saved.instances.map(\.id), ["provider"])
    }

    func testStrictRuleCacheReadReportsMissingTable() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.db")
        let database = try ProviderConfigDB(url: url)
        try await database.nmBulkReplace(from: fixture())
        let store = ProviderConfigStore(fileURL: root.appendingPathComponent("mirror.json"), database: database)
        try await store.nmRefreshFromDatabase()
        try executeSQL(url, sql: "DROP TABLE provider_thinking_rules")
        do {
            try await store.nmReloadThinkingRuleCache()
            XCTFail("规则读取失败不能使恢复流程报告缓存已重载")
        } catch is NivoSQLiteWriteError {}
    }

    func testReadOnlyRefreshKeepsDuplicateRowsAndStableVisibleOrder() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        var original = fixture()
        let first = LLMModel(id: "first", displayName: "first", provider: "OpenAI")
        let second = LLMModel(id: "second", displayName: "second", provider: "OpenAI")
        original.modelEntries = [
            ModelEntry(uuid: "z-first", providerInstanceId: "provider", model: first),
            ModelEntry(uuid: "a-first", providerInstanceId: "provider", model: first,
                       overrides: ModelOverrides(displayName: "custom-name"), isHidden: true,
                       userModifiedAt: Date(timeIntervalSince1970: 100)),
            ModelEntry(uuid: "second", providerInstanceId: "provider", model: second),
        ]
        original.modelGroups = [ModelGroup(id: "group", name: "group", memberEntryIds: ["z-first"])]
        try await database.nmBulkReplace(from: original)
        _ = try await database.nmLearnLegacyUuids(["a-first": "provider/first", "z-first": "provider/first"])
        let store = ProviderConfigStore(fileURL: root.appendingPathComponent("mirror.json"), database: database)
        try await store.nmRefreshFromDatabase()
        let revision = store.configRevision
        for _ in 0..<5 { try await store.nmRefreshFromDatabase() }
        XCTAssertEqual(store.configRevision, revision)
        XCTAssertEqual(store.config.modelEntries.map(\.id), ["provider/first", "provider/second"])
        XCTAssertEqual(store.config.modelEntries.first?.overrides.displayName, "custom-name")
        XCTAssertEqual(store.config.modelEntries.first?.isHidden, true)
        XCTAssertEqual(store.config.modelGroups.first?.memberEntryIds, ["provider/first"])
        let rows = try await database.nmDumpProviderConfig()
        XCTAssertEqual(rows.modelEntries.count, 3)
    }

    func testRefreshCannotMaskFailedFullConfigurationWrite() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.db")
        let mirror = root.appendingPathComponent("mirror.json")
        let database = try ProviderConfigDB(url: url)
        let store = ProviderConfigStore(fileURL: mirror, database: database)
        store.applyConfig(fixture())
        try await store.nmWaitForConfigurationWrites()
        let saved = try Data(contentsOf: mirror)
        try executeSQL(url, sql: """
            CREATE TRIGGER reject_full_write BEFORE UPDATE ON provider_instances
            BEGIN SELECT RAISE(ABORT, 'test-full-write'); END;
            """)
        var changed = store.config
        changed.instances[0].label = "unsaved-edit"
        store.applyConfig(changed)
        do {
            try await store.nmRefreshFromDatabase()
            XCTFail("镜像刷新不能用数据库旧值掩盖保存失败")
        } catch is NivoSQLiteWriteError {}
        XCTAssertEqual(store.config.instances.first?.label, "unsaved-edit")
        XCTAssertEqual(try Data(contentsOf: mirror), saved)
    }

    func testReloadNormalizesLegacyReferencesAndPreservesRestoredTombstones() async throws {
        let root = try directory()
        let mirror = root.appendingPathComponent("mirror.json")
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        var original = fixture()
        original.modelGroups = [ModelGroup(id: "group", name: "group", memberEntryIds: ["legacy-entry"])]
        original.deletedModelGroups = [ProviderConfigTombstone(id: "deleted-group", deletedAt: Date(timeIntervalSince1970: 100))]
        try await database.nmBulkReplace(from: original)
        _ = try await database.nmLearnLegacyUuids(["legacy-entry": original.modelEntries[0].id])
        try JSONEncoder().encode(original).write(to: mirror)
        let store = ProviderConfigStore(fileURL: mirror, database: database)
        try await store.nmReloadFromDisk()
        XCTAssertEqual(store.config.modelGroups.first?.memberEntryIds, [original.modelEntries[0].id])
        XCTAssertEqual(store.config.deletedModelGroups, original.deletedModelGroups)
    }

    func testRuleCacheSnapshotUsesPersistedParentsAndRejectsMissingTableWhenEmpty() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.db")
        let database = try ProviderConfigDB(url: url)
        try await database.nmBulkReplace(from: fixture())
        _ = try await inboundThinkingRule(database)
        let snapshot = try await database.nmThinkingRuleCacheSnapshot()
        XCTAssertEqual(snapshot["provider"]?.map(\.id), ["inbound-rule"])
        try await database.nmBulkReplace(from: .empty)
        let empty = try await database.nmThinkingRuleCacheSnapshot()
        XCTAssertTrue(empty.isEmpty)
        try executeSQL(url, sql: "DROP TABLE provider_thinking_rules")
        do {
            _ = try await database.nmThinkingRuleCacheSnapshot()
            XCTFail("当前配置没有提供商也不能隐藏缺失规则表")
        } catch is NivoSQLiteWriteError {}
    }

    func testRepeatedLegacyMappingDoesNotRewriteMetadata() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.db")
        let database = try ProviderConfigDB(url: url)
        let expected = ["legacy-entry": "provider/fixture-model"]
        _ = try await database.nmLearnLegacyUuids(expected)
        try executeSQL(url, sql: """
            CREATE TRIGGER reject_repeated_mapping BEFORE INSERT ON provider_local_kv
            WHEN NEW.key='legacyUuidMap' BEGIN SELECT RAISE(ABORT, 'test-mapping-write'); END;
            """)
        let repeated = try await database.nmLearnLegacyUuids(expected)
        let empty = try await database.nmLearnLegacyUuids([:])
        XCTAssertEqual(repeated, expected)
        XCTAssertEqual(empty, expected)
        do {
            _ = try await database.nmLearnLegacyUuids(["another": "provider/other-model"])
            XCTFail("真正修改映射时写盘失败必须报告")
        } catch is NivoSQLiteWriteError {}
        let retained = try await database.nmLegacyUuidMap()
        XCTAssertEqual(retained, expected)
    }

    func testLocalSavePreservesInboundModelNotYetPublishedToPage() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        let mirror = root.appendingPathComponent("provider.json")
        let store = ProviderConfigStore(fileURL: mirror, database: database)
        store.applyConfig(fixture())
        try await store.nmWaitForConfigurationWrites()
        let incoming = LLMModel(id: "incoming", displayName: "incoming", provider: "OpenAI")
        _ = try await database.upsertEntryFromInbound(id: "provider/incoming", providerInstanceId: "provider",
            baseModelJson: String(decoding: try JSONEncoder().encode(incoming), as: UTF8.self), overridesJson: nil,
            isCustom: false, isHidden: false, userModifiedAt: nil, sortOrder: 1, updatedAt: 50, extrasJson: "{\"future\":true}")
        var changed = store.config
        changed.instances[0].label = "local-name"
        store.applyConfig(changed)
        try await store.nmWaitForConfigurationWrites()
        let persisted = try await database.nmDumpProviderConfig()
        XCTAssertEqual(persisted.instances.first?.label, "local-name")
        XCTAssertEqual(persisted.modelEntries.count, 2)
        let row = await database.entryRow(id: "provider/incoming")
        XCTAssertEqual(row?["updated_at"] as? Double, 50)
        XCTAssertEqual(row?["extras_json"] as? String, "{\"future\":true}")
        let saved = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: mirror))
        XCTAssertEqual(saved.modelEntries.count, 2)
    }

    func testLaterSaveRetriesEarlierDatabaseFailureWithoutLosingEitherEdit() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("provider.db")
        let database = try ProviderConfigDB(url: url)
        let store = ProviderConfigStore(fileURL: root.appendingPathComponent("provider.json"), database: database)
        store.applyConfig(fixture())
        try await store.nmWaitForConfigurationWrites()
        try executeSQL(url, sql: """
            CREATE TRIGGER reject_edit BEFORE UPDATE ON provider_instances
            BEGIN SELECT RAISE(ABORT, 'test-edit'); END;
            """)
        var changed = store.config
        changed.instances[0].label = "pending-name"
        store.applyConfig(changed)
        do { try await store.nmWaitForConfigurationWrites(); XCTFail("故障注入必须阻止持久化") }
        catch is NivoSQLiteWriteError {}
        try executeSQL(url, sql: "DROP TRIGGER reject_edit")
        changed.instances[0].isEnabled = false
        store.applyConfig(changed)
        try await store.nmWaitForConfigurationWrites()
        let saved = try await database.nmDumpProviderConfig()
        XCTAssertEqual(saved.instances.first?.label, "pending-name")
        XCTAssertEqual(saved.instances.first?.isEnabled, false)
    }

    /// 模型组连续编辑在同一主线程回合排队，不能依赖稍后刷新才纠正回拨时间。
    func testRapidGroupRemovalAndReadditionSurviveObservedFutureTimestamp() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        let store = ProviderConfigStore(fileURL: root.appendingPathComponent("provider.json"), database: database)
        var initial = fixture()
        let identifier = initial.modelEntries[0].id
        let observed = Date().addingTimeInterval(600)
        var group = ModelGroup(name: "clock-regression", memberEntryIds: [identifier])
        group.addedMembers[identifier] = observed
        initial.modelGroups = [group]
        store.applyConfig(initial)
        try await store.nmWaitForConfigurationWrites()

        group.memberEntryIds = []
        store.updateGroup(group)
        group = try XCTUnwrap(store.config.modelGroups.first)
        let removed = try XCTUnwrap(group.removedMembers[identifier])
        group.memberEntryIds = [identifier]
        store.updateGroup(group)
        let readded = try XCTUnwrap(store.config.modelGroups.first?.addedMembers[identifier])
        XCTAssertGreaterThan(removed, observed)
        XCTAssertGreaterThan(readded, removed)
        try await store.nmWaitForConfigurationWrites()
        let saved = try await database.nmDumpProviderConfig()
        XCTAssertEqual(saved.modelGroups.first?.memberEntryIds, [identifier])
        XCTAssertEqual(saved.modelGroups.first?.addedMembers[identifier], readded)
    }

    func testExplicitBackupRestoreStillReplacesEntireProviderCollection() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        let store = ProviderConfigStore(fileURL: root.appendingPathComponent("provider.json"), database: database)
        store.applyConfig(fixture())
        try await store.nmWaitForConfigurationWrites()
        let token = UUID()
        try await store.nmBeginRestore(token)
        defer { store.nmEndRestore(token) }
        try await store.nmApplyRestoredConfiguration(.empty)
        let restored = try await database.nmDumpProviderConfig()
        XCTAssertTrue(restored.instances.isEmpty)
        XCTAssertTrue(restored.modelEntries.isEmpty)
    }

    func testInboundMalformedModelAndOverrideDoNotPoisonExistingConfiguration() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        let original = fixture()
        try await database.nmBulkReplace(from: original)
        let identifier = original.modelEntries[0].uuid
        for (base, overrides) in [("{}", Optional<String>.none),
                                  (try modelJSON("fixture-model"), "{\"maxOutputTokens\":\"many\"}")] {
            do {
                _ = try await database.upsertEntryFromInbound(id: identifier, providerInstanceId: "provider",
                    baseModelJson: base, overridesJson: overrides, isCustom: false, isHidden: true,
                    userModifiedAt: nil, sortOrder: 0, updatedAt: Date().timeIntervalSince1970 + 100, extrasJson: nil)
                XCTFail("无法被缓存读取的记录必须在写入前拒绝")
            } catch {}
        }
        let saved = try await database.nmDumpProviderConfig()
        XCTAssertEqual(saved.modelEntries, original.modelEntries)
    }

    func testCorruptLocalGroupHistoryIsRetainedForRecovery() async throws {
        for column in ["member_entry_ids_json", "added_members_json", "removed_members_json"] {
            let root = try directory()
            let url = root.appendingPathComponent("provider.db")
            let database = try ProviderConfigDB(url: url)
            var original = fixture()
            original.modelGroups = [ModelGroup(id: "group", name: "original", memberEntryIds: ["provider/fixture-model"])]
            try await database.nmBulkReplace(from: original)
            try executeSQL(url, sql: "UPDATE provider_model_groups SET \(column)='broken' WHERE id='group'")
            do {
                _ = try await database.upsertGroupFromInbound(id: "group", name: "incoming", strategy: "fallback",
                    fallbackStrategy: "limited", defaultThinkingLevel: nil, contextLimitTokens: nil,
                    contextLimitRemembered: nil, memberEntryIdsJson: "[]", sortOrder: 0,
                    updatedAt: Date().timeIntervalSince1970 + 100, extrasJson: nil)
                XCTFail("本机损坏成员记录不能被当成空集合合并")
            } catch {}
            let row = await database.groupRow(id: "group")
            XCTAssertEqual(row?[column] as? String, "broken")
            XCTAssertEqual(row?["name"] as? String, "original")
        }
    }

    func testUnsupportedOrMalformedInboundGroupDoesNotEnterDatabase() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider.db"))
        try await database.nmBulkReplace(from: fixture())
        for (members, strategy) in [("{}", "fallback"), ("[]", "future-strategy")] {
            do {
                _ = try await database.upsertGroupFromInbound(id: "group", name: "incoming", strategy: strategy,
                    fallbackStrategy: "limited", defaultThinkingLevel: nil, contextLimitTokens: nil,
                    contextLimitRemembered: nil, memberEntryIdsJson: members, sortOrder: 0,
                    updatedAt: 10, extrasJson: nil)
                XCTFail("不支持的组须由上层保留以供重放，不能破坏现有缓存")
            } catch {}
        }
        let saved = try await database.nmDumpProviderConfig()
        XCTAssertTrue(saved.modelGroups.isEmpty)
        XCTAssertEqual(saved.modelEntries.count, 1)
    }

    private func modelJSON(_ identifier: String) throws -> String {
        String(decoding: try JSONEncoder().encode(LLMModel(id: identifier, displayName: identifier, provider: "OpenAI")), as: UTF8.self)
    }

    private func updateProvider(_ database: ProviderConfigDB, label: String, timestamp: Double) async throws -> Bool {
        try await database.upsertInstanceFromInbound(id: "provider", label: label, providerType: "openai",
            credentialType: "apiKey", customBaseURL: nil, appendV1Suffix: true,
            imageEndpointMode: nil, imageEndpointResolved: nil, isEnabled: true, sortOrder: 0,
            secretBlob: nil, secretKind: nil, secretUpdatedAt: nil, createdAt: 1, updatedAt: timestamp,
            extrasJson: nil, customUserAgent: nil)
    }

    private func inboundThinkingRule(_ database: ProviderConfigDB) async throws -> Bool {
        try await database.upsertThinkingRuleFromInbound(id: "inbound-rule", instanceId: "provider", sortOrder: 0,
            scopeKind: "allModels", scopePattern: nil, wireFormatJson: "{\"kind\":\"omitEverything\"}", echoField: nil,
            echoTiming: nil, label: "inbound", createdAt: 1, updatedAt: 2)
    }

    /// 故障注入只连接本测试的临时数据库，生产仓库继续走真实SQL路径。
    private func executeSQL(_ url: URL, sql: String) throws {
        var connection: OpaquePointer?
        defer { if let connection { sqlite3_close(connection) } }
        let opened = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil)
        guard opened == SQLITE_OK, let connection else {
            throw NivoSQLiteWriteError.sqlite(operation: "test_open", code: opened)
        }
        let result = sqlite3_exec(connection, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw NivoSQLiteWriteError.sqlite(operation: "test_exec", code: result) }
    }

    private func fixture() -> ProviderConfig {
        let instance = ProviderInstance(id: "provider", label: "fixture", providerType: .openAI, credentialType: .apiKey)
        let entry = ModelEntry(providerInstanceId: instance.id,
            model: LLMModel(id: "fixture-model", displayName: "fixture", provider: "OpenAI"))
        let sessionID = UUID().uuidString
        let binding = SessionModelBinding(sessionId: sessionID,
            primarySource: .directEntry(modelEntryId: entry.id), subModelSource: nil)
        return ProviderConfig(instances: [instance], modelEntries: [entry], modelGroups: [],
            defaultPrimaryGroupId: nil, defaultSubGroupId: nil, sessionBindings: [sessionID: binding],
            agentLoopModelEntryIds: [entry.id])
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}
