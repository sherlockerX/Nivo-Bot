import XCTest
@testable import Minis

/// 使用独立配置文件检查真实仓库的编辑行为，不打开共享数据库或读取凭证。
@MainActor
final class NivoProviderModelEditingTests: XCTestCase {
    /// 改模型ID仍应定位同一UUID，不能按新复合ID查找而静默放弃。
    func testRenamingCustomModelKeepsItsUUID() async throws {
        let original = fixture()
        let store = try makeStore(original)
        let updated = renamed(original.modelEntries[0], modelID: "renamed")
        store.updateEntry(updated)
        _ = try? await store.nmWaitForConfigurationWrites()
        XCTAssertEqual(store.config.modelEntries.first?.baseModel.id, "renamed")
        XCTAssertEqual(store.config.modelEntries.first?.uuid, original.modelEntries[0].uuid)
        XCTAssertEqual(Set(store.config.modelEntries.map(\.uuid)).count, 2)
    }

    /// ID冲突不得覆盖另一模型或制造重复UUID，原配置应保持可继续保存。
    func testRenamingToExistingModelDoesNotReplaceAnotherUUID() async throws {
        let original = fixture()
        let store = try makeStore(original)
        let updated = renamed(original.modelEntries[0], modelID: original.modelEntries[1].baseModel.id)
        store.updateEntry(updated)
        _ = try? await store.nmWaitForConfigurationWrites()
        XCTAssertEqual(store.config, original)
        XCTAssertEqual(Set(store.config.modelEntries.map(\.uuid)).count, 2)
    }

    /// 改ID后分组、直接绑定、组内解析值和智能体选择都继续指向同一模型。
    func testRenamingRepairsAllExistingModelReferences() async throws {
        let original = fixture()
        let old = original.modelEntries[0]
        let store = try makeStore(original)
        let updated = renamed(old, modelID: "renamed")
        store.updateEntry(updated)
        _ = try? await store.nmWaitForConfigurationWrites()
        XCTAssertEqual(store.config.modelGroups[0].memberEntryIds, [updated.id, original.modelEntries[1].id])
        XCTAssertEqual(store.config.agentLoopModelEntryIds, [updated.id])
        XCTAssertEqual(store.config.sessionBindings["direct"]?.primarySource,
                       .directEntry(modelEntryId: updated.id))
        XCTAssertEqual(store.config.sessionBindings["group"]?.primarySource,
                       .group(groupId: "group", resolvedEntryId: updated.id))
        XCTAssertEqual(store.config.sessionBindings["group"]?.subModelSource,
                       .directEntry(modelEntryId: updated.id))
        XCTAssertNil(store.config.modelGroups[0].addedMembers[old.id])
        XCTAssertNotNil(store.config.modelGroups[0].removedMembers[old.id])
        XCTAssertNotNil(store.config.modelGroups[0].addedMembers[updated.id])
    }

