import XCTest
@testable import Minis

/// 衣柜测试只用合成字节模拟文件，不生成图片，也不读取正式形象。
final class NivoAvatarWardrobeTests: XCTestCase {
    private func fixture() throws -> NivoAvatarWardrobeFiles {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return NivoAvatarWardrobeFiles(root: root)
    }

    func testSwitchKeepsPosesMotionAndUserUploadedClip() throws {
        let files = try fixture()
        let original = ["idle.png": Data([1]), "happy.png": Data([2]), "motion/idle.mp4": Data([3])]
        try files.replace(with: original)
        let own = files.root.appendingPathComponent("own-clip.mp4")
        try Data([9]).write(to: own)
        try files.replace(with: ["idle.png": Data([4])])
        let archived = try XCTUnwrap(files.list().first)
        try files.wear(archived.id)
        for (name, bytes) in original { XCTAssertEqual(try Data(contentsOf: files.root.appendingPathComponent(name)), bytes) }
        XCTAssertEqual(try Data(contentsOf: own), Data([9]))
        try files.wear("dragon")
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.root.appendingPathComponent("idle.png").path))
        XCTAssertEqual(try files.list().count, 2)
        XCTAssertEqual(try Data(contentsOf: own), Data([9]))
    }

    func testPartialSwitchRecoversOriginalFiles() throws {
        let files = try fixture()
        let rollback = files.root.appendingPathComponent(".wardrobe-rollback")
        try FileManager.default.createDirectory(at: rollback, withIntermediateDirectories: true)
        try Data([1]).write(to: rollback.appendingPathComponent("idle.png"))
        try Data([2]).write(to: files.root.appendingPathComponent("happy.png"))
        try files.recover()
        XCTAssertEqual(try Data(contentsOf: files.root.appendingPathComponent("idle.png")), Data([1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.root.appendingPathComponent("happy.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollback.path))
    }

    func testMalformedIdentifierCannotEscapeWardrobe() throws {
        let files = try fixture()
        XCTAssertThrowsError(try files.remove("../outside"))
        XCTAssertThrowsError(try files.wear("../outside"))
        XCTAssertThrowsError(try files.replace(with: ["../outside": Data([1])]))
    }

    func testFailedInstallPreservesCurrentAndRecoveryCopy() throws {
        let files = try fixture()
        try files.replace(with: ["idle.png": Data([1])])
        // 目的motion是普通文件，制造安装片段目录失败。
        try Data([8]).write(to: files.root.appendingPathComponent("motion"))
        XCTAssertThrowsError(try files.replace(with: ["idle.png": Data([2]), "motion/idle.mp4": Data([3])]))
        XCTAssertEqual(try Data(contentsOf: files.root.appendingPathComponent("idle.png")), Data([1]))
        XCTAssertEqual(try files.list().count, 1)
    }
}
