import XCTest
@testable import Minis

/// 验证原生执行器使用的字节封装；需要真实Foundation和Objective-C桥接的应用测试目标。
final class NivoShellIOTests: XCTestCase {
    func testLargeScriptArgumentsRemainSeparateAndComplete() throws {
        let script = String(repeating: "x", count: 65_536)
        let invocation = try XCTUnwrap(NivoShellInvocation(executable: "/bin/sh",
            arguments: ["-c", script, "a;$(b)", ""], environment: [:]))
        XCTAssertEqual(invocation.argumentCount, 5)
        let arguments = invocation.argumentData.split(separator: 0, omittingEmptySubsequences: false)
        XCTAssertEqual(arguments[2].count, 65_536)
        XCTAssertEqual(String(decoding: arguments[3], as: UTF8.self), "a;$(b)")
        XCTAssertEqual(arguments[4].count, 0)
        XCTAssertNil(NivoShellInvocation(executable: "/bin/sh", arguments: ["x\0y"], environment: [:]))
        XCTAssertNil(NivoShellInvocation(executable: "/bin/sh", arguments: [String(repeating: "x", count: 131_072)], environment: [:]))
    }

    func testCustomEnvironmentOverridesDefaultExactlyOnce() throws {
        let invocation = try XCTUnwrap(NivoShellInvocation(executable: "/bin/sh", arguments: [],
            environment: ["HOME": "/var/minis/home", "TZ": "Asia/Shanghai", "EMPTY": ""]))
        let entries = invocation.environmentData.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(entries.filter { $0.hasPrefix("HOME=") }, ["HOME=/var/minis/home"])
        XCTAssertEqual(entries.filter { $0.hasPrefix("TZ=") }, ["TZ=Asia/Shanghai"])
        XCTAssertTrue(entries.contains("EMPTY="))
        XCTAssertNil(NivoShellInvocation(executable: "/bin/sh", arguments: [], environment: ["BAD=KEY": "value"]))
        XCTAssertNil(NivoShellInvocation(executable: "/bin/sh", arguments: [], environment: ["KEY": "x\0y"]))
    }

    func testCaptureCountsDiscardedBytesWithoutCuttingUnicodeScalar() {
        let capture = NivoShellCapture(maximumBytes: 5)
        capture.append(Data("你好".utf8))
        capture.append(Data("\nrest".utf8))
        capture.finish(reachedEOF: true)
        XCTAssertEqual(capture.totalBytes, 11)
        XCTAssertEqual(capture.output, "你")
        XCTAssertTrue(capture.isTruncated)
        XCTAssertNil(capture.captureError)
    }

    func testSplitUTF8AndMissingEOFRemainDistinct() {
        let capture = NivoShellCapture(maximumBytes: 10)
        capture.append(Data([0xE4, 0xBD]))
        capture.append(Data([0xA0, 0x0A]))
        capture.finish(reachedEOF: true)
        XCTAssertEqual(capture.output, "你\n")
        XCTAssertFalse(capture.isTruncated)
        XCTAssertNil(capture.captureError)

        let interrupted = NivoShellCapture(maximumBytes: 10)
        interrupted.append(Data("kept".utf8))
        interrupted.finish(reachedEOF: false)
        XCTAssertEqual(interrupted.output, "kept")
        XCTAssertNotNil(interrupted.captureError)

        let invalid = NivoShellCapture(maximumBytes: 10)
        invalid.append(Data([0xE4, 0xBD]))
        invalid.finish(reachedEOF: true)
        XCTAssertNotNil(invalid.captureError)
    }
}
