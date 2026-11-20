import XCTest
@testable import Minis

/// 使用真实桥接返回形状验证CLI的统一协议，不读取或创建个人会话。
final class NivoSessionResponseTests: XCTestCase {
    func testStatusHasExactlyOneDataEnvelope() throws {
        let payload: [String: Any] = ["ok": true, "action": "status",
            "data": ["session_id": "example", "is_running": true, "model_name": "Example"]]
        let output = NivoSessionResponse.envelope(action: "status", payload: payload, timestamp: "now")
        XCTAssertEqual(output["ok"] as? Bool, true)
        let data = try XCTUnwrap(output["data"] as? [String: Any])
        XCTAssertEqual(data["session_id"] as? String, "example")
        XCTAssertEqual(data["is_running"] as? Bool, true)
        XCTAssertNil(data["data"])
        XCTAssertNil(data["ok"])
        XCTAssertEqual(NivoSessionResponse.exitCode(payload), 0)
    }

    func testBridgeFailureIsNotWrappedAsSuccessfulData() throws {
        let payload: [String: Any] = ["ok": false, "error": "session_not_found", "session_id": "example"]
        let output = NivoSessionResponse.envelope(action: "status", payload: payload, timestamp: "now")
        XCTAssertEqual(output["ok"] as? Bool, false)
        XCTAssertNil(output["data"])
        let error = try XCTUnwrap(output["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "session_not_found")
        XCTAssertEqual(NivoSessionResponse.exitCode(payload), 1)
    }

    func testSendRetryAndOpenRetainDomainFields() throws {
        for action in ["send", "retry", "open"] {
            let payload: [String: Any] = ["ok": true, "action": action, "session_id": "example", "status": "Running"]
            let output = NivoSessionResponse.envelope(action: action, payload: payload, timestamp: "now")
            let data = try XCTUnwrap(output["data"] as? [String: Any])
            XCTAssertEqual(data["session_id"] as? String, "example")
            XCTAssertEqual(data["status"] as? String, "Running")
            XCTAssertNil(data["ok"])
            XCTAssertEqual(output["action"] as? String, action)
        }
    }

    func testStructuredBridgeErrorRetainsCodeAndMessage() throws {
        let payload: [String: Any] = ["ok": false, "error": ["code": "busy", "message": "Wait for the current request."]]
        let output = NivoSessionResponse.envelope(action: "retry", payload: payload, timestamp: "now")
        let error = try XCTUnwrap(output["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "busy")
        XCTAssertEqual(error["message"] as? String, "Wait for the current request.")
        XCTAssertEqual(NivoSessionResponse.exitCode(payload), 1)
    }
}
