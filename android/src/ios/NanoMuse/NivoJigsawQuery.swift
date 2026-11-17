import Foundation

/// 与安卓minis-jigsaw-cli兼容的只读日期查询，分页以完整自然日为单位。
struct NivoJigsawQuery: Sendable {
    var command: String
    var startDay: Int64
    var endDay: Int64
    var limit: Int
    var offset: Int
    var format: String
    var today: Int64
    var zoneID: String
    static let zone = TimeZone(identifier: "Asia/Shanghai")!
    var pageStart: Int64 { startDay + Int64(offset) }
    var pageEnd: Int64 { min(endDay, pageStart + Int64(limit) - 1) }
    var nextOffset: Int? { pageEnd < endDay ? Int(pageEnd - startDay + 1) : nil }

    /// 严格拒绝写命令、重复参数、错误日期和过大范围，读取正文不静默截断。
    static func parse(_ arguments: [String], now: Date = Date(), timeZone: TimeZone = zone) throws -> NivoJigsawQuery {
        guard let command = arguments.first, ["list", "get", "stats", "export"].contains(command) else {
            throw QueryError("Only list, get, stats and export are supported.")
        }
        let values = try options(Array(arguments.dropFirst()))
        let allowed: Set<String> = command == "get" ? ["date", "format"]
            : command == "stats" ? ["start", "end", "days", "format"] : ["start", "end", "days", "limit", "offset", "format"]
        guard Set(values.keys).isSubset(of: allowed) else { throw QueryError("Unsupported option. Output is stdout only.") }
        let format = values["format"] ?? "json"
        guard ["json", "md"].contains(format) else { throw QueryError("--format must be json or md.") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let today = try day(String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1))
        let end = command == "get" ? try day(required(values, "date")) : try values["end"].map(day) ?? today
        let days = try number(values, key: "days", fallback: 7, range: 1...366)
        let start = command == "get" ? end : try values["start"].map(day) ?? end - Int64(days - 1)
        guard start <= end, end - start < 366 else { throw QueryError("Read between 1 and 366 days, with start no later than end.") }
        let limit = try number(values, key: "limit", fallback: 31, range: 1...366)
        let offset = try number(values, key: "offset", fallback: 0, range: 0...365)
        guard Int64(offset) <= end - start else { throw QueryError("--offset must be smaller than the date range.") }
        return NivoJigsawQuery(command: command, startDay: start, endDay: end, limit: limit, offset: offset,
            format: format, today: today, zoneID: timeZone.identifier)
    }

    /// 日期只接受严格的四位公历年，回读校验防止2月30日被系统纠正。
    static func day(_ value: String) throws -> Int64 {
        guard value.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil else { throw QueryError("Dates must use YYYY-MM-DD.") }
        let formatter = dateFormatter()
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { throw QueryError("Invalid calendar date.") }
        let result = Int64((date.timeIntervalSince1970 / 86_400).rounded(.down))
        try NivoTodoRules.validateDay(result)
        return result
    }

    /// 仅用于日期标签，不根据设备时区重新解释已选日期。
    static func date(_ day: Int64) -> String {
        dateFormatter().string(from: Date(timeIntervalSince1970: Double(day) * 86_400))
    }

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    private static func options(_ arguments: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            guard token.hasPrefix("--") else { throw QueryError("Expected an option beginning with --.") }
            let pair = token.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let rawKey = pair.first, !rawKey.isEmpty else { throw QueryError("Expected an option name after --.") }
            let key = ["from": "start", "to": "end", "until": "end"][rawKey] ?? rawKey
            let value: String
            if pair.count == 2 { value = pair[1] }
            else {
                guard index < arguments.count else { throw QueryError("Option --\(key) needs a value.") }
                value = arguments[index]
                index += 1
            }
            guard !value.isEmpty, !value.hasPrefix("--"), result[key] == nil else { throw QueryError("Empty or repeated option --\(key).") }
            result[key] = value
        }
        return result
    }

    private static func required(_ values: [String: String], _ key: String) throws -> String {
        guard let value = values[key] else { throw QueryError("Missing --\(key).") }
        return value
    }

    private static func number(_ values: [String: String], key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = values[key] else { return fallback }
        guard let value = Int(raw), range.contains(value) else { throw QueryError("Invalid integer --\(key).") }
        return value
    }

    /// 参数错误保留具体修正方向供模型重试。
    struct QueryError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// 生成仅含用户文字、心情和习惯的只读输出，不序列化照片内容或路径。
