import XCTest
@testable import Minis

/// 独立配置验证聊天选择、运行时授权和模型可用性，不调用真实供应商。
@MainActor
final class NivoModelUseAuthorizationTests: XCTestCase {
    func testChatBindingAndDefaultGroupDoNotAuthorizeOffload() throws {
        let config = fixture()
        let store = try makeStore(config)
        XCTAssertNotNil(store.entry(for: config.modelEntries[0].id))
        XCTAssertNotNil(store.config.sessionBindings["chat"])
        XCTAssertTrue(store.resolvedAgentLoopEntries.isEmpty)
        XCTAssertTrue(ModelUseOffloadBridge.availableAgentEntries(store: store).isEmpty)
    }

    func testOnlyExplicitlyAuthorizedEntriesAreExposed() throws {
        var config = fixture()
        config.agentLoopModelEntryIds = [config.modelEntries[0].id]
        let store = try makeStore(config)
        XCTAssertEqual(ModelUseOffloadBridge.availableAgentEntries(store: store).map(\.id),
                       [config.modelEntries[0].id])
    }

    func testAuthorizedGroupMembersAreDeduplicated() throws {
        var config = fixture()
        config.agentLoopModelEntryIds = [config.modelEntries[0].id]
        config.agentLoopGroupIds = ["group"]
        let store = try makeStore(config)
        XCTAssertEqual(ModelUseOffloadBridge.availableAgentEntries(store: store).map(\.id),
                       config.modelEntries.map(\.id))
    }

    func testHiddenModelsAndDisabledProvidersAreNotCallable() throws {
        var config = fixture()
        config.agentLoopGroupIds = ["group"]
        config.modelEntries[0].isHidden = true
        config.instances[1].isEnabled = false
        let store = try makeStore(config)
        XCTAssertTrue(ModelUseOffloadBridge.availableAgentEntries(store: store).isEmpty)
    }

    func testProviderFilterUsesLabelOrUUIDWithoutAddingAuthorization() throws {
        var config = fixture()
        config.agentLoopModelEntryIds = [config.modelEntries[0].id]
        let store = try makeStore(config)
        for filter in ["PRIMARY", "primary-id"] {
            XCTAssertEqual(ModelUseOffloadBridge.availableAgentEntries(store: store,
                providerFilter: filter).map(\.id), [config.modelEntries[0].id])
        }
        XCTAssertTrue(ModelUseOffloadBridge.availableAgentEntries(store: store,
            providerFilter: "Secondary").isEmpty)
    }

    private func fixture() -> ProviderConfig {
        let providers = [
            ProviderInstance(id: "primary-id", label: "Primary", providerType: .openAI, credentialType: .apiKey),
            ProviderInstance(id: "secondary-id", label: "Secondary", providerType: .openAI, credentialType: .apiKey),
        ]
        let entries = providers.map { provider in
            ModelEntry(uuid: "model-" + provider.id, providerInstanceId: provider.id,
                model: LLMModel(id: "model.v1", displayName: "Model", provider: "OpenAI",
                                modalityOverride: [.textInput, .textOutput]), isCustom: true)
        }
        return ProviderConfig(instances: providers, modelEntries: entries,
            modelGroups: [ModelGroup(id: "group", name: "Models", memberEntryIds: entries.map(\.id))],
            defaultPrimaryGroupId: "group", defaultSubGroupId: nil,
            sessionBindings: ["chat": .init(sessionId: "chat",
                primarySource: .directEntry(modelEntryId: entries[0].id), subModelSource: nil)])
    }

    private func makeStore(_ config: ProviderConfig) throws -> ProviderConfigStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-use-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("provider.json")
        try JSONEncoder().encode(config).write(to: file)
        return ProviderConfigStore(fileURL: file)
    }
}
