import XCTest
import Darwin
@testable import Minis

/// 只在Apple应用测试目标运行POSIX实际文件用例，Windows核心包不计入这些结果。
final class NivoScheduledScriptFilesTests: XCTestCase {
    private func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        return home
    }

    func testReadsFrozenRegularFileAtSizeBoundary() throws {
        let home = try home()
        let file = home.appendingPathComponent("bin/check.sh")
        let original = Data(repeating: 32, count: 65_536)
        try original.write(to: file)
        let frozen = try NivoScheduledScriptFiles.read(script: NivoRoutineScript(id: "check.sh"), home: home)
        try Data("exit 1".utf8).write(to: file)
        XCTAssertEqual(Data(frozen.body.utf8), original)
        try Data(repeating: 32, count: 65_537).write(to: file)
        XCTAssertThrowsError(try NivoScheduledScriptFiles.read(script: NivoRoutineScript(id: "check.sh"), home: home))
    }

    func testRejectsSymbolicLinkDirectoryAndPipeWithoutBlocking() throws {
        let home = try home()
        let original = home.appendingPathComponent("original")
        try Data("echo text".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("bin/link.sh"), withDestinationURL: original)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin/directory.sh"), withIntermediateDirectories: false)
        XCTAssertEqual(mkfifo(home.appendingPathComponent("bin/pipe.sh").path, 0o600), 0)
        for name in ["link.sh", "directory.sh", "pipe.sh"] {
            XCTAssertThrowsError(try NivoScheduledScriptFiles.read(script: NivoRoutineScript(id: name), home: home), name)
        }
    }

    func testRejectsLinkedBinDirectoryAndBinaryContents() throws {
        let home = try home()
        let file = home.appendingPathComponent("bin/check.py")
        try Data([0xff, 0xfe]).write(to: file)
        XCTAssertThrowsError(try NivoScheduledScriptFiles.read(script: NivoRoutineScript(id: "check.py"), home: home))
        let linked = home.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("bin"), withDestinationURL: home.appendingPathComponent("bin"))
        XCTAssertThrowsError(try NivoScheduledScriptFiles.read(script: NivoRoutineScript(id: "check.py"), home: linked))
    }
}
