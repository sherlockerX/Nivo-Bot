import XCTest
@testable import Minis

/// 轮换失败只恢复本次仍拥有的写入，后续编辑、删除及同值新版本必须保留。
final class NivoProviderKeyRotationTests: XCTestCase {
    func testLocalStageCapturePrefersLocalValueAndVersion() throws {
        var stage = try fixture()
        stage.targetIsLocal = true
        stage.previousLocal = secret("fixture-local")
        stage.previousLocal?.version = try JSONEncoder().encode(NivoProviderKeyRotation.Version(schema: 1, seconds: 300))
        stage.previousSync?.version = try JSONEncoder().encode(NivoProviderKeyRotation.Version(schema: 1, seconds: 400))
        XCTAssertTrue(try stage.matchesPrevious(value: stage.previousLocal?.value,
            version: Date(timeIntervalSince1970: 300), fallbackVersion: .distantPast))
        XCTAssertFalse(try stage.matchesPrevious(value: stage.previousSync?.value,
            version: Date(timeIntervalSince1970: 400), fallbackVersion: .distantPast))
    }

    func testLocalStageRestoresLocalSnapshotAndKeepsLegacyStageCompatible() throws {
        var oldStage = try fixture()
        oldStage.previousLocal = secret("fixture-local-priority")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(oldStage)) as? [String: Any])
        object["targetIsLocal"] = true
        let localStage = try JSONDecoder().decode(NivoProviderKeyRotation.Stage.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(try localStage.rollback(current: localStage.replacement), .restore(oldStage.previousLocal!))
        object.removeValue(forKey: "targetIsLocal")
        let legacyStage = try JSONDecoder().decode(NivoProviderKeyRotation.Stage.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(try legacyStage.rollback(current: legacyStage.replacement), .restore(oldStage.previousSync!))
    }

    func testOwnedReplacementRestoresPreviousSecretAndVersion() throws {
        let stage = try fixture()
        XCTAssertEqual(try stage.rollback(current: stage.replacement), .restore(stage.previousSync!))
    }

    func testLegacyOnlyReplacementRemovesOnlyNewSyncEntry() throws {
        var stage = try fixture()
        stage.previousSync = nil
        stage.previousLocal = secret("fixture-legacy")
        XCTAssertEqual(try stage.rollback(current: stage.replacement), .remove)
    }

    func testRollbackDoesNotResurrectAnEntryDeletedLater() throws {
        let stage = try fixture()
        XCTAssertEqual(try stage.rollback(current: nil), .preserve)
    }

    func testLaterSameValueSaveWithNewVersionIsPreserved() throws {
        let stage = try fixture()
        var current = stage.replacement
        current.version = try JSONEncoder().encode(NivoProviderKeyRotation.Version(schema: 1, seconds: 300))
        current.comment = ""
        XCTAssertEqual(try stage.rollback(current: current), .preserve)
    }

    func testSecondRollbackPreservesAlreadyRestoredValue() throws {
        let stage = try fixture()
        XCTAssertEqual(try stage.rollback(current: stage.previousSync), .preserve)
    }

    func testStageRejectsForeignOwnershipAndMalformedVersion() throws {
        var stage = try fixture()
        stage.replacement.comment = "another-operation"
        XCTAssertThrowsError(try stage.validate())
        stage = try fixture()
        stage.replacement.version = Data("broken".utf8)
        XCTAssertThrowsError(try stage.validate())
    }

    func testRecoveryReceiptContainsOnlyIdentity() throws {
        let stage = try fixture()
        let encoded = try JSONEncoder().encode(stage.receipt)
        XCTAssertEqual(try JSONDecoder().decode(NivoProviderKeyRotation.Receipt.self, from: encoded), stage.receipt)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("fixture-secret"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("value"))
    }

    func testInvalidReceiptFailsBeforeAnyCredentialOperation() throws {
        for identifier in ["", String(repeating: "p", count: 513), "instance\0tail"] {
            let receipt = NivoProviderKeyRotation.Receipt(identifier: UUID(), instanceID: identifier)
            XCTAssertThrowsError(try receipt.validate())
        }
    }

    func testStageCaptureRejectsChangedValueAfterInitialObservation() throws {
        let stage = try fixture()
        XCTAssertFalse(try stage.matchesPrevious(value: Data("fixture-earlier".utf8),
            version: Date(timeIntervalSince1970: 100), fallbackVersion: Date(timeIntervalSince1970: 100)))
    }

    func testStageCaptureRejectsSameValueWithLaterVersion() throws {
        var stage = try fixture()
        stage.previousSync?.version = try JSONEncoder().encode(NivoProviderKeyRotation.Version(schema: 1, seconds: 101))
        XCTAssertFalse(try stage.matchesPrevious(value: stage.previousSync?.value,
            version: Date(timeIntervalSince1970: 100), fallbackVersion: Date(timeIntervalSince1970: 100)))
    }

    func testStageCaptureUsesLegacyFallbackOnlyForUnversionedSecret() throws {
        var stage = try fixture()
        stage.previousLocal = stage.previousSync
        stage.previousSync = nil
        let observed = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(try stage.matchesPrevious(value: stage.previousLocal?.value, version: observed, fallbackVersion: observed))
        XCTAssertFalse(try stage.matchesPrevious(value: stage.previousLocal?.value, version: observed,
            fallbackVersion: Date(timeIntervalSince1970: 101)))
    }

    func testStageCaptureDistinguishesAbsentAndNewlyAppearedCredential() throws {
        var stage = try fixture()
        XCTAssertFalse(try stage.matchesPrevious(value: nil, version: nil, fallbackVersion: .distantPast))
        stage.previousSync = nil
        XCTAssertTrue(try stage.matchesPrevious(value: nil, version: nil, fallbackVersion: .distantPast))
        XCTAssertFalse(try stage.matchesPrevious(value: Data("fixture-old".utf8),
            version: .distantPast, fallbackVersion: .distantPast))
    }

    func testStageCaptureRejectsMalformedCapturedVersion() throws {
        var stage = try fixture()
        stage.previousSync?.version = Data("broken".utf8)
        XCTAssertThrowsError(try stage.matchesPrevious(value: stage.previousSync?.value,
            version: .distantPast, fallbackVersion: .distantPast))
    }

    private func fixture() throws -> NivoProviderKeyRotation.Stage {
        let receipt = NivoProviderKeyRotation.Receipt(identifier: UUID(), instanceID: "fixture-provider")
        var replacement = secret("fixture-secret-new")
        replacement.comment = receipt.comment
        replacement.version = try JSONEncoder().encode(NivoProviderKeyRotation.Version(schema: 1, seconds: 200))
        return .init(receipt: receipt, previousSync: secret("fixture-secret-old"), previousLocal: nil,
            replacement: replacement)
    }

    private func secret(_ value: String) -> NivoProviderKeyRotation.Secret {
        .init(value: Data(value.utf8), version: nil, comment: "", accessibility: nil)
    }
}