enum NivoJigsawOutput {
    static func render(query: NivoJigsawQuery, state: NivoMosaicState, now: Date = Date()) throws -> String {
        let start = query.command == "stats" ? query.startDay : query.pageStart
        let end = query.command == "stats" ? query.endDay : query.pageEnd
        let entries = state.entries.filter { $0.deletedAt == nil && $0.day >= start && $0.day <= end }
            .sorted { ($0.day, $0.createdAt, $0.id) < ($1.day, $1.createdAt, $1.id) }
        guard entries.count <= 5_000 else { throw NivoJigsawQuery.QueryError("Too many records. Use a smaller range or limit; no text was truncated.") }
        guard query.command == "stats" || entries.reduce(0, { $0 + $1.text.utf16.count }) <= 500_000 else {
            throw NivoJigsawQuery.QueryError("Result is too large. Use a smaller range or limit; no text was truncated.")
        }
        var root: [String: Any] = ["timezone": query.zoneID, "date_semantics": "saved_local_calendar_day",
            "start": NivoJigsawQuery.date(query.startDay),
            "end": NivoJigsawQuery.date(query.endDay), "computed_at": ISO8601DateFormatter().string(from: now),
            "habits_configured": !state.habits.isEmpty, "view_url": "minis://views/mosaic"]
        root["queried"] = ["start": NivoJigsawQuery.date(start), "end": NivoJigsawQuery.date(end), "inclusive": true, "timezone": query.zoneID]
        // 每日数据由日期单独过滤，避免同一天跨页或正文被摘要截断。
        let grouped = Dictionary(grouping: entries, by: \.day)
        var outputDays: [[String: Any]] = []
        var habitCount = 0
        if query.command != "stats" {
            for day in start...end {
                let value = try dayJSON(day, entries: grouped[day] ?? [], state: state)
                habitCount += (value["habits"] as? [[String: Any]])?.count ?? 0
                guard habitCount <= 10_000 else { throw NivoJigsawQuery.QueryError("Too many habit records; use a smaller range.") }
                outputDays.append(value)
            }
        }
        let hasMarks = (state.habitDays ?? []).contains { $0.day >= start && $0.day <= end }
        let hasMood = state.days.contains { $0.day >= start && $0.day <= end && $0.mood != nil }
        let hasPlan = (start...end).contains { day in state.habits.contains { NivoMosaicRules.isPlanned($0, day: day) } }
        root["status"] = entries.isEmpty && !hasMarks && !hasMood && !hasPlan ? "empty" : "ok"
        if query.command == "stats" { root["stats"] = try stats(query: query, entries: entries, state: state) }
        else {
            root["days"] = outputDays
            root["offset"] = query.offset
            root["limit"] = query.limit
            root["has_more"] = query.nextOffset != nil
            root["next_offset"] = query.nextOffset.map { $0 as Any } ?? NSNull()
        }
        let output: String
        if query.format == "md" { output = markdown(root, days: outputDays) }
        else { output = String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) }
        guard output.utf8.count <= 2 * 1_024 * 1_024 else { throw NivoJigsawQuery.QueryError("Result is too large. Use a smaller range; no text was truncated.") }
        return output
    }

    private static func dayJSON(_ day: Int64, entries: [NivoMosaicEntry], state: NivoMosaicState) throws -> [String: Any] {
        let planned = state.habits.filter { NivoMosaicRules.isPlanned($0, day: day) }
        guard planned.count <= 10_000 else { throw NivoJigsawQuery.QueryError("Too many habit records; use a smaller range.") }
        let info = state.days.first { $0.day == day }
        let mood = info == nil ? entries.last?.mood : info?.mood
        let habits: [[String: Any]] = planned.map { habit in
            let mark = state.habitDays?.first { $0.day == day && $0.habitID == habit.id }
            return ["name": habit.title, "done": mark?.status == .done, "state": mark.map { $0.status.rawValue as Any } ?? NSNull()]
        }
        let records = entries.map(recordJSON)
        let text = entries.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        return ["date": NivoJigsawQuery.date(day), "text": text.isEmpty ? NSNull() : text as Any,
                "mood": mood.map { $0.rawValue as Any } ?? NSNull(),
                "mood_label": mood.map { ["great", "good", "okay", "low", "bad"][$0.rawValue - 1] as Any } ?? NSNull(),
                "energy": mood.map { (6 - $0.rawValue) as Any } ?? NSNull(),
                "habits_configured": !state.habits.isEmpty, "habits": habits, "records": records]
    }

    /// 关联只输出同账户仓库保存的语义快照，不读取照片路径、草稿或现有任务状态。
    private static func recordJSON(_ entry: NivoMosaicEntry) -> [String: Any] {
        var result: [String: Any] = ["id": entry.id, "text": entry.text,
            "mood": entry.mood.map { $0.rawValue as Any } ?? NSNull(),
            "energy": entry.mood.map { (6 - $0.rawValue) as Any } ?? NSNull(),
            "has_photo": entry.mediaPath != nil, "habit": entry.habitTitle.map { $0 as Any } ?? NSNull(),
            "created_at_ms": entry.createdAt, "updated_at_ms": entry.updatedAt]
        result["taskIDs"] = entry.taskIDs
        result["focusIDs"] = entry.focusIDs
        result["reflectionSessionID"] = entry.reflectionSessionID.map { $0 as Any } ?? NSNull()
        result["taskSnapshots"] = (entry.taskSnapshots ?? []).map {
            ["id": $0.id, "title": $0.title, "status": $0.status.rawValue,
             "linkedAt": $0.linkedAt.map { $0 as Any } ?? NSNull()] as [String: Any]
        }
        result["focusSnapshots"] = (entry.focusSnapshots ?? []).map {
            ["id": $0.id, "title": $0.title, "elapsedMs": $0.elapsedMs,
             "startedAt": $0.startedAt.map { $0 as Any } ?? NSNull(),
             "endedAt": $0.endedAt.map { $0 as Any } ?? NSNull()] as [String: Any]
        }
        result["linkEvidence"] = "saved_snapshot_not_current_completion_proof"
        return result
    }

    private static func stats(query: NivoJigsawQuery, entries: [NivoMosaicEntry], state: NivoMosaicState) throws -> [String: Any] {
        let count = Int(query.endDay - query.startDay + 1)
        let recorded = Set(entries.filter { $0.day <= query.today }.map(\.day)).count
        let future = (query.startDay...query.endDay).filter { $0 > query.today }.count
        let energy = entries.compactMap { $0.mood.map { 6 - $0.rawValue } }
        let done = Set((state.habitDays ?? []).filter { $0.status == .done }.map(\.id))
        var plannedCount = 0
        var doneCount = 0
        // 逐项累计而不是先构造全年习惯数组，输出较小时也不能产生无界中间分配。
        for day in query.startDay...query.endDay {
            for habit in state.habits where NivoMosaicRules.isPlanned(habit, day: day) {
                plannedCount += 1
                guard plannedCount <= 10_000 else { throw NivoJigsawQuery.QueryError("Too many habit records; use a smaller range.") }
                if done.contains("\(habit.id):\(day)") { doneCount += 1 }
            }
        }
        return ["days": count, "recorded_days": recorded, "missing_days": count - recorded - future,
                "future_days": future, "records": entries.count, "mood_records": energy.count,
                "average_energy": energy.isEmpty ? NSNull() : (Double(energy.reduce(0, +)) / Double(energy.count)) as Any,
                "habit_planned": plannedCount, "habit_done": doneCount]
    }

    private static func markdown(_ root: [String: Any], days: [[String: Any]]) -> String {
        var lines = ["# Mosaic \(root["start"] ?? "") to \(root["end"] ?? "")", "Timezone: \(root["timezone"] ?? "")"]
        if let stats = root["stats"] as? [String: Any] {
            lines += stats.keys.sorted().map { "- \($0): \(stats[$0] ?? "")" }
        } else {
            for day in days {
                lines += ["", "## \(day["date"] ?? "")", "Mood: \(day["mood_label"] ?? ""); energy: \(day["energy"] ?? "")"]
                for record in day["records"] as? [[String: Any]] ?? [] {
                    lines += markdownRecord(record)
                }
                for habit in day["habits"] as? [[String: Any]] ?? [] {
                    lines.append("- [\((habit["done"] as? Bool == true) ? "x" : " ")] \(habit["name"] ?? "") (\(habit["state"] ?? ""))")
                }
            }
            if root["has_more"] as? Bool == true { lines.append("More days: repeat with --offset \(root["next_offset"] ?? "").") }
        }
        return lines.joined(separator: "\n")
    }

    /// 每条心得保留自己的正文和关联，不能合并同日正文后丢失任务、时段对应关系。
    private static func markdownRecord(_ record: [String: Any]) -> [String] {
        var lines = ["", "### Record \(record["id"] ?? "")", record["text"] as? String ?? ""]
        let taskIDs = record["taskIDs"] as? [String] ?? []
        let focusIDs = record["focusIDs"] as? [String] ?? []
        lines += ["Task IDs: \(taskIDs.joined(separator: ", "))", "Focus IDs: \(focusIDs.joined(separator: ", "))"]
        if let source = record["reflectionSessionID"] as? String { lines.append("Reflection source: \(source)") }
        lines.append("Link evidence: saved_snapshot_not_current_completion_proof. Times below are Unix milliseconds; unknown means not recorded.")
        for task in record["taskSnapshots"] as? [[String: Any]] ?? [] {
            lines.append("- Saved task \(task["id"] ?? ""): \(task["title"] ?? ""); status=\(task["status"] ?? ""); linkedAt=\(recordedTime(task["linkedAt"]))")
        }
        for focus in record["focusSnapshots"] as? [[String: Any]] ?? [] {
            lines.append("- Saved focus \(focus["id"] ?? ""): \(focus["title"] ?? ""); elapsedMs=\(focus["elapsedMs"] ?? "unknown"); startedAt=\(recordedTime(focus["startedAt"])); endedAt=\(recordedTime(focus["endedAt"]))")
        }
        return lines
    }

    /// 旧快照没有时间字段时明确标为未知，不借用碎片创建时间补造。
    private static func recordedTime(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "unknown" }
        return String(describing: value)
    }
}
