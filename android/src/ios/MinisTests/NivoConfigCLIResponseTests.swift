import XCTest
@testable import Minis

/// 配置CLI输出使用真实生产适配器，覆盖JSON片段和原信封兼容性。
final class NivoConfigCLIResponseTests: XCTestCase {
    func testQuietNullIsJSONNullInsteadOfEmptyObject() throws {
        let output = NivoConfigCLIResponse.format(["ok": true, "value": "null"], compact: true, quiet: true)
        XCTAssertEqual(output, "null")
        XCTAssertTrue(try decode(output) is NSNull)
    }

    func testQuietStringIsDecodedExactlyOnceAndKeepsEscapes() throws {
        let value = "第一行\n\"quoted\"\\path"
        let encoded = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        let output = NivoConfigCLIResponse.format(
            ["ok": true, "value": String(decoding: encoded, as: UTF8.self)], compact: true, quiet: true)
        XCTAssertEqual(try decode(output) as? String, value)
    }

    func testQuietNumberAndBooleanRemainJSONScalars() throws {
        for raw in ["0", "128000", "-1", "1.5", "true", "false"] {
            for compact in [true, false] {
                let output = NivoConfigCLIResponse.format(["ok": true, "value": raw], compact: compact, quiet: true)
                XCTAssertEqual(try decode(output) as? NSNumber, try decode(raw) as? NSNumber)
                XCTAssertFalse(output.hasPrefix("\""))
            }
        }
    }

    func testQuietArrayPreservesNestedObjectsAndNulls() throws {
        let raw = "[{\"id\":\"provider/model.v1\",\"enabled\":true},null,3]"
        let output = NivoConfigCLIResponse.format(["ok": true, "value": raw], compact: false, quiet: true)
        XCTAssertEqual(try decode(output) as? NSArray, try decode(raw) as? NSArray)
    }

    func testQuietObjectAndEmptyArrayRemainTheirOriginalTypes() throws {
        for raw in ["[]", "{}", "{\"contextWindow\":128000}"] {
            let output = NivoConfigCLIResponse.format(["ok": true, "value": raw], compact: true, quiet: true)
            XCTAssertEqual(output, raw)
        }
    }

    func testQuietNativeDataEnvelopeKeepsDiscoveryPayload() throws {
        let data: [String: Any] = ["topic": "models", "fields": [["path": "models.provider/model.v1.contextWindow"]]]
        let output = NivoConfigCLIResponse.format(
            ["ok": true, "tool": "minis-config", "action": "topic-help", "data": data], compact: true, quiet: true)
        XCTAssertEqual(try decode(output) as? NSDictionary, data as NSDictionary)
    }

    func testQuietNativeDataMayAlsoBeNullOrScalar() throws {
        let values: [Any] = [NSNull(), true, 7, "hello"]
        for value in values {
            let output = NivoConfigCLIResponse.format(["ok": true, "data": value], compact: true, quiet: true)
            let expected = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            XCTAssertEqual(try decode(output) as? NSObject,
                           try JSONSerialization.jsonObject(with: expected, options: [.fragmentsAllowed]) as? NSObject)
        }
    }

    func testQuietSwiftErrorBecomesCodeAndMessage() throws {
        let output = NivoConfigCLIResponse.format(
            ["ok": false, "error": "invalid_args", "reason": "--page must be a positive integer."],
            compact: true, quiet: true)
        XCTAssertEqual(try decode(output) as? NSDictionary,
            ["code": "invalid_args", "message": "--page must be a positive integer."] as NSDictionary)
    }

    func testQuietPermissionErrorRetainsUserGuidance() throws {
        let output = NivoConfigCLIResponse.format(
            ["ok": false, "error": "permission_denied", "reason": "Disabled.", "user_message": "Open Permissions."],
            compact: true, quiet: true)
        let decoded = try XCTUnwrap(try decode(output) as? [String: Any])
        XCTAssertEqual(decoded["code"] as? String, "permission_denied")
        XCTAssertEqual(decoded["message"] as? String, "Disabled.")
        XCTAssertEqual(decoded["user_message"] as? String, "Open Permissions.")
    }

    func testQuietNativeErrorObjectIsUnchanged() throws {
        let error = ["code": "invalid_args", "message": "Missing path."]
        let output = NivoConfigCLIResponse.format(
            ["ok": false, "error": error, "tool": "minis-config"], compact: true, quiet: true)
        XCTAssertEqual(try decode(output) as? NSDictionary, error as NSDictionary)
    }

    func testNonQuietSuccessPreservesEncodedValueAndPagination() throws {
        let envelope: [String: Any] = ["ok": true, "value": "[1,2]", "schema": "array",
            "pagination": ["page": 1, "total": 2], "agent_hint": "Complete."]
        for compact in [false, true] {
            let output = NivoConfigCLIResponse.format(envelope, compact: compact, quiet: false)
            XCTAssertEqual(try decode(output) as? NSDictionary, envelope as NSDictionary)
        }
    }

    func testNonQuietErrorPreservesOriginalBridgeContract() throws {
        let errors: [Any] = ["unknown_path", ["code": "invalid_args", "message": "Missing path."]]
        for error in errors {
            let envelope: [String: Any] = ["ok": false, "error": error, "reason": "Original reason."]
            let output = NivoConfigCLIResponse.format(envelope, compact: true, quiet: false)
            XCTAssertEqual(try decode(output) as? NSDictionary, envelope as NSDictionary)
        }
    }

    func testQuietWriteReceiptIsNotLostWhenThereIsNoDataField() throws {
        let envelope: [String: Any] = ["ok": true, "applied": [["path": "appearance.theme", "new": "dark"]],
            "user_message": "Saved. Review Config Changes."]
        let output = NivoConfigCLIResponse.format(envelope, compact: true, quiet: true)
        XCTAssertEqual(try decode(output) as? NSDictionary, envelope as NSDictionary)
    }

    func testCompactOnlyChangesWhitespace() throws {
        let envelope: [String: Any] = ["ok": true, "data": ["first": 1, "second": [2, 3]]]
        let compact = NivoConfigCLIResponse.format(envelope, compact: true, quiet: false)
        let pretty = NivoConfigCLIResponse.format(envelope, compact: false, quiet: false)
        XCTAssertFalse(compact.contains("\n"))
        XCTAssertTrue(pretty.contains("\n"))
        XCTAssertEqual(try decode(compact) as? NSDictionary, try decode(pretty) as? NSDictionary)
    }

    func testMalformedEncodedValueProducesStructuredSerializationError() throws {
        let output = NivoConfigCLIResponse.format(["ok": true, "value": "not-json"], compact: true, quiet: true)
        let error = try XCTUnwrap(try decode(output) as? [String: String])
        XCTAssertEqual(error["code"], "json_serialization_failed")
        XCTAssertNotNil(error["message"])
    }

    func testInvalidFoundationValueIsRejectedBeforeJSONSerialization() throws {
        let output = NivoConfigCLIResponse.format(["ok": true, "data": Date()], compact: true, quiet: false)
        let envelope = try XCTUnwrap(try decode(output) as? [String: Any])
        XCTAssertEqual(envelope["ok"] as? Bool, false)
        XCTAssertEqual((envelope["error"] as? [String: String])?["code"], "json_serialization_failed")
    }

    private func decode(_ output: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(output.utf8), options: [.fragmentsAllowed])
    }
}
