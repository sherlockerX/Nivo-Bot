import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CNivoSQLite
#endif
@testable import Minis

/// 使用独立SQLite与JSON镜像覆盖新增服务商时的真实字段编码和全库回读。
@MainActor
final class NivoProviderCodecRoundTripTests: XCTestCase {
    /// 首次无模型服务商同时覆盖镜像尚不存在和已写空配置两种起点。
    func testFreshKeylessProviderWithoutModelsPersistsFromMissingAndEmptyMirrors() async throws {
        for hasMirror in [false, true] {
            let root = try directory()
            let mirror = root.appendingPathComponent("provider-config.json")
            if hasMirror { try JSONEncoder().encode(ProviderConfig.empty).write(to: mirror) }
            let database = try ProviderConfigDB(url: root.appendingPathComponent("provider-config.db"))
            let store = ProviderConfigStore(fileURL: mirror, database: database)
            let instance = keylessInstance(id: "new-provider")
            let token = UUID()
            try await store.nmBeginRestore(token)
            defer { store.nmEndRestore(token) }
            let prepared = try NivoProviderSetupConfiguration.prepare(instance: instance, apiKey: "", current: store.config)
            XCTAssertTrue(prepared.configuration.modelEntries.isEmpty)
            XCTAssertTrue(prepared.credentials.isEmpty)

            try await store.nmCommitImportedConfiguration(prepared.configuration, token: token)

            let persisted = try await database.nmDumpProviderConfig()
            let decoded = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: mirror))
            XCTAssertEqual(persisted.instances, [instance])
            XCTAssertTrue(persisted.modelEntries.isEmpty)
            XCTAssertTrue(persisted.modelGroups.isEmpty)
            XCTAssertTrue(persisted.sessionBindings.isEmpty)
            XCTAssertEqual(decoded, persisted)
            XCTAssertEqual(store.config, decoded)
        }
    }

    /// 模型能力、覆盖、成员历史和两类会话设置必须经过真实SQL后仍可完整解码。
    func testAllJSONColumnsSurviveDatabaseAndMirrorRoundTrip() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider-config.db"))
        let candidate = populatedConfiguration()
        let persisted = try await database.nmApplyConfigurationChanges(from: .empty, to: candidate)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(persisted))
        XCTAssertEqual(persisted, candidate)
        XCTAssertEqual(decoded, candidate)
    }

    /// 旧模型缺少可选元数据和旧思考开关仍能先解码，再进入当前SQLite与镜像格式。
    func testLegacyOptionalFieldsRoundTripThroughCurrentDatabase() async throws {
        let root = try directory()
        let database = try ProviderConfigDB(url: root.appendingPathComponent("provider-config.db"))
        let legacy = #"{"instances":[{"id":"legacy-provider","label":"fixture","providerType":"openAI","credentialType":"apiKey","isEnabled":true,"createdAt":0}],"modelEntries":[{"providerInstanceId":"legacy-provider","model":{"id":"legacy-model","displayName":"fixture","provider":"OpenAI"},"isCustom":false,"isHidden":false}],"sessionBindings":{},"sessionInferenceConfigs":{"legacy-session":{"thinkingEnabled":true}}}"#
        let candidate = try JSONDecoder().decode(ProviderConfig.self, from: Data(legacy.utf8))
        XCTAssertTrue(candidate.modelGroups.isEmpty)
        XCTAssertEqual(candidate.sessionInferenceConfigs["legacy-session"]?.thinkingLevel, .medium)
        XCTAssertTrue(try XCTUnwrap(candidate.modelEntries.first).overrides.isEmpty)

        let persisted = try await database.nmApplyConfigurationChanges(from: .empty, to: candidate)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(persisted))
        XCTAssertEqual(decoded, candidate)
    }

    /// 新增时读到旧行损坏必须拒绝整个事务，不能发布新实例或改写原镜像掩盖问题。
    func testMalformedExistingJSONRejectsNewProviderWithoutPartialWrite() async throws {
        let fields = [
            ("provider_model_entries", "base_model_json"),
            ("provider_model_entries", "overrides_json"),
            ("provider_model_groups", "member_entry_ids_json"),
            ("provider_model_groups", "added_members_json"),
            ("provider_model_groups", "removed_members_json"),
            ("provider_session_bindings", "binding_json"),
            ("provider_session_inference_configs", "config_json"),
        ]
        for (table, column) in fields {
            let root = try directory()
            let mirror = root.appendingPathComponent("provider-config.json")
            let databaseURL = root.appendingPathComponent("provider-config.db")
            let baseline = populatedConfiguration()
            let originalData = try JSONEncoder().encode(baseline)
            try originalData.write(to: mirror)
            let database = try ProviderConfigDB(url: databaseURL)
            _ = try await database.nmApplyConfigurationChanges(from: .empty, to: baseline)
            let store = ProviderConfigStore(fileURL: mirror, database: database)
            let originalCache = store.config
            let token = UUID()
            try await store.nmBeginRestore(token)
            defer { store.nmEndRestore(token) }
            try withDatabase(databaseURL) { connection in
                try NivoSQLiteWrite.execute(connection, sql: "UPDATE \(table) SET \(column)=?", values: [.text("{broken")])
            }
            let prepared = try NivoProviderSetupConfiguration.prepare(instance: keylessInstance(id: "new-provider"),
                apiKey: "", current: store.config)
            do {
                try await store.nmCommitImportedConfiguration(prepared.configuration, token: token)
                XCTFail("损坏字段应阻止新增：\(table).\(column)")
            } catch {
                XCTAssertEqual(store.config, originalCache)
                XCTAssertEqual(try Data(contentsOf: mirror), originalData)
                let count = try withDatabase(databaseURL) { connection in
                    try NivoSQLiteWrite.readRow(connection,
                        sql: "SELECT COUNT(*) FROM provider_instances WHERE id=?", values: [.text("new-provider")]) {
                            sqlite3_column_int64($0, 0)
                        }
                }
                XCTAssertEqual(count, 0, "失败事务不能留下新实例")
            }
        }
    }

    /// 固定时间和本机示例端点让字段比较与网络、Keychain及当前日期无关。
    private func keylessInstance(id: String) -> ProviderInstance {
        ProviderInstance(id: id, label: "自定义fixture", providerType: .openAI, credentialType: .apiKey,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.125), customBaseURL: "http://localhost:11434")
    }

    /// 每个由配置仓库生成的JSON列都至少包含一个非默认值。
    private func populatedConfiguration() -> ProviderConfig {
        let instance = keylessInstance(id: "provider")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.125)
        var model = LLMModel(id: "fixture-model", displayName: "模型\"甲\"", provider: "fixture",
            modalityOverride: [.textInput, .imageInput, .textOutput], contextWindow: 65_536, maxOutputTokens: 4096,
            supportsReasoning: true, interleavedReasoningField: "reasoning_content",
            reasoningEffortValues: ["low", "high"], declaresNoEffortTiers: false)
        model.effortDeclarationIsAuthoritative = true
        let entry = ModelEntry(uuid: "11111111-1111-4111-8111-111111111111", providerInstanceId: instance.id,
            model: model, overrides: .init(displayName: "自定义\n模型", maxOutputTokens: 2048,
                modalityOverride: [.textInput, .textOutput], contextWindow: 32_768,
                supportsReasoning: true, maxThinkingLevel: .high),
            isCustom: true, isHidden: true, userModifiedAt: timestamp)
        let group = ModelGroup(id: "group", name: "fixture", memberEntryIds: [entry.uuid],
            strategy: .loadBalance, fallbackStrategy: .always, defaultThinkingLevel: .medium,
            contextLimitTokens: 8192, lastContextLimitTokens: 16_384,
            addedMembers: [entry.uuid: timestamp], removedMembers: ["removed": timestamp])
        let binding = SessionModelBinding(sessionId: "session", primarySource: .directEntry(
            modelEntryId: entry.uuid, compositeKey: entry.id),
            subModelSource: .group(groupId: group.id, resolvedEntryId: entry.id))
        var inference = SessionInferenceConfig()
        inference.thinkingLevel = .high
        return ProviderConfig(instances: [instance], modelEntries: [entry], modelGroups: [group],
            defaultPrimaryGroupId: group.id, defaultSubGroupId: group.id, sessionBindings: [binding.sessionId: binding],
            agentLoopModelEntryIds: [entry.id], agentLoopGroupIds: [group.id], voiceInputGroupId: group.id,
            voiceOutputGroupId: group.id, visionGroupId: group.id, sessionInferenceConfigs: [binding.sessionId: inference],
            deletedInstances: [.init(id: "retired-provider", deletedAt: timestamp)],
            deletedModelEntries: [.init(id: "retired-entry", deletedAt: timestamp)],
            deletedModelGroups: [.init(id: "retired-group", deletedAt: timestamp)])
    }

    /// 诊断连接仅打开当前测试创建的数据库，不创建或访问默认数据库。
    private func withDatabase<Result>(_ url: URL, body: (OpaquePointer) throws -> Result) throws -> Result {
        var connection: OpaquePointer?
        defer { if let connection { sqlite3_close(connection) } }
        let status = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil)
        guard status == SQLITE_OK, let connection else {
            throw NivoSQLiteWriteError.sqlite(operation: "codec_test_open", code: status)
        }
        return try body(connection)
    }

    /// 每个案例独占临时目录，结束时清理自己的测试文件。
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-codec-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}
