import Foundation

/// 会话桥接中的执行结果只包装一次，失败不能在最外层变成成功。
enum NivoSessionResponse {
    /// 兼容现有status内层包装及send、retry、open的扁平桥接返回值。
    static func envelope(action: String, payload: [String: Any], timestamp: String) -> [String: Any] {
        let isSuccess = (payload["ok"] as? Bool) != false
        var output: [String: Any] = ["ok": isSuccess, "tool": "minis-sessions-cli",
            "action": action, "timestamp": timestamp]
        if !isSuccess {
            output["error"] = failure(payload["error"])
            return output
        }
        var data = payload
        if payload["action"] as? String == action, let nested = payload["data"] as? [String: Any] {
            data = nested
        }
        data.removeValue(forKey: "ok")
        data.removeValue(forKey: "action")
        output["data"] = data
        return output
    }

    /// 语法错误由CLI解析器返回2，实际桥接操作失败返回1。
    static func exitCode(_ payload: [String: Any]) -> Int32 {
        (payload["ok"] as? Bool) == false ? 1 : 0
    }

    private static func failure(_ value: Any?) -> [String: Any] {
        if let structured = value as? [String: Any] { return structured }
        let code = value as? String ?? "session_operation_failed"
        return ["code": code, "message": code]
    }
}

#if canImport(ObjectiveC)
/// 原生CLI只负责输出，共享值逻辑决定协议形状与退出码。
@objc(NivoSessionOffloadResponse)
final class NivoSessionOffloadResponse: NSObject {
    /// 给现有Objective-C调用点提供唯一成功或失败包装。
    @objc(envelopeForAction:payload:)
    static func envelope(action: String, payload: [String: Any]) -> [String: Any] {
        NivoSessionResponse.envelope(action: action, payload: payload,
            timestamp: ISO8601DateFormatter().string(from: Date()))
    }

    /// 与JSON的ok字段保持一致，失败可由shell管道直接检查。
    @objc(exitCodeForPayload:)
    static func exitCode(payload: [String: Any]) -> Int32 {
        NivoSessionResponse.exitCode(payload)
    }
}
#endif