    func testAwaitedRenameConfirmsPersistedConfigurationAndKeepsStableIdentity() async throws {
        let original = fixture()
        let url = try configurationFile(original)
        let store = ProviderConfigStore(fileURL: url)
        let updated = renamed(original.modelEntries[0], modelID: "renamed")
        let saved = try await store.nmUpdateEntry(updated, expected: original.modelEntries[0])
        let onDisk = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.uuid, original.modelEntries[0].uuid)
        XCTAssertEqual(saved.baseModel.id, "renamed")
        XCTAssertEqual(onDisk, store.config)
        XCTAssertEqual(onDisk.modelGroups[0].memberEntryIds.first, saved.id)
    }

    func testRenameAdvancesAllLegacyAliasHistoryAndKeepsUnrelatedReferences() throws {
        var original = fixture()
        let first = original.modelEntries[0]
        let updated = renamed(first, modelID: "renamed")
        let observed = Date(timeIntervalSince1970: 9_000_000_000)
        original.modelGroups[0].addedMembers[first.uuid] = observed
        original.modelGroups[0].memberEntryIds = [first.id, first.uuid, first.legacyColonCompositeKey, original.modelEntries[1].id]
        let candidate = try NivoProviderModelEditConfiguration.updating(updated, expected: first, in: original)
        let group = candidate.modelGroups[0]
        XCTAssertEqual(group.memberEntryIds, [updated.id, original.modelEntries[1].id])
        for reference in [first.id, first.uuid, first.legacyColonCompositeKey] {
            XCTAssertNil(group.addedMembers[reference])
            XCTAssertGreaterThan(try XCTUnwrap(group.removedMembers[reference]), observed)
        }
        XCTAssertGreaterThan(try XCTUnwrap(group.addedMembers[updated.id]), observed)
    }

    func testAwaitedDuplicateIDReturnsErrorWithoutChangingDiskOrMemory() async throws {
        let original = fixture()
        let url = try configurationFile(original)
        let before = try Data(contentsOf: url)
        let store = ProviderConfigStore(fileURL: url)
        do {
            _ = try await store.nmUpdateEntry(renamed(original.modelEntries[0], modelID: "second"), expected: original.modelEntries[0])
            XCTFail("ID冲突必须返回表单错误")
        } catch {
            XCTAssertEqual(error as? NivoProviderModelIdentity.Failure, .duplicateModelID("second"))
        }
        XCTAssertEqual(store.config, original)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testStaleEditorCannotOverwriteNewModelSettings() async throws {
        let original = fixture()
        let store = try makeStore(original)
        var newer = original.modelEntries[0]
        newer.overrides.displayName = "Newer"
        let saved = try await store.nmUpdateEntry(newer, expected: original.modelEntries[0])
        do {
            _ = try await store.nmUpdateEntry(renamed(original.modelEntries[0], modelID: "stale"), expected: original.modelEntries[0])
            XCTFail("旧表单不能覆盖新设置")
        } catch { XCTAssertEqual(error as? NivoProviderModelIdentity.Failure, .changed) }
        XCTAssertEqual(store.config.modelEntries[0], saved)
    }

    func testFailedAddKeepsOriginalStateAndCanRetrySameInput() async throws {
        let original = fixture()
        let url = try configurationFile(original)
        let store = ProviderConfigStore(fileURL: url)
        let added = ModelEntry(uuid: "fixture-new", providerInstanceId: original.instances[0].id,
            model: LLMModel(id: "new", displayName: "New", provider: "OpenAI"), isCustom: true)
        // 将本测试自己的配置文件换成同名空目录，稳定触发镜像写入失败。
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do { try await store.nmAddEntry(added); XCTFail("镜像未保存不能报告成功") }
        catch {}
        XCTAssertEqual(store.config, original)
        try FileManager.default.removeItem(at: url)
        try await store.nmAddEntry(added)
        let onDisk = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.modelEntries.filter { $0.uuid == added.uuid }.count, 1)
        XCTAssertEqual(onDisk, store.config)
    }

    func testDatabaseCommitThenMirrorFailureRestoresRowsAndCanRetryRename() async throws {
        let original = fixture()
        let url = try configurationFile(original)
        let database = try ProviderConfigDB(url: url.deletingLastPathComponent().appendingPathComponent("provider.db"))
        try await database.nmBulkReplace(from: original)
        let store = ProviderConfigStore(fileURL: url, database: database)
        let updated = renamed(original.modelEntries[0], modelID: "renamed")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do {
            _ = try await store.nmUpdateEntry(updated, expected: original.modelEntries[0])
            XCTFail("SQLite成功但镜像失败仍须返回保存失败")
        } catch {}
        let afterFailure = try await database.nmDumpProviderConfig()
        XCTAssertEqual(afterFailure.modelEntries.map(\.baseModel.id), original.modelEntries.map(\.baseModel.id))
        XCTAssertEqual(afterFailure.modelEntries.map(\.uuid), original.modelEntries.map(\.uuid))
        XCTAssertEqual(afterFailure.modelGroups[0].memberEntryIds, original.modelGroups[0].memberEntryIds)
        XCTAssertEqual(store.config, original)
        do { try await store.nmWaitForConfigurationWrites(); XCTFail("镜像仍失败时不能清除队列错误") }
        catch {}
        try FileManager.default.removeItem(at: url)
        _ = try await store.nmUpdateEntry(updated, expected: original.modelEntries[0])
        let onDisk = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: url))
        let committed = try await database.nmDumpProviderConfig()
        XCTAssertEqual(onDisk.modelEntries, committed.modelEntries)
        XCTAssertEqual(committed.modelGroups[0].memberEntryIds.first, updated.id)
        XCTAssertEqual(committed.sessionBindings["direct"]?.primarySource, .directEntry(modelEntryId: updated.id))
        XCTAssertEqual(onDisk, store.config)
    }

    func testLegacyCapabilityInferencePreservesUUIDAndUserRevision() throws {
        var original = fixture()
        let entry = original.modelEntries[0]
        let revision = Date(timeIntervalSince1970: 12345)
        original.modelEntries[0] = ModelEntry(uuid: entry.uuid, providerInstanceId: entry.providerInstanceId,
            model: LLMModel(id: entry.baseModel.id, displayName: "Fixture", provider: "OpenAI"),
            isCustom: true, userModifiedAt: revision)
        let store = try makeStore(original)
        XCTAssertEqual(store.config.modelEntries[0].uuid, entry.uuid)
        XCTAssertEqual(store.config.modelEntries[0].userModifiedAt, revision)
    }

    func testDeletingGroupClearsOnlyItsVoiceAndDefaultSelections() async throws {
        var original = fixture()
        original.voiceInputGroupId = "group"
        original.voiceOutputGroupId = "group"
        original.defaultSubGroupId = "unrelated"
        original.visionGroupId = "unrelated"
        let store = try makeStore(original)
        // 独立仓库禁用显式删除的共享ChatStore同步路径。
        store.removeGroup("group")
        try await store.nmWaitForConfigurationWrites()
        XCTAssertNil(store.config.voiceInputGroupId)
        XCTAssertNil(store.config.voiceOutputGroupId)
        XCTAssertNil(store.config.defaultPrimaryGroupId)
        XCTAssertEqual(store.config.defaultSubGroupId, "unrelated")
        XCTAssertEqual(store.config.visionGroupId, "unrelated")
        XCTAssertEqual(store.config.modelEntries, original.modelEntries)
    }

    func testFirstGroupAndDefaultAreSavedTogether() async throws {
        let original = ProviderConfig.empty
        let url = try configurationFile(original)
        let store = ProviderConfigStore(fileURL: url)
        let group = ModelGroup(id: "new-group", name: "Fixture", memberEntryIds: [])
        try await store.nmAddGroup(group)
        let onDisk = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(onDisk.modelGroups, [group])
        XCTAssertEqual(onDisk.defaultPrimaryGroupId, group.id)
    }

    func testLateRefreshCannotReplaceChangedProviderCatalog() async throws {
        let original = fixture()
        let store = try makeStore(original)
        do {
            _ = try await store.nmRefreshModels(for: original.instances[0]) { instance in
                var changed = instance
                changed.customBaseURL = "https://example.invalid/v1"
                store.updateInstance(changed)
                return .init(models: [LLMModel(id: "late", displayName: "Late", provider: "OpenAI")], source: "fixture", warnings: [])
            }
            XCTFail("更换地址后的旧目录不能写回")
        } catch { XCTAssertEqual(error as? NivoProviderModelIdentity.Failure, .changed) }
        try await store.nmWaitForConfigurationWrites()
        XCTAssertEqual(store.config.modelEntries, original.modelEntries)
        XCTAssertEqual(store.config.instances[0].customBaseURL, "https://example.invalid/v1")
    }

    func testLateRefreshCannotCrossCompletedRestoreGeneration() async throws {
        let original = fixture()
        let store = try makeStore(original)
        do {
            _ = try await store.nmRefreshModels(for: original.instances[0]) { _ in
                let token = UUID()
                try await store.nmBeginRestore(token)
                store.nmEndRestore(token)
                return .init(models: [LLMModel(id: "late", displayName: "Late", provider: "OpenAI")], source: "fixture", warnings: [])
            }
            XCTFail("已完成的恢复也必须使旧请求失效")
        } catch { XCTAssertEqual(error as? NivoProviderModelIdentity.Failure, .changed) }
        XCTAssertEqual(store.config, original)
    }

    /// 重置后重新加载真实保存结果，未知上下文必须显示为空，后续保存不能复活旧覆盖。
    func testResetThenSaveDoesNotRestorePreviousContextOverride() async throws {
        var original = fixture()
        original.modelEntries[0].isCustom = false
        original.modelEntries[0].overrides.contextWindow = 64000
        let url = try configurationFile(original)
        let store = ProviderConfigStore(fileURL: url)
        XCTAssertEqual(NivoProviderModelForm(entry: original.modelEntries[0]).contextWindowText, "64000")
        var reset = original.modelEntries[0]
        reset.overrides = ModelOverrides()
        let resetSaved = try await store.nmUpdateEntry(reset, expected: original.modelEntries[0])
        var form = NivoProviderModelForm(entry: resetSaved)
        XCTAssertEqual(form.contextWindowText, "")
        form.displayName = "After reset"
        let saved = try await store.nmUpdateEntry(form.applying(to: resetSaved), expected: resetSaved)
        let onDisk = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: url))
        XCTAssertNil(saved.overrides.contextWindow)
        XCTAssertEqual(onDisk.modelEntries[0], saved)
        XCTAssertGreaterThan(try XCTUnwrap(saved.userModifiedAt), try XCTUnwrap(resetSaved.userModifiedAt))
    }

    /// 只改名称不能清除目录中的推理协议、权威声明或用户在其他入口设置的档位上限。
    func testNameOnlyFormEditPreservesReasoningMetadataAndUnshownOverride() throws {
        let entry = reasoningEntry()
        var form = NivoProviderModelForm(entry: entry)
        form.displayName = "Renamed display"
        let updated = form.applying(to: entry)
        XCTAssertEqual(updated.baseModel, entry.baseModel)
        XCTAssertEqual(updated.overrides.maxThinkingLevel, .high)
        XCTAssertEqual(updated.overrides.displayName, "Renamed display")
        XCTAssertEqual(updated.uuid, entry.uuid)
        XCTAssertEqual(updated.isCustom, entry.isCustom)
        XCTAssertEqual(updated.isHidden, entry.isHidden)
        XCTAssertEqual(updated.overrides.modalityOverride, entry.overrides.modalityOverride)
        XCTAssertEqual(updated.model.reasoningEffortValues, ["low", "high"])
        XCTAssertEqual(updated.model.declaresNoEffortTiers, false)
        XCTAssertEqual(updated.model.effortDeclarationIsAuthoritative, true)
        XCTAssertEqual(updated.effectiveMaxThinkingLevel, .high)
    }

    /// 改自定义接口ID必须保留其余目录字段，不能因重建不可变ID而丢失推理参数。
    func testModelIDFormEditPreservesAllOtherBaseModelFields() throws {
        let entry = reasoningEntry()
        var form = NivoProviderModelForm(entry: entry)
        form.modelID = " replacement \n"
        let updated = form.applying(to: entry)
        var expectedBase = LLMModel(id: "replacement", displayName: entry.baseModel.displayName,
            provider: entry.baseModel.provider, modalityOverride: entry.baseModel.modalityOverride,
            contextWindow: entry.baseModel.contextWindow, maxOutputTokens: entry.baseModel.maxOutputTokens,
            supportsReasoning: entry.baseModel.supportsReasoning, interleavedReasoningField: entry.baseModel.interleavedReasoningField,
            reasoningEffortValues: ["low", "high"], declaresNoEffortTiers: false)
        expectedBase.effortDeclarationIsAuthoritative = true
        XCTAssertEqual(updated.baseModel, expectedBase)
        XCTAssertEqual(updated.overrides, entry.overrides)
    }

    /// 语音输入、语音输出和视频模型只改名称时，不强加文本能力或抹掉视频输出。
    func testNameOnlyFormEditKeepsDedicatedMediaDirections() throws {
        let modalities: [ModelModality] = [[.audioInput, .textOutput], [.textInput, .audioOutput], [.textInput, .videoOutput]]
        for modality in modalities {
            let entry = ModelEntry(uuid: "media", providerInstanceId: "fixture-provider",
                model: LLMModel(id: "fixture-media", displayName: "Media", provider: "Fixture", modalityOverride: modality),
                isCustom: true)
            var form = NivoProviderModelForm(entry: entry)
            form.displayName = "Renamed"
            let updated = form.applying(to: entry)
            XCTAssertEqual(updated.model.capabilities.supportedModalities, modality)
            XCTAssertNil(updated.overrides.modalityOverride)
        }
    }

    /// 用户明确打开一个开关时，只更改该可编辑能力，未展示的文本及视频方向仍保持原值。
    func testModalityToggleKeepsUnshownDirectionsAndSupportsTurningBackOff() throws {
        let entry = ModelEntry(uuid: "media", providerInstanceId: "fixture-provider",
            model: LLMModel(id: "fixture-media", displayName: "Media", provider: "Fixture",
                modalityOverride: [.audioInput, .videoOutput]), isCustom: true)
        var form = NivoProviderModelForm(entry: entry)
        form.selectedModalities.insert(.imageOutput)
        let updated = form.applying(to: entry)
        XCTAssertEqual(updated.model.capabilities.supportedModalities, [.audioInput, .videoOutput, .imageOutput])
        var reopened = NivoProviderModelForm(entry: updated)
        reopened.selectedModalities.remove(.imageOutput)
        let restored = reopened.applying(to: updated)
        XCTAssertEqual(restored.model.capabilities.supportedModalities, [.audioInput, .videoOutput])
        XCTAssertNil(restored.overrides.modalityOverride)
    }

    private func reasoningEntry() -> ModelEntry {
        var model = LLMModel(id: "fixture-reasoning", displayName: "Reasoning", provider: "Fixture",
            modalityOverride: [.textInput, .textOutput], contextWindow: 64000, maxOutputTokens: 4096,
            supportsReasoning: true, interleavedReasoningField: "reasoning_content",
            reasoningEffortValues: ["low", "high"], declaresNoEffortTiers: false)
        model.effortDeclarationIsAuthoritative = true
        return ModelEntry(uuid: "reasoning", providerInstanceId: "fixture-provider", model: model,
            overrides: .init(maxThinkingLevel: .high), isCustom: true, isHidden: true,
            userModifiedAt: Date(timeIntervalSince1970: 100))
    }

    private func fixture() -> ProviderConfig {
        let instance = ProviderInstance(id: "fixture-provider", label: "Fixture", providerType: .openAI, credentialType: .apiKey)
        let first = ModelEntry(uuid: "fixture-first", providerInstanceId: instance.id,
            model: LLMModel(id: "first", displayName: "First", provider: "OpenAI", modalityOverride: [.textInput, .textOutput]), isCustom: true)
        let second = ModelEntry(uuid: "fixture-second", providerInstanceId: instance.id,
            model: LLMModel(id: "second", displayName: "Second", provider: "OpenAI", modalityOverride: [.textInput, .textOutput]), isCustom: true)
        let group = ModelGroup(id: "group", name: "Fixture", memberEntryIds: [first.id, second.id],
            addedMembers: [first.id: Date(timeIntervalSince1970: 100)])
        return ProviderConfig(instances: [instance], modelEntries: [first, second], modelGroups: [group],
            defaultPrimaryGroupId: group.id, defaultSubGroupId: nil,
            sessionBindings: [
                "direct": .init(sessionId: "direct", primarySource: .directEntry(modelEntryId: first.id), subModelSource: nil),
                "group": .init(sessionId: "group", primarySource: .group(groupId: group.id, resolvedEntryId: first.id),
                    subModelSource: .directEntry(modelEntryId: first.uuid)),
            ], agentLoopModelEntryIds: [first.id])
    }

    private func renamed(_ original: ModelEntry, modelID: String) -> ModelEntry {
        ModelEntry(uuid: original.uuid, providerInstanceId: original.providerInstanceId,
            model: LLMModel(id: modelID, displayName: original.baseModel.displayName, provider: original.baseModel.provider,
                modalityOverride: original.baseModel.modalityOverride),
            overrides: original.overrides, isCustom: original.isCustom, isHidden: original.isHidden,
            userModifiedAt: original.userModifiedAt)
    }

    private func makeStore(_ config: ProviderConfig) throws -> ProviderConfigStore {
        ProviderConfigStore(fileURL: try configurationFile(config))
    }

    private func configurationFile(_ config: ProviderConfig) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-edit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("provider.json")
        try JSONEncoder().encode(config).write(to: url, options: .atomic)
        return url
    }
}
