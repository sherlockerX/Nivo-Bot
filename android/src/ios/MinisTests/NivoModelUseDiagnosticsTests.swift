import XCTest
@testable import Minis

/// 模型名和操作提示应独立表达，避免把整个提示误报成模型ID。
final class NivoModelUseDiagnosticsTests: XCTestCase {
    func testEmptyAuthorizedListKeepsExactModelName() {
        let message = ModelUseError.modelNotFound("deepseek-v4.1-flash",
            hint: NivoModelUseDiagnostics.noModelsHint).localizedDescription
        XCTAssertTrue(message.hasPrefix("Model 'deepseek-v4.1-flash' not found."))
        XCTAssertTrue(message.contains("\n" + NivoModelUseDiagnostics.noModelsHint))
        XCTAssertFalse(message.contains("flash \u{2014}"))
    }

    func testProviderFailureIsNotWrappedAsModelName() {
        let message = ModelUseError.providerNotFound("secondary").localizedDescription
        XCTAssertTrue(message.hasPrefix("No available authorized model matches --provider 'secondary'."))
        XCTAssertFalse(message.contains("Model 'No"))
    }

    func testMissingModelRetainsListDiscoveryHint() {
        XCTAssertEqual(ModelUseError.modelNotFound("missing").localizedDescription,
            "Model 'missing' not found. Use 'minis-model-use list' to see available models.")
    }

    func testEmptyListHintExplainsSeparateAuthorizationAndSettingsEntry() {
        let hint = NivoModelUseDiagnostics.noModelsHint
        XCTAssertTrue(hint.contains("Models \(NivoProduct.name) Can Call at Runtime"))
        XCTAssertTrue(hint.contains("Chat model selection is separate"))
        XCTAssertTrue(hint.contains("minis://settings/model-groups"))
    }
}
