import XCTest
@testable import Minis

/// 动态配置路径必须保留接口ID中的点号和斜线。
final class NivoConfigPathTests: XCTestCase {
    func testDottedModelIDRemainsWhole() {
        let identifier = "provider/deepseek-v4.1-flash"
        XCTAssertEqual(NivoConfigPath.childIDs(
            matching: "models.\(identifier).contextWindow", basePath: "models",
            existingIDs: [identifier]), [identifier])
    }

    func testNestedLeafAndSlashedModelIDRemainResolvable() {
        let identifier = "provider/vendor/model.v2"
        XCTAssertEqual(NivoConfigPath.childIDs(
            matching: "models.\(identifier).modality.video", basePath: "models",
            existingIDs: [identifier]), [identifier])
    }

    func testLongestExistingIdentityIsConsideredFirst() {
        XCTAssertEqual(NivoConfigPath.childIDs(
            matching: "models.provider/model.v2.contextWindow", basePath: "models",
            existingIDs: ["provider/model", "provider/model.v2"]),
            ["provider/model.v2", "provider/model"])
    }

    func testPrefixDoesNotMatchAnotherCollectionOrPartialIdentity() {
        for path in ["models2.first.contextWindow", "models.firstExtra.contextWindow",
                     "models.first", "models.first.", "models..contextWindow"] {
            XCTAssertTrue(NivoConfigPath.childIDs(
                matching: path, basePath: "models", existingIDs: ["first"]).isEmpty)
        }
    }

    func testUnknownIdentityIsNeverSynthesized() {
        XCTAssertTrue(NivoConfigPath.childIDs(
            matching: "providers.missing.apiKey", basePath: "providers",
            existingIDs: ["present"]).isEmpty)
    }
}
