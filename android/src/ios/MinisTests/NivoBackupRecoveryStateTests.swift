import XCTest
@testable import Minis

/// 日志读取使用真实临时文件，不能把损坏日志当作可清理的孤立快照。
final class NivoBackupRecoveryStateTests: XCTestCase {
    func testProviderTransactionJournalKeepsIdentityAndQueueForRestart() throws {
        let file = try markerFile()
        let receipt = NivoProviderKeyRotation.Receipt(identifier: UUID(), instanceID: "fixture")
        let proposed = NivoProviderSetupSyncSQL.Record(type: "ProviderInstanceV3", id: "fixture", zone: "zone",
            operation: "upsert", priority: 0, createdAt: 100)
        let queue = NivoProviderSetupSyncSQL.Receipt(changes: [.init(previous: nil, proposed: proposed)])
        let marker = NivoBackupRecoveryState.Marker(backupId: "provider", startedAt: Date(timeIntervalSince1970: 100),
            categories: ["providers"], runId: "run", snapshotNames: [], providerKeyRotation: receipt, providerSetupQueue: queue)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: file)
        XCTAssertEqual(NivoBackupRecoveryState.read(file).marker, marker)
    }

    func testProviderTransactionReceiptCannotBeAttachedToOtherRecoveryCategories() throws {
        let file = try markerFile()
        let receipt = NivoProviderKeyRotation.Receipt(identifier: UUID(), instanceID: "fixture")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for categories in [["chats"], ["providers", "chats"], []] {
            let marker = NivoBackupRecoveryState.Marker(backupId: "provider", startedAt: Date(), categories: categories,
                runId: "run", snapshotNames: [], providerKeyRotation: receipt)
            try encoder.encode(marker).write(to: file)
            XCTAssertNil(NivoBackupRecoveryState.read(file).marker)
            XCTAssertTrue(NivoBackupRecoveryState.read(file).requiresRecovery)
        }
    }

    private func markerFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("in-progress.json")
    }

    func testAbsentJournalAllowsNormalUse() throws {
        let state = NivoBackupRecoveryState.read(try markerFile())
        XCTAssertFalse(state.requiresRecovery)
        XCTAssertFalse(state.affectsPersonalData)
        XCTAssertNil(state.marker)
    }

    func testValidJournalPreservesCategoryAndIdentity() throws {
        let file = try markerFile()
        let marker = NivoBackupRecoveryState.Marker(backupId: "backup", startedAt: Date(timeIntervalSince1970: 1_000),
            categories: ["personal_data", "chats"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: file)
        let state = NivoBackupRecoveryState.read(file)
        XCTAssertEqual(state.marker, marker)
        XCTAssertTrue(state.requiresRecovery)
        XCTAssertTrue(state.affectsPersonalData)
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(NivoBackupRecoveryState.read(file).requiresRecovery)
    }

    func testUnrelatedCategoryDoesNotClaimPersonalDataWasModified() throws {
        let file = try markerFile()
        let marker = NivoBackupRecoveryState.Marker(backupId: "backup", startedAt: Date(), categories: ["providers"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: file)
        let state = NivoBackupRecoveryState.read(file)
        XCTAssertTrue(state.requiresRecovery)
        XCTAssertFalse(state.affectsPersonalData)
    }

    func testBoundJournalRetainsRunAndCompleteSnapshotManifest() throws {
        let file = try markerFile()
        let marker = NivoBackupRecoveryState.Marker(backupId: "backup", startedAt: Date(timeIntervalSince1970: 1_000),
            categories: ["personal_data"], runId: "run-123",
            snapshotNames: ["personal_data-0", "new.json.absent-path-of"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: file)
        XCTAssertEqual(NivoBackupRecoveryState.read(file).marker, marker)
        XCTAssertTrue(NivoBackupRecoveryState.read(file).requiresRecovery)
    }

    func testMalformedRunOrSnapshotManifestKeepsRecoveryBarrier() throws {
        let file = try markerFile()
        let invalidBindings: [(String?, [String]?)] = [
            ("../other", ["saved"]), ("", ["saved"]), ("run", nil),
            (nil, ["saved"]), ("run", ["saved", "saved"]),
            ("run", ["../outside"]), ("run", ["folder/child"]),
            ("run", ["folder\\child"]), ("run", ["."]), ("run", ["C:target"])
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for (runID, names) in invalidBindings {
            let marker = NivoBackupRecoveryState.Marker(backupId: "backup", startedAt: Date(),
                categories: ["providers"], runId: runID, snapshotNames: names)
            try encoder.encode(marker).write(to: file)
            let state = NivoBackupRecoveryState.read(file)
            XCTAssertTrue(state.requiresRecovery)
            XCTAssertTrue(state.affectsPersonalData)
            XCTAssertNil(state.marker)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testTruncatedOversizedOrDirectoryJournalRetainsRecoveryBarrier() throws {
        let file = try markerFile()
        for data in [Data(), Data("{\"backupId\":\"unfinished".utf8), Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1)] {
            try data.write(to: file)
            let state = NivoBackupRecoveryState.read(file)
            XCTAssertTrue(state.requiresRecovery)
            XCTAssertTrue(state.affectsPersonalData)
            XCTAssertNil(state.marker)
        }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertTrue(NivoBackupRecoveryState.read(file).requiresRecovery)
    }

    func testCredentialReceiptSurvivesJournalRoundTripWithoutValues() throws {
        let file = try markerFile()
        let receipt = NivoCredentialRestoreReceipt(identifier: UUID(), targets: [
            .init(kind: .providerAPIKey, owner: "fixture-provider"),
            .init(kind: .environment, owner: "FIXTURE_VALUE")
        ])
        let marker = NivoBackupRecoveryState.Marker(backupId: "backup", startedAt: Date(),
            categories: ["providers"], runId: "run", snapshotNames: [], credentialRestore: receipt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(marker)
        try data.write(to: file)
        XCTAssertEqual(NivoBackupRecoveryState.read(file).marker?.credentialRestore, receipt)
        let serialized = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(serialized.contains("valueData"))
        XCTAssertTrue(serialized.contains("providerAPIKey"))
    }

    func testCredentialReceiptRejectsDuplicateTargetsAndMalformedIdentifiers() throws {
        let valid = NivoCredentialRestoreReceipt.Target(kind: .providerAPIKey, owner: "provider")
        for targets in [[valid, valid], [.init(kind: .environment, owner: "../target")],
                        [.init(kind: .mcpTokens, owner: "")], [.init(kind: .providerEmail, owner: "id\0tail")]] {
            XCTAssertThrowsError(try NivoCredentialRestoreReceipt(identifier: UUID(), targets: targets).validate())
        }
    }

    func testCredentialReceiptRequiresBoundProviderRecoveryCategory() throws {
        let file = try markerFile()
        let receipt = NivoCredentialRestoreReceipt(identifier: UUID(), targets: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for categories in [["chats"], [String]()] {
            let marker = NivoBackupRecoveryState.Marker(backupId: "backup", startedAt: Date(),
                categories: categories, runId: "run", snapshotNames: [], credentialRestore: receipt)
            try encoder.encode(marker).write(to: file)
            XCTAssertTrue(NivoBackupRecoveryState.read(file).requiresRecovery)
            XCTAssertNil(NivoBackupRecoveryState.read(file).marker)
        }
    }
}
