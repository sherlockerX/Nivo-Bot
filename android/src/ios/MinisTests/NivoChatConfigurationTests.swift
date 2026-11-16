import XCTest
@testable import Minis

/// 分支配置写盘失败必须可见，不能在重启后悄悄恢复默认模型。
@MainActor
final class NivoChatConfigurationTests: XCTestCase {
    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("config.json")
    }

    func testBranchConfigurationSurvivesReload() async throws {
        let url = try location()
        let store = ProviderConfigStore(fileURL: url)
        let identifier = UUID().uuidString
        let binding = SessionModelBinding(sessionId: identifier,
            primarySource: .directEntry(modelEntryId: "fixture"), subModelSource: nil)
        var inference = SessionInferenceConfig()
        inference.thinkingLevel = .medium
        try await store.nmSetBranchConfiguration(sessionID: identifier, binding: binding, inference: inference)
        let restored = ProviderConfigStore(fileURL: url)
        XCTAssertEqual(restored.binding(for: identifier), binding)
        XCTAssertEqual(restored.inferenceConfig(for: identifier), inference)
    }

    func testFailedWriteDoesNotPublishBranchConfiguration() async throws {
        let url = try location()
        let store = ProviderConfigStore(fileURL: url)
        // 用同名目录模拟目标文件无法替换，不依赖设备磁盘空间。
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let binding = SessionModelBinding(sessionId: identifier,
            primarySource: .directEntry(modelEntryId: "fixture"), subModelSource: nil)
        do {
            try await store.nmSetBranchConfiguration(sessionID: identifier, binding: binding,
                                                       inference: SessionInferenceConfig())
            XCTFail("目标文件不可写时必须返回失败")
        } catch {}
        XCTAssertNil(store.binding(for: identifier))
        XCTAssertNil(store.inferenceConfig(for: identifier))
    }
}
