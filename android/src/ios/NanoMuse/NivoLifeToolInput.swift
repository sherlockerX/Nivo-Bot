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
