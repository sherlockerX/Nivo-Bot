import Foundation
import XCTest
@testable import Minis

/// 使用实际写盘队列和文件故障验证本地模式迁移的重放边界。
@MainActor
final class NivoLocalModeRecoveryTests: XCTestCase {
    func testFailedConfigurationReplaysBeforeTheNextStrictBaselineWait() async throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
        let transaction = NivoLocalModeConfigurationTransaction<String>()
        let queue = NivoProviderWriteQueue()
        var published = "enabled"
        do {
            try await commit(transaction, queue: queue, destination: fixture.destination,
                current: published, candidate: "disabled", publish: { published = $0 })
            XCTFail("保存失败不能发布停用配置")
        } catch {}
        XCTAssertTrue(transaction.hasPendingConfiguration)
        XCTAssertEqual(published, "enabled")
        try FileManager.default.removeItem(at: fixture.destination)
        try await commit(transaction, queue: queue, destination: fixture.destination,
            current: published, candidate: nil, publish: { published = $0 })
        try await queue.waitUntilIdle()
        XCTAssertFalse(transaction.hasPendingConfiguration)
        XCTAssertEqual(published, "disabled")
        XCTAssertEqual(try String(contentsOf: fixture.destination, encoding: .utf8), "disabled")
    }

    func testUnrelatedWriteFailureCannotBecomeAnOwnedRetry() async throws {
        let fixture = try makeFixture()
        let transaction = NivoLocalModeConfigurationTransaction<String>()
        let queue = NivoProviderWriteQueue()
        queue.enqueue { throw CocoaError(.fileWriteOutOfSpace) }
        do {
            try await commit(transaction, queue: queue, destination: fixture.destination,
                current: "enabled", candidate: "disabled", publish: { _ in XCTFail() })
            XCTFail("没有迁移快照时必须传播已有保存错误")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace) }
        XCTAssertFalse(transaction.hasPendingConfiguration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testCorruptBaselineStillBlocksAnOwnedRetry() async throws {
        let transaction = NivoLocalModeConfigurationTransaction<String>()
        do {
            try await transaction.run(current: "enabled", candidate: "disabled",
                waitForBaseline: { _ in }, persist: { _, _ in throw CocoaError(.fileWriteOutOfSpace) },
                publish: { _ in XCTFail() })
        } catch {}
        do {
            try await transaction.run(current: "enabled", candidate: nil,
                waitForBaseline: { isReplay in
                    XCTAssertTrue(isReplay)
                    throw CocoaError(.fileReadCorruptFile)
                }, persist: { _, _ in XCTFail(); return "disabled" }, publish: { _ in XCTFail() })
            XCTFail("已持有迁移意图也不能覆盖损坏基线")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile) }
        XCTAssertTrue(transaction.hasPendingConfiguration)
    }

    func testChangedBaselinePreventsAStaleReplay() async throws {
        let transaction = NivoLocalModeConfigurationTransaction<String>()
        do {
            try await transaction.run(current: "enabled", candidate: "disabled",
                waitForBaseline: { _ in }, persist: { _, _ in throw CocoaError(.fileWriteOutOfSpace) },
                publish: { _ in XCTFail() })
        } catch {}
        do {
            try await transaction.run(current: "new-user-configuration", candidate: nil,
                waitForBaseline: { _ in }, persist: { _, _ in XCTFail(); return "disabled" },
                publish: { _ in XCTFail() })
            XCTFail("旧迁移意图不能覆盖后来的用户配置")
        } catch {}
        XCTAssertTrue(transaction.hasPendingConfiguration)
    }

    func testRestartRebuildsRetirementFromPersistedIdentityWithoutChangingOwner() async throws {
        let fixture = try makeFixture()
        let identityURL = fixture.root.appendingPathComponent("identity.json")
        let identity = try NivoLocalIdentity.prepare(at: identityURL, legacyOwner: "existing-owner", retiring: ["old-relay"])
        let firstProcess = NivoLocalModeConfigurationTransaction<String>()
        do {
            try await firstProcess.run(current: "enabled", candidate: "disabled",
                waitForBaseline: { _ in }, persist: { _, _ in throw CocoaError(.fileWriteOutOfSpace) },
                publish: { _ in XCTFail() })
        } catch {}
        let restartedIdentity = try NivoLocalIdentity.prepare(at: identityURL,
            legacyOwner: "different-owner", retiring: [])
        XCTAssertEqual(restartedIdentity, identity)
        XCTAssertTrue(NivoLocalIdentity.isRetiredProvider(id: "old-relay", baseURL: nil,
            retiredIDs: restartedIdentity.retiredProviderIDs))
        let secondProcess = NivoLocalModeConfigurationTransaction<String>()
        let queue = NivoProviderWriteQueue()
        var published = "enabled"
        try await commit(secondProcess, queue: queue, destination: fixture.destination,
            current: published, candidate: "disabled", publish: { published = $0 })
        XCTAssertEqual(published, "disabled")
        XCTAssertEqual(try NivoLocalIdentity.read(from: identityURL)?.owner, "existing-owner")
    }

    func testPublicationFailureRetainsTheExactReplayTarget() async throws {
        let transaction = NivoLocalModeConfigurationTransaction<String>()
        do {
            try await transaction.run(current: "enabled", candidate: "disabled",
                waitForBaseline: { _ in }, persist: { _, target in target },
                publish: { _ in throw CocoaError(.fileReadUnknown) })
        } catch {}
        XCTAssertTrue(transaction.hasPendingConfiguration)
        try await transaction.run(current: "enabled", candidate: nil, waitForBaseline: { _ in },
            persist: { baseline, target in
                XCTAssertEqual(baseline, "enabled")
                XCTAssertEqual(target, "disabled")
                return target
            }, publish: { XCTAssertEqual($0, "disabled") })
        XCTAssertFalse(transaction.hasPendingConfiguration)
    }

    private func commit(_ transaction: NivoLocalModeConfigurationTransaction<String>,
                        queue: NivoProviderWriteQueue, destination: URL,
                        current: String, candidate: String?, publish: @MainActor (String) throws -> Void) async throws {
        try await transaction.run(current: current, candidate: candidate,
            waitForBaseline: { isReplay in
                if isReplay { _ = try? await queue.waitUntilIdle() }
                else { try await queue.waitUntilIdle() }
            }, persist: { _, target in
                try await queue.enqueue { try Data(target.utf8).write(to: destination, options: .atomic) }.value
                return try String(contentsOf: destination, encoding: .utf8)
            }, publish: publish)
    }

    private func makeFixture() throws -> (root: URL, destination: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-retry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, root.appendingPathComponent("configuration.json"))
    }
}

