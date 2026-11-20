import XCTest
@testable import Minis

/// 生产身份规则的便携测试，不依赖UIKit、共享配置或真实凭据。
final class NivoProviderModelIdentityTests: XCTestCase {
    func testRenameLocatesOriginalUUIDEvenWhenCompositeIDChanged() throws {
        let values = identities()
        XCTAssertEqual(try NivoProviderModelIdentity.replacementIndex(
            for: .init(uuid: "first", providerID: "provider", modelID: "renamed"), in: values), 0)
    }

    func testDuplicateModelIDIsRejectedBeforeReplacingAnything() {
        XCTAssertThrowsError(try NivoProviderModelIdentity.replacementIndex(
            for: .init(uuid: "first", providerID: "provider", modelID: "second"), in: identities())) {
            XCTAssertEqual($0 as? NivoProviderModelIdentity.Failure, .duplicateModelID("second"))
        }
    }

    func testMissingOrMovedUUIDCannotEditAnotherProvidersModel() {
        for value in [NivoProviderModelIdentity(uuid: "missing", providerID: "provider", modelID: "first"),
                      .init(uuid: "first", providerID: "other", modelID: "first")] {
            XCTAssertThrowsError(try NivoProviderModelIdentity.replacementIndex(for: value, in: identities()))
        }
    }

    func testSameModelIDUnderDifferentProviderIsAllowed() throws {
        try NivoProviderModelIdentity.validateAddition(
            .init(uuid: "third", providerID: "other", modelID: "first"), in: identities())
    }

    func testAdditionRejectsDuplicateUUIDAndDuplicateModelID() {
        for value in [NivoProviderModelIdentity(uuid: "first", providerID: "other", modelID: "third"),
                      .init(uuid: "third", providerID: "provider", modelID: "first")] {
            XCTAssertThrowsError(try NivoProviderModelIdentity.validateAddition(value, in: identities()))
        }
    }

    func testInvalidModelIDsCannotPoisonStorageOrDeletionJournal() {
        for modelID in ["", "   ", "first\0second", "first\nsecond", String(repeating: "x", count: 4097)] {
            XCTAssertThrowsError(try NivoProviderModelIdentity.validateAddition(
                .init(uuid: "new", providerID: "provider", modelID: modelID), in: identities()))
        }
    }

    func testReferenceMigrationPreservesOrderAndCollapsesAliasesOnly() {
        let result = NivoProviderModelIdentity.remap(["left", "provider/first", "first", "right", "provider: first"],
            aliases: ["provider/first", "first"], target: "provider/renamed")
        XCTAssertEqual(result, ["left", "provider/renamed", "right", "provider: first"])
    }

    private func identities() -> [NivoProviderModelIdentity] {
        [.init(uuid: "first", providerID: "provider", modelID: "first"),
         .init(uuid: "second", providerID: "provider", modelID: "second")]
    }
}
