import XCTest
@testable import Minis

/// 验证不同版本成员历史的真实JSON边界，损坏数据不得被解释为没有删除记录。
final class NivoProviderMemberHistoryTests: XCTestCase {
    func testMissingLegacyHistoryAndEmptyObjectAreEmpty() throws {
        let inputs: [String?] = [nil, "", "{}"]
        for input in inputs {
            let history = try NivoProviderMemberHistory.decode(input)
            XCTAssertTrue(history.added.isEmpty)
            XCTAssertTrue(history.removed.isEmpty)
        }
    }

    func testFlatLegacyRemovalTimestampsRemainEffective() throws {
        let history = try NivoProviderMemberHistory.decode("{\"provider/model\":123,\"added\":456}")
        XCTAssertTrue(history.added.isEmpty)
        XCTAssertEqual(history.removed["provider/model"]?.timeIntervalSince1970, 123)
        XCTAssertEqual(history.removed["added"]?.timeIntervalSince1970, 456)
    }

    func testCurrentEnvelopePreservesBothMapsAndIgnoresAdditionalFields() throws {
        let history = try NivoProviderMemberHistory.decode("{\"added\":{\"model\":20},\"removed\":{\"other\":30},\"future\":{\"schema\":2}}")
        XCTAssertEqual(history.added["model"]?.timeIntervalSince1970, 20)
        XCTAssertEqual(history.removed["other"]?.timeIntervalSince1970, 30)
    }

    func testCorruptOrUnknownHistoryNeverBecomesEmpty() throws {
        for input in ["broken", "[]", "null", "{\"removed\":null}",
                      "{\"removed\":{\"model\":true}}", "{\"model\":\"123\"}",
                      "{\"added\":{\"model\":1e400}}", "{\"future\":{\"members\":[]}}"] {
            XCTAssertThrowsError(try NivoProviderMemberHistory.decode(input), input)
        }
    }

    func testDatabaseMapRejectsMalformedExistingValue() throws {
        XCTAssertThrowsError(try NivoProviderMemberHistory.decodeMap("{\"model\":\"yesterday\"}"))
        let result = try NivoProviderMemberHistory.decodeMap("{\"model\":42}")
        XCTAssertEqual(result["model"]?.timeIntervalSince1970, 42)
    }
}
