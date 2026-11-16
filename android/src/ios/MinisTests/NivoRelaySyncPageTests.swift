import XCTest
@testable import Minis

/// 验证真实JSON协议边界，错误页必须停在原游标。
final class NivoRelaySyncPageTests: XCTestCase {
    func testMissingCollectionAndMalformedRecordDoNotBecomeEmptyPage() throws {
        XCTAssertThrowsError(try NivoRelaySyncPage.decode(Data(#"{"cursor":5,"more":false,"conversations":[]}"#.utf8), since: 0))
        let malformed = #"{"cursor":5,"more":false,"conversations":[],"messages":[{"mid":"bad"}]}"#
        XCTAssertThrowsError(try NivoRelaySyncPage.decode(Data(malformed.utf8), since: 0))
    }

    func testNonAdvancingAndRegressingPageAreRejected() {
        XCTAssertThrowsError(try NivoRelaySyncPage.decode(Data(#"{"cursor":5,"more":true,"conversations":[],"messages":[]}"#.utf8), since: 5))
        XCTAssertThrowsError(try NivoRelaySyncPage.decode(Data(#"{"cursor":4,"more":false,"conversations":[],"messages":[]}"#.utf8), since: 5))
    }

    func testValidPagePreservesRemoteTimestampAndAttachmentNames() throws {
        let json = #"{"cursor":7,"more":false,"conversations":[{"cid":"chat","kind":"main","title":"title","created_at":1,"updated_at":2,"deleted":false}],"messages":[{"mid":"message","cid":"chat","role":"user","text":"hello","created_at":3,"deleted":false,"attachments":[{"name":"file.txt"}]}]}"#
        let page = try NivoRelaySyncPage.decode(Data(json.utf8), since: 5)
        XCTAssertEqual(page.cursor, 7)
        XCTAssertEqual(page.messages.first?.createdAt, 3)
        XCTAssertEqual(page.messages.first?.attachments?.first?.name, "file.txt")
    }

    func testMalformedUploadReceiptCannotAcknowledgeMessages() throws {
        XCTAssertThrowsError(try NivoRelayPushReceipt.decode(Data("{}".utf8)))
        let receipt = try NivoRelayPushReceipt.decode(Data(#"{"cursor":7,"accepted":1,"rejected":[{"cid":"chat","reason":"main_exists","cid_main":"shared"}]}"#.utf8))
        XCTAssertEqual(receipt.rejected.first?.cidMain, "shared")
    }
}
