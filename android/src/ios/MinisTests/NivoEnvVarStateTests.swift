import XCTest
@testable import Minis

/// 真实文件与生产合并规则回归；不模拟Keychain来宣称系统集成通过。
final class NivoEnvVarStateTests: XCTestCase {
    func testMalformedSecretIsRejectedWhileMissingLegacyValueIsPreserved() throws {
        XCTAssertNil(try NivoEnvVarState.decodeValue(nil))
        XCTAssertNil(try NivoEnvVarState.decodeValue(""))
        XCTAssertEqual(try NivoEnvVarState.decodeValue(Data("fixture-only".utf8).base64EncodedString()), "fixture-only")
        XCTAssertThrowsError(try NivoEnvVarState.decodeValue("!invalid"))
        XCTAssertThrowsError(try NivoEnvVarState.decodeValue(Data([0xFF]).base64EncodedString()))
    }

    func testOlderAndDuplicateRemoteVersionsDoNotReplaceNewerLocalValue() {
        let local = EnvVarEntry(id: "fixture", key: "FIXTURE", createdAt: date(1), updatedAt: date(30))
        XCTAssertFalse(NivoEnvVarState.accepts(remote: date(20), local: local))
        XCTAssertFalse(NivoEnvVarState.accepts(remote: date(30), local: local))
        XCTAssertTrue(NivoEnvVarState.accepts(remote: date(40), local: local))
        XCTAssertTrue(NivoEnvVarState.accepts(remote: date(1), local: nil))
    }

    func testLocalVersionAdvancesAfterClockRollback() throws {
        XCTAssertGreaterThan(try NivoEnvVarState.nextVersion(after: date(30), now: date(10)), date(30))
    }

    func testRenamePreservesOriginalCreationAndRejectsSharedKeyCollision() throws {
        let local = EnvVarEntry(id: "fixture", key: "OLD_NAME", createdAt: date(1), updatedAt: date(20))
        let renamed = EnvVarEntry(id: "fixture", key: "NEW_NAME", createdAt: date(5), updatedAt: date(30))
        let merged = try XCTUnwrap(NivoEnvVarState.merging(renamed, into: [local]))
        XCTAssertEqual(merged.first?.createdAt, date(1))
        XCTAssertEqual(merged.first?.key, "NEW_NAME")
        XCTAssertEqual(merged.first?.version, date(30))
        XCTAssertNil(try NivoEnvVarState.merging(local, into: merged))
        let other = EnvVarEntry(id: "other", key: "NEW_NAME", createdAt: date(1))
        XCTAssertThrowsError(try NivoEnvVarState.merging(renamed, into: [local, other]))
    }

    func testInvalidNamesDuplicateIdentifiersAndInvalidDatesAreRejected() {
        let valid = EnvVarEntry(id: "fixture", key: "FIXTURE", createdAt: date(1))
        XCTAssertNoThrow(try NivoEnvVarState.validate([valid]))
        for entries in [[valid, valid], [EnvVarEntry(id: "", key: "FIXTURE")],
                        [EnvVarEntry(key: "9INVALID")], [EnvVarEntry(key: "A\0B")],
                        [EnvVarEntry(key: "FIXTURE", updatedAt: Date(timeIntervalSince1970: .infinity))]] {
            XCTAssertThrowsError(try NivoEnvVarState.validate(entries))
        }
    }

    /// 不同身份使用同一名称会共享一个Keychain槽，读取时必须拒绝歧义档案。
    func testDuplicateNamesAreRejectedBeforeReadingCredentials() throws {
        let url = try file()
        let entries = [EnvVarEntry(id: "first", key: "FIXTURE"), EnvVarEntry(id: "second", key: "FIXTURE")]
        let original = try JSONEncoder().encode(entries)
        try original.write(to: url)
        XCTAssertThrowsError(try NivoEnvVarState.read(url))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testCorruptMetadataIsPreservedAndDoesNotBecomeEmpty() throws {
        let url = try file()
        let data = Data("{broken".utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try NivoEnvVarState.read(url))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testFailedWriteThrowsAndLeavesPreviousMetadata() throws {
        let url = try file()
        let saved = [EnvVarEntry(id: "fixture", key: "FIXTURE", createdAt: date(1))]
        try NivoEnvVarState.save(saved, to: url)
        XCTAssertThrowsError(try NivoEnvVarState.save([], to: url.appendingPathComponent("unavailable")))
        XCTAssertEqual(try NivoEnvVarState.read(url), saved)
    }

    func testOldMetadataLoadsAndNewVersionSurvivesReload() throws {
        let url = try file()
        try Data(#"[{"id":"fixture","key":"FIXTURE","createdAt":0}]"#.utf8).write(to: url)
        var entries = try NivoEnvVarState.read(url)
        XCTAssertNil(entries.first?.updatedAt)
        XCTAssertEqual(entries.first?.note, "")
        entries[0].updatedAt = date(30)
        try NivoEnvVarState.save(entries, to: url)
        XCTAssertEqual(try NivoEnvVarState.read(url), entries)
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    private func file() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("metadata.json")
    }
}
