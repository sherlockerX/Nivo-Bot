import Foundation

/// 仅适配配置CLI的JSON出口，不改变Swift调用方使用的原始桥接信封。
enum NivoConfigCLIResponse {
    /// quiet解开读取值或数据载荷；普通输出保留原有字段和编码层级。
    static func format(_ envelope: [String: Any], compact: Bool, quiet: Bool) -> String {
        do {
            let output: Any
            if quiet { output = try quietValue(envelope) }
            else { output = envelope }
            // 包成数组验证JSON片段，避免无效Foundation对象触发Objective-C异常。
            guard JSONSerialization.isValidJSONObject([output]) else {
                return serializationFailure(quiet: quiet)
            }
            var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
            if !compact { options.insert(.prettyPrinted) }
            let data = try JSONSerialization.data(withJSONObject: output, options: options)
            return String(decoding: data, as: UTF8.self)
        } catch {
            return serializationFailure(quiet: quiet)
        }
    }

    private static func quietValue(_ envelope: [String: Any]) throws -> Any {
        guard (envelope["ok"] as? Bool) == true else { return quietError(envelope) }
        if let data = envelope["data"] { return data }
        if let encodedValue = envelope["value"] as? String {
            return try JSONSerialization.jsonObject(with: Data(encodedValue.utf8), options: [.fragmentsAllowed])
        }
        // 写入和审计响应可能没有data，仍保留回执与可供用户操作的提示。
        return envelope
    }

    private static func quietError(_ envelope: [String: Any]) -> [String: Any] {
        if let details = envelope["error"] as? [String: Any] { return details }
        let code = envelope["error"] as? String ?? "unknown_error"
        var result: [String: Any] = [
            "code": code,
            "message": envelope["reason"] as? String
                ?? envelope["message"] as? String
                ?? envelope["user_message"] as? String
                ?? code,
        ]
        if let guidance = envelope["user_message"] as? String { result["user_message"] = guidance }
        return result
    }

    private static func serializationFailure(quiet: Bool) -> String {
        let error = "{\"code\":\"json_serialization_failed\",\"message\":\"Config CLI response could not be encoded.\"}"
        return quiet ? error : "{\"ok\":false,\"error\":\(error)}"
    }
}
