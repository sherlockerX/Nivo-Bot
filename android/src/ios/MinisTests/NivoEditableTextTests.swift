import Foundation
import XCTest
@testable import Minis

/// 只在测试临时目录读取，验证文件缺失、默认文案和损坏是不同状态。
final class NivoEditableTextTests: XCTestCase {
    private func withFile(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory.appendingPathComponent("preferences.md"))
    }

    func testMissingFileOpensWithoutWritingDefaults() throws {
        try withFile { file in
            XCTAssertEqual(try NivoEditableText.readIfPresent(file), "")
            XCTAssertEqual(try NivoEditableText.preferences(at: file, fallback: "Default"), "Default")
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testExistingTextAndIntentionallyEmptyPreference() throws {
        try withFile { file in
            try "  My notes\n".write(to: file, atomically: true, encoding: .utf8)
            XCTAssertEqual(try NivoEditableText.readIfPresent(file), "  My notes\n")
            XCTAssertEqual(try NivoEditableText.preferences(at: file, fallback: "Default"), "My notes")
            try "\n".write(to: file, atomically: true, encoding: .utf8)
            XCTAssertEqual(try NivoEditableText.preferences(at: file, fallback: "Default"), "Default")
        }
    }

    func testUnreadableOrInvalidFileDoesNotBecomeEditableDefault() throws {
        try withFile { file in
            let bytes = Data([0xff, 0xfe, 0x80])
            try bytes.write(to: file)
            XCTAssertThrowsError(try NivoEditableText.preferences(at: file, fallback: "Default"))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertThrowsError(try NivoEditableText.readIfPresent(file.deletingLastPathComponent()))
        }
    }
}
