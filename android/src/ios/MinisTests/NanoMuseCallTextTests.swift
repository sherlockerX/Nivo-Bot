import XCTest
@testable import Minis

/// 覆盖插话识别、回声排除、数字边界和最后一段正文的保留。
final class NanoMuseCallTextTests: XCTestCase {
    func testRejectsEchoAndSingleCharacterNoise() {
        XCTAssertFalse(NanoMuseCallText.cutsIn("嗯", spoken: ""))
        XCTAssertFalse(NanoMuseCallText.cutsIn("今天晴天", spoken: "今天晴天，可以出去散步。"))
        XCTAssertFalse(NanoMuseCallText.cutsIn("the weather is sunny", spoken: "The weather is sunny today."))
    }

    func testAcceptsDifferentSpeechInChineseAndEnglish() {
        XCTAssertTrue(NanoMuseCallText.cutsIn("等一下换个话题", spoken: "今天晴天。"))
        XCTAssertTrue(NanoMuseCallText.cutsIn("stop please", spoken: "The weather is sunny."))
        XCTAssertTrue(NanoMuseCallText.cutsIn("继续", spoken: ""))
    }

    func testKeepsDecimalsAndTimesTogether() {
        var buffer = "价格3.5元，10:30出发。"
        XCTAssertEqual(NanoMuseCallText.takeChunks(from: &buffer), ["价格3.5元，", "10:30出发。"])
        XCTAssertEqual(buffer, "")
    }

    func testFlushPreservesFinalFragment() {
        var buffer = "Hello, remaining"
        XCTAssertEqual(NanoMuseCallText.takeChunks(from: &buffer), ["Hello,"])
        XCTAssertEqual(NanoMuseCallText.takeChunks(from: &buffer, flush: true), ["remaining"])
        XCTAssertEqual(buffer, "")
    }
}
