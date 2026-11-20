import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// JSON工具输入严格解码，错误类型不降级为默认参数。
enum NivoLifeToolInput {
    /// 每种动作只接受自身适用字段，避免签名丢弃参数后把不同请求当成相同重试。
    static func requireFields(_ values: [String: Any], allowed: Set<String>) throws {
        guard Set(values.keys).isSubset(of: allowed) else { throw NivoLifeError.invalidField("unexpected_fields") }
    }

    /// 整数参数拒绝Bool、小数、字符串和溢出值。
    static func integer(_ values: [String: Any], _ key: String, default fallback: Int64? = nil) throws -> Int64? {
        guard let raw = values[key] else { return fallback }
        guard let number = raw as? NSNumber, try !isBoolean(number),
              let result = Int64(number.stringValue) else { throw NivoLifeError.invalidField(key) }
        return result
    }

    /// 字符串缺席才采用默认值，显式null和其他类型均返回错误。
    static func text(_ values: [String: Any], _ key: String, default fallback: String? = nil) throws -> String {
        guard let value = values[key] else {
            guard let fallback else { throw NivoLifeError.invalidField(key) }
            return fallback
        }
        guard let text = value as? String else { throw NivoLifeError.invalidField(key) }
        return text
    }

    /// 日期使用固定公历与POSIX语言环境，避免设备语言影响数字解析。
    static func day(_ value: Any?) throws -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = value as? String,
              raw.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
            throw NivoLifeError.invalidField("date")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else { throw NivoLifeError.invalidField("date") }
        return NivoLifeDay.value(date, timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    /// 编辑负载只接受公开字段，禁止直接赋值状态、完成证据或内部版本。
    static func patch(_ values: [String: Any]) throws -> NivoTodoToolPatch {
        let raw = try text(values, "payload", default: "{}")
        guard raw.utf8.count <= 64_000,
              let payload = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw NivoLifeError.invalidField("payload")
        }
        let allowed = Set(["title", "notes", "groupName", "tags", "isImportant", "isUrgent", "scheduledDate", "dueDate"])
        guard Set(payload.keys).isSubset(of: allowed) else { throw NivoLifeError.invalidField("payload_fields") }
        var patch = NivoTodoToolPatch()
        if payload["title"] != nil { patch.title = try text(payload, "title") }
        if payload["notes"] != nil { patch.notes = try text(payload, "notes") }
        if payload["groupName"] != nil { patch.groupName = try text(payload, "groupName") }
        if let value = payload["tags"] {
            guard let tags = value as? [String] else { throw NivoLifeError.invalidField("tags") }
            patch.tags = tags
        }
        patch.isImportant = try boolean(payload, "isImportant")
        patch.isUrgent = try boolean(payload, "isUrgent")
        patch.scheduledDay = try day(payload["scheduledDate"])
        patch.dueDay = try day(payload["dueDate"])
        patch.clearsScheduledDay = payload["scheduledDate"] is NSNull
        patch.clearsDueDay = payload["dueDate"] is NSNull
        return patch
    }

    private static func boolean(_ values: [String: Any], _ key: String) throws -> Bool? {
        guard let raw = values[key] else { return nil }
        guard let number = raw as? NSNumber, try isBoolean(number) else {
            throw NivoLifeError.invalidField(key)
        }
        return number.boolValue
    }

    /// Apple平台沿用真实CF类型；便携Foundation以JSON原始类型区分布尔值和0/1。
    private static func isBoolean(_ number: NSNumber) throws -> Bool {
        #if canImport(CoreFoundation)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        let data = try JSONSerialization.data(withJSONObject: number, options: .fragmentsAllowed)
        return data == Data("true".utf8) || data == Data("false".utf8)
        #endif
    }
}

/// 模型工具与CLI共用可恢复错误协议，不输出Swift枚举序号或私有存储路径。
enum NivoLifeToolFailure {
    /// 失败始终显式标记，调用方不能把授权拒绝或磁盘故障当作空记录。
    static func output(_ error: Error) -> String {
        var value = details(error)
        // Coach和Life旧调用方读取code，保留同值别名以兼容已有冲突恢复逻辑。
        value["code"] = value["error"]
        value["success"] = false
        value["dataAvailable"] = false
        let fallback = "{\"success\":false,\"error\":\"records_unavailable\",\"code\":\"records_unavailable\",\"dataAvailable\":false}"
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return fallback }
        return String(decoding: data, as: UTF8.self)
    }

    private static func details(_ error: Error) -> [String: Any] {
        if let access = error as? NivoPersonalRecordsAccessError {
            return ["error": access.rawValue, "message": access.localizedDescription, "requiresNewUserTurn": true]
        }
        if let execution = error as? NivoJigsawExecutionError {
            return ["error": execution.rawValue, "message": execution.localizedDescription]
        }
        if let execution = error as? NivoScheduledExecutionError {
            return ["error": execution.rawValue, "message": execution.localizedDescription]
        }
        if let life = error as? NivoLifeError { return lifeDetails(life) }
        if let query = error as? NivoJigsawQuery.QueryError {
            return ["error": "invalid_query", "message": query.message, "requiresNewUserTurn": false]
        }
        if error is CancellationError {
            return ["error": "cancelled", "message": "The request was cancelled.", "requiresNewUserTurn": true]
        }
        return ["error": "records_unavailable", "message": "Saved records could not be read. Open the records page to check its status before retrying.", "requiresNewUserTurn": false]
    }

    private static func lifeDetails(_ error: NivoLifeError) -> [String: Any] {
        switch error {
        case .invalidField(let field):
            if ["id_required", "expected_revision_required"].contains(field) {
                let option = field == "id_required" ? "--id" : "--expected-revision"
                return ["error": "invalid_args", "argument": option,
                    "message": "Missing or invalid \(option). Run minis-scheduled --help for the required arguments."]
            }
            var result: [String: Any] = ["error": "invalid_field", "message": "Check the tool's documented fields and JSON value types."]
            if field.range(of: "^[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil { result["field"] = field }
            return result
        case .accountChanged:
            return ["error": "account_changed", "message": "The account or saved-data scope changed. Return to the conversation and send a new request.", "requiresNewUserTurn": true]
        case .staleRevision(let expected, let actual):
            return ["error": "stale_revision", "message": "Query the latest item before a new operation.", "expectedRevision": expected, "actualRevision": actual]
        case .notFound:
            return ["error": "not_found", "message": "The saved item no longer exists. Query the list again."]
        case .operationConflict:
            return ["error": "operation_conflict", "message": "This operation ID was already used for different content."]
        case .activeSessionExists:
            return ["error": "active_session_exists", "message": "Finish the current focus session first."]
        case .invalidTransition:
            return ["error": "invalid_transition", "message": "This action does not apply to the saved state. Query the current item before retrying."]
        case .unsupportedVersion:
            return ["error": "unsupported_version", "message": "The saved records use an unsupported version. The original file was preserved."]
        case .corruptStore:
            return ["error": "corrupt_store", "message": "Saved records could not be decoded. The original file was preserved."]
        }
    }
}
