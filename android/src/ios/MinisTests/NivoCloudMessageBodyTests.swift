import XCTest
@testable import Minis

/// 真实文件验证附件读取；缺失或损坏不得回退成已成功同步的空回复。
final class NivoCloudMessageBodyTests: XCTestCase {
    func testInlineBodyMustExistAndMayBeAnExplicitEmptyArray() throws {
        XCTAssertEqual(try NivoCloudMessageBody.read(inline: "[]", assetURL: nil), "[]")
        XCTAssertThrowsError(try NivoCloudMessageBody.read(inline: nil, assetURL: nil))
    }

    func testAssetIsReadExactlyAndTakesPriorityOverStaleInline() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("body.json")
        let body = "[{\"type\":\"text\",\"text\":\"保留完整中文回复\"}]"
        try Data(body.utf8).write(to: file)
        XCTAssertEqual(try NivoCloudMessageBody.read(inline: "[]", assetURL: file), body)
    }

    func testMissingDirectoryAndInvalidEncodingAssetsThrowWithoutFallback() throws {
        let root = try temporaryDirectory()
        XCTAssertThrowsError(try NivoCloudMessageBody.read(inline: "[]", assetURL: root.appendingPathComponent("missing.json")))
        XCTAssertThrowsError(try NivoCloudMessageBody.read(inline: "[]", assetURL: root))
        let file = root.appendingPathComponent("invalid.json")
        try Data([0xC3, 0x28]).write(to: file)
        XCTAssertThrowsError(try NivoCloudMessageBody.read(inline: "[]", assetURL: file))
    }

    func testOversizedInlineAndAssetAreRejected() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("large.json")
        let bytes = Data(repeating: 0x20, count: NivoCloudMessageBody.MAX_BODY_BYTES + 1)
        try bytes.write(to: file)
        XCTAssertThrowsError(try NivoCloudMessageBody.read(inline: nil, assetURL: file))
        XCTAssertThrowsError(try NivoCloudMessageBody.read(inline: String(decoding: bytes, as: UTF8.self), assetURL: nil))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}
