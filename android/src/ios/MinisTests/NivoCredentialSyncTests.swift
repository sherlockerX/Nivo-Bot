import XCTest
@testable import Minis

/// 只使用虚构值，验证完整解码、旧版兼容和乱序同步的版本语义。
final class NivoCredentialSyncTests: XCTestCase {
    func testMalformedPayloadAndMalformedMemberDoNotBecomeSuccess() throws {
        for json in ["{", "{}", "[{}]", "[" + entryJSON() + ",{}]"] {
            XCTAssertThrowsError(try NivoCredentialSync.providers(json))
        }
    }

    func testDuplicateOrEmptyOwnersAndInvalidBase64AreRejected() throws {
        let encoded = Data("fixture-only".utf8).base64EncodedString()
        for json in [
            "[" + entryJSON(owner: "") + "]",
            "[" + entryJSON().replacingOccurrences(of: encoded, with: "!invalid") + "]",
            "[" + entryJSON() + "," + entryJSON() + "]"
        ] { XCTAssertThrowsError(try NivoCredentialSync.providers(json)) }
    }

    func testInvalidTimestampIsNotDowngradedToLegacy() throws {
        for timestamp in ["true", #""NaN""#, #""not-time""#, "{}"] {
            let json = "[" + entryJSON(timestamp: timestamp) + "]"
            XCTAssertThrowsError(try NivoCredentialSync.providers(json))
        }
    }

    func testLegacyAndNumericStringVersionsRemainCompatible() throws {
        let legacy = try NivoCredentialSync.providers("[" + entryJSON() + "]")
        XCTAssertEqual(legacy.count, 1)
        XCTAssertNil(legacy.first?.updatedAt)
        let versioned = try NivoCredentialSync.providers("[" + entryJSON(timestamp: #""20.5""#) + "]")
        XCTAssertEqual(versioned.first?.updatedAt, date(20.5))
    }

    private func entryJSON(owner: String = "fixture-a", timestamp: String? = nil) -> String {
        let value = Data("fixture-only".utf8).base64EncodedString()
        let version = timestamp.map { ",\"updatedAt\":\($0)" } ?? ""
        return "{\"instanceId\":\"\(owner)\",\"apiKey\":\"\(value)\"\(version)}"
    }

    func testIdenticalNewerValueAdvancesVersionBeforeAnOlderDifferentValue() throws {
        let same = NivoCredentialSync.Entry(owner: "fixture-a", value: Data("same".utf8), updatedAt: date(30))
        let result = NivoCredentialSync.decision(local: same.value, localUpdatedAt: date(10), remote: same, now: date(40))
        XCTAssertEqual(result, .write(date(30)))
        let older = NivoCredentialSync.Entry(owner: "fixture-a", value: Data("older".utf8), updatedAt: date(20))
        XCTAssertEqual(NivoCredentialSync.decision(local: same.value, localUpdatedAt: date(30), remote: older, now: date(40)), .keep)
    }

    func testLegacyDoesNotOverwriteExistingAndMissingReceivesRemoteVersion() {
        let remote = NivoCredentialSync.Entry(owner: "fixture-a", value: Data("fixture".utf8), updatedAt: nil)
        XCTAssertEqual(NivoCredentialSync.decision(local: Data("local".utf8), localUpdatedAt: date(10), remote: remote, now: date(40)), .keep)
        XCTAssertEqual(NivoCredentialSync.decision(local: nil, localUpdatedAt: date(10), remote: remote, now: date(40)), .write(date(40)))
    }

    func testEnvironmentPayloadValidatesWholeBatchAndKeepsLegacyShape() throws {
        let encoded = Data("fixture-only".utf8).base64EncodedString()
        let valid = "[{\"key\":\"FIXTURE_NAME\",\"value\":\"\(encoded)\"}]"
        let entries = try NivoCredentialSync.environments(valid)
        XCTAssertEqual(entries.first?.owner, "FIXTURE_NAME")
        XCTAssertNil(entries.first?.updatedAt)
        for invalid in ["[{}]", valid.replacingOccurrences(of: "FIXTURE_NAME", with: "9INVALID"),
                        valid.replacingOccurrences(of: encoded, with: "!invalid"), "{}"] {
            XCTAssertThrowsError(try NivoCredentialSync.environments(invalid))
        }
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
}
