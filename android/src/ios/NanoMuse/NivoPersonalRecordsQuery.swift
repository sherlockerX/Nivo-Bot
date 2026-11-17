import Foundation

/// 原生工具与便携测试共用严格的只读参数协议，不接受路径和写入动作。
struct NivoPersonalRecordsRequest: Sendable {
    static let kinds = ["catalog", "reflection_range", "reflections", "reflection_stats", "coach"]
    static let sections = ["overview", "courses", "topics", "sessions", "actions", "drafts"]
    let kind: String
    let section: String
    let targetID: String?
    let startDate: String?
    let endDate: String?
    let limit: Int
    let offset: Int

    /// 错误类型和不适用字段必须失败，不能静默退回默认查询。
    static func parse(_ args: [String: Any]) throws -> Self {
        try NivoLifeToolInput.requireFields(args, allowed: ["kind", "section", "targetId", "startDate", "endDate", "limit", "offset", "tool_title"])
        guard JSONSerialization.isValidJSONObject(args),
              try JSONSerialization.data(withJSONObject: args).count <= 20_000 else { throw invalid("Arguments are too large") }
        let kind = try NivoLifeToolInput.text(args, "kind", default: "catalog")
        let section = try NivoLifeToolInput.text(args, "section", default: "overview")
        guard kinds.contains(kind), sections.contains(section) else { throw invalid("Unknown record kind or section") }
        let target = try optionalText(args, "targetId")
        let start = try optionalText(args, "startDate")
        let end = try optionalText(args, "endDate")
        guard args["section"] == nil || kind == "coach", target == nil || kind == "coach",
              (start == nil && end == nil) || ["reflections", "reflection_stats"].contains(kind) else {
            throw invalid("A filter does not apply to this record kind")
        }
        if let target {
            guard section != "overview", target.range(of: "^[A-Za-z0-9_.:-]{1,160}$", options: .regularExpression) != nil else {
                throw invalid("Choose an exact ID and a Coach detail section")
            }
        }
        return Self(kind: kind, section: section, targetID: target, startDate: start, endDate: end,
            limit: try number(args, "limit", fallback: 20, range: 1...30),
            offset: try number(args, "offset", fallback: 0, range: 0...1_000_000))
    }

    /// 复用日记的完整日分页、日期上限和输出大小限制，不读取图片文件。
    func mosaicQuery(now: Date = Date(), timeZone: TimeZone = .current) throws -> NivoJigsawQuery {
        var arguments = [kind == "reflection_stats" ? "stats" : "list"]
        if let startDate { arguments += ["--start", startDate] }
        if let endDate { arguments += ["--end", endDate] }
        if kind != "reflection_stats" { arguments += ["--limit", String(limit), "--offset", String(offset)] }
        return try NivoJigsawQuery.parse(arguments, now: now, timeZone: timeZone)
    }

    private static func optionalText(_ args: [String: Any], _ key: String) throws -> String? {
        args[key] == nil ? nil : try NivoLifeToolInput.text(args, key)
    }

    private static func number(_ args: [String: Any], _ key: String, fallback: Int64,
                               range: ClosedRange<Int>) throws -> Int {
        guard let value = try NivoLifeToolInput.integer(args, key, default: fallback),
              value >= Int64(range.lowerBound), value <= Int64(range.upperBound) else { throw invalid("Invalid integer \(key)") }
        return Int(value)
    }

    private static func invalid(_ text: String) -> NivoJigsawQuery.QueryError { .init(text) }
}

/// 只序列化公开的记录字段；Coach命令回执、照片路径和凭证均不进入结果。
enum NivoPersonalRecordsOutput {
    /// 全部正文保持原样，超限要求缩小查询，不静默截断。
    static func json(_ value: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard data.count <= 2 * 1_024 * 1_024 else {
            throw NivoJigsawQuery.QueryError("Result is too large; reduce the limit or date range. No text was truncated.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 日期发现只访问已保存文本、心情和习惯状态，不把草稿或习惯计划视为经历。
    static func reflectionRange(_ state: NivoMosaicState, timeZone: TimeZone = .current) throws -> String {
        let days = state.entries.filter { $0.deletedAt == nil }.map(\.day)
            + state.days.filter { $0.mood != nil }.map(\.day) + (state.habitDays ?? []).map(\.day)
        return try json(["success": true, "data": ["firstDate": days.min().map { NivoJigsawQuery.date($0) as Any } ?? NSNull(),
            "lastDate": days.max().map { NivoJigsawQuery.date($0) as Any } ?? NSNull(),
            "status": days.isEmpty ? "empty" : "ok", "timezone": timeZone.identifier,
            "date_semantics": "saved_local_calendar_day"]])
    }

    /// Coach查询直接读取值快照，既不初始化课程，也不对账或改变进度。
    static func coach(_ request: NivoPersonalRecordsRequest, state: NivoCoachState) throws -> String {
        if request.section == "overview" {
            return try json(["success": true, "data": ["revision": state.revision,
                "courses": state.tracks.count, "topics": state.topics.count, "sessions": state.sessions.count,
                "actions": state.actions.count, "drafts": state.drafts.count,
                "evidenceStatus": "saved_snapshot_not_reconciled"]])
        }
        let page = try coachRows(request, state: state)
        let rows = page.items
        if let target = request.targetID {
            guard let row = rows.first(where: { $0["id"] as? String == target }) else {
                throw NivoJigsawQuery.QueryError("Coach object not found; query the list again.")
            }
            return try json(["success": true, "data": row, "revision": state.revision,
                "evidenceStatus": "saved_snapshot_not_reconciled"])
        }
        let selected = rows.map(summary)
        let next = request.offset + selected.count
        return try json(["success": true, "data": ["items": selected, "total": page.total,
            "offset": request.offset, "limit": request.limit, "hasMore": next < page.total,
            "nextOffset": next < page.total ? next as Any : NSNull(), "status": page.total == 0 ? "empty" : "ok",
            "evidenceStatus": "saved_snapshot_not_reconciled"], "revision": state.revision])
    }

    private static func coachRows(_ request: NivoPersonalRecordsRequest, state: NivoCoachState) throws -> (items: [[String: Any]], total: Int) {
        switch request.section {
        case "courses": return try select(state.tracks, request: request)
        case "topics": return try select(Array(state.topics.reversed()), request: request)
        case "sessions": return try select(Array(state.sessions.reversed()), request: request)
        case "actions": return try select(Array(state.actions.reversed()), request: request)
        case "drafts": return try select(Array(state.drafts.reversed()), request: request)
        default: throw NivoJigsawQuery.QueryError("Unknown Coach section")
        }
    }

    private static func select<Value: Encodable & Identifiable>(_ values: [Value], request: NivoPersonalRecordsRequest) throws -> (items: [[String: Any]], total: Int) where Value.ID == String {
        let selected: [Value]
        if let target = request.targetID { selected = values.first(where: { $0.id == target }).map { [$0] } ?? [] }
        else { selected = Array(values.dropFirst(request.offset).prefix(request.limit)) }
        guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as? [[String: Any]] else {
            throw NivoJigsawQuery.QueryError("Coach snapshot could not be decoded")
        }
        return (result, values.count)
    }

    private static func summary(_ row: [String: Any]) -> [String: Any] {
        let allowed: Set<String> = ["id", "title", "status", "revision", "courseId", "unitId", "topicId", "sessionId", "stage", "mode", "paused", "currentUnitId", "sourceStatus"]
        var result = row.filter { allowed.contains($0.key) }
        if let course = row["course"] as? [String: Any] { result["title"] = course["title"] }
        return result
    }
}