#if canImport(UIKit)
/// Apple目标使用真实提供商仓库验证SQLite提交后镜像失败的恢复。
@MainActor
final class NivoLocalModeStoreRecoveryTests: XCTestCase {
    func testDatabaseCommitAndFailedMirrorReplayWithoutPublishingPartialCache() async throws {
        let fixture = try makeFixture()
        let database = try ProviderConfigDB(url: fixture.root.appendingPathComponent("providers.db"))
        try await database.nmBulkReplace(from: fixture.configuration)
        let store = ProviderConfigStore(fileURL: fixture.url, database: database)
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        do {
            try await store.nmCommitLocalModeRetirement(retiring: ["old-relay"])
            XCTFail("镜像失败必须留在恢复流程")
        } catch {}
        XCTAssertEqual(store.config, fixture.configuration)
        let committed = try await database.nmDumpProviderConfig()
        XCTAssertFalse(try XCTUnwrap(committed.instances.first { $0.id == "old-relay" }).isEnabled)
        try FileManager.default.removeItem(at: fixture.url)
        try await store.nmReplayPendingLocalModeRetirement()
        try await store.nmWaitForMigrationBaseline(retryingFailedWrites: false)
        let mirrored = try JSONDecoder().decode(ProviderConfig.self, from: Data(contentsOf: fixture.url))
        XCTAssertEqual(mirrored, store.config)
        XCTAssertFalse(try XCTUnwrap(mirrored.instances.first { $0.id == "old-relay" }).isEnabled)
        XCTAssertTrue(try XCTUnwrap(mirrored.instances.first { $0.id == "user-api" }).isEnabled)
        XCTAssertEqual(mirrored.modelEntries, fixture.configuration.modelEntries)
        XCTAssertEqual(mirrored.sessionBindings, fixture.configuration.sessionBindings)
    }

    func testRestartUsesDurableRetirementIDsAfterConfigurationNeverReachedDisk() async throws {
        let fixture = try makeFixture()
        let identityURL = fixture.root.appendingPathComponent("identity.json")
        let identity = try NivoLocalIdentity.prepare(at: identityURL,
            legacyOwner: "existing-owner", retiring: ["old-relay"])
        let firstStore = ProviderConfigStore(fileURL: fixture.url)
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        do { try await firstStore.nmCommitLocalModeRetirement(retiring: identity.retiredProviderIDs); XCTFail() }
        catch {}
        try FileManager.default.removeItem(at: fixture.url)
        try JSONEncoder().encode(fixture.configuration).write(to: fixture.url, options: .atomic)
        let restartedStore = ProviderConfigStore(fileURL: fixture.url)
        let savedIdentity = try XCTUnwrap(NivoLocalIdentity.read(from: identityURL))
        try await restartedStore.nmCommitLocalModeRetirement(retiring: savedIdentity.retiredProviderIDs)
        XCTAssertFalse(try XCTUnwrap(restartedStore.config.instances.first { $0.id == "old-relay" }).isEnabled)
        XCTAssertEqual(try NivoLocalIdentity.read(from: identityURL)?.owner, "existing-owner")
    }

    func testUnownedFailureRemainsVisibleWhenStartupAsksForReplay() async throws {
        let fixture = try makeFixture()
        let store = ProviderConfigStore(fileURL: fixture.url)
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        var changed = fixture.configuration
        changed.instances[1].label = "user-change"
        store.applyConfig(changed)
        do { try await store.nmWaitForConfigurationWrites(); XCTFail() } catch {}
        try FileManager.default.removeItem(at: fixture.url)
        try await store.nmReplayPendingLocalModeRetirement()
        do {
            try await store.nmWaitForMigrationBaseline(retryingFailedWrites: false)
            XCTFail("没有迁移重放目标时不能清除普通配置的保存错误")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    private func makeFixture() throws -> (root: URL, url: URL, configuration: ProviderConfig) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("providers.json")
        var configuration = ProviderConfig.empty
        configuration.instances = [
            ProviderInstance(id: "old-relay", label: "old", providerType: .openAI, credentialType: .apiKey),
            ProviderInstance(id: "user-api", label: "own", providerType: .openAI, credentialType: .apiKey),
        ]
        let entry = ModelEntry(providerInstanceId: "old-relay",
            model: LLMModel(id: "fixture-model", displayName: "fixture", provider: "OpenAI"))
        configuration.modelEntries = [entry]
        let sessionID = UUID().uuidString
        configuration.sessionBindings[sessionID] = SessionModelBinding(sessionId: sessionID,
            primarySource: .directEntry(modelEntryId: entry.id), subModelSource: nil)
        try JSONEncoder().encode(configuration).write(to: url, options: .atomic)
        return (root, url, configuration)
    }
}
#endif
