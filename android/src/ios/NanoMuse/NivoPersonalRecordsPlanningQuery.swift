import Foundation

/// 直接读取账户当前的固定档案，不初始化目标界面、调度器或任何脚本环境。
enum NivoPersonalRecordsPlanningQuery {
    /// 与goals.json保存格式对应的只读值，未知字段不会被自动转交给模型。
    struct Goal: Decodable, Sendable {
        struct Step: Decodable, Sendable {
            let id: String
            let text: String
            let done: Bool
        }

        let id: String
        let title: String
        let why: String
        let category: String
        let checkEveryHours: Int
        let checkHour: Int
        let checkMinute: Int
        let steps: [Step]
        let progress: Int
        let status: String
        let sessionId: String?
        let routineId: String?
        let lastNote: String?
        let lastCheckedAt: Date?
        let createdAt: Date
        let updatedAt: Date
    }

    /// 每次查询重新读盘；只有文件确实不存在才返回空值，损坏、权限和类型错误原样上抛。
    static func readGoals(directory: URL) throws -> [Goal] {
        guard let data = try archiveData(directory.appendingPathComponent("goals.json")) else { return [] }
        let rows = try decoder().decode([Goal].self, from: data)
        guard Set(rows.map(\.id)).count == rows.count, rows.allSatisfy({ !$0.id.isEmpty }) else {
            throw NivoLifeError.invalidField("goal_ids")
        }
        return rows
    }

    /// 只读取已提交主档案，复用正式档案验证，不应用收据、不恢复运行、不写回文件。
    static func readRoutines(directory: URL) throws -> [NanoMuseRoutine] {
        guard let data = try archiveData(directory.appendingPathComponent("routines.json")) else { return [] }
        let rows = try decoder().decode([NanoMuseRoutine].self, from: data)
        try NivoRoutineArchive.validate(rows)
        return rows
    }

    /// 列表只给摘要，精确目标详情保留完整步骤、动机和最后保存的说明。
    static func goals(_ request: NivoPersonalRecordsRequest, rows: [Goal]) throws -> String {
        let data: [String: Any]
        if let target = request.targetID {
            guard let goal = rows.first(where: { $0.id == target }) else {
                throw NivoJigsawQuery.QueryError("Goal not found; query the list again.")
            }
            var detail = try goalSummary(goal)
            detail["why"] = goal.why
            detail["steps"] = goal.steps.map { ["id": $0.id, "text": $0.text, "done": $0.done] as [String: Any] }
            detail["lastNote"] = nullable(goal.lastNote)
            detail["lastCheckedAt"] = try timestamp(goal.lastCheckedAt)
            detail["sessionId"] = nullable(goal.sessionId)
            detail["routineId"] = nullable(goal.routineId)
            detail["checkEveryHours"] = goal.checkEveryHours
            detail["checkHour"] = goal.checkHour
            detail["checkMinute"] = goal.checkMinute
            data = detail
        } else {
            let ordered = rows.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
            data = try page(ordered, request: request, render: goalSummary)
        }
        return try NivoPersonalRecordsOutput.json(["success": true, "data": data,
            "evidenceStatus": "saved_snapshot_not_independent_completion_proof", "timestampUnit": "unix_milliseconds"])
    }

    /// 任务详情的limit和offset分页运行历史，保留原始提示词但不交付脚本或脚本输出正文。
    static func routines(_ request: NivoPersonalRecordsRequest, rows: [NanoMuseRoutine]) throws -> String {
        let data: [String: Any]
        if let target = request.targetID {
            guard let routine = rows.first(where: { $0.id == target }) else {
                throw NivoJigsawQuery.QueryError("Routine not found; query the list again.")
            }
            var detail = try routineSummary(routine)
            detail["prompt"] = routine.script == nil ? routine.prompt : ""
            detail["startDate"] = nullable(routine.schedule?.startDay.map(NivoJigsawQuery.date))
            detail["endDate"] = nullable(routine.schedule?.endDay.map(NivoJigsawQuery.date))
            // 旧历史可能没有运行ID；相同时间保留档案顺序，翻页不会随机重排。
            let ordered = routine.runs.enumerated().sorted {
                $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at > $1.element.at
            }.map(\.element)
            detail["runs"] = try page(ordered, request: request) { try run($0, isScript: routine.script != nil) }
            detail["historyScope"] = "retained_on_device"
            detail["historyRetentionLimit"] = 50
            detail["historySource"] = "committed_routines_archive"
            detail["unappliedSettlementReceiptsIncluded"] = false
            data = detail
        } else {
            let ordered = rows.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
            data = try page(ordered, request: request, render: routineSummary)
        }
        return try NivoPersonalRecordsOutput.json(["success": true, "data": data,
            "evidenceStatus": "saved_archive_not_reconciled", "timestampUnit": "unix_milliseconds",
            "dateSemantics": "saved_local_calendar_day"])
    }

    private static func goalSummary(_ goal: Goal) throws -> [String: Any] {
        ["id": goal.id, "title": goal.title, "category": goal.category, "status": goal.status,
         "progress": goal.progress, "createdAt": try timestamp(goal.createdAt), "updatedAt": try timestamp(goal.updatedAt)]
    }

    private static func routineSummary(_ row: NanoMuseRoutine) throws -> [String: Any] {
        ["id": row.id, "title": row.label, "enabled": row.enabled, "hidden": row.hidden,
         "goalId": nullable(row.goalId), "repeatMode": row.repeatMode.rawValue,
         "times": NivoRoutineScheduleRules.normalizedTimes(row).map(\.text),
         "customDays": (row.schedule?.customDays ?? []).sorted(),
         "intervalMinutes": nullable(row.schedule?.intervalMinutes), "intervalHours": nullable(row.intervalHours),
         "createdAt": try timestamp(row.createdAt), "lastFiredAt": try timestamp(row.lastFiredAt),
         "retainedRunCount": row.runs.count, "executionKind": row.script == nil ? "prompt" : "script"]
    }

    private static func run(_ row: NanoMuseRoutine.Run, isScript: Bool) throws -> [String: Any] {
        // 脚本可以已被编辑为提示词任务；只凭明确脚本证据隐藏正文，普通模型同样会保存self_report。
        let scriptContent = isScript || row.scriptDigest != nil || row.exitCode != nil || row.stdoutBytes != nil
            || row.resultSource == "script_stdout"
        return ["id": nullable(row.id), "at": try timestamp(row.at), "ok": row.ok,
                "sessionId": nullable(row.sessionId), "finishedAt": try timestamp(row.finishedAt),
                "durationSeconds": nullable(row.duration), "trigger": nullable(row.trigger),
                "status": nullable(row.status), "scheduledFor": try timestamp(row.scheduledFor),
                "resultTruncated": nullable(row.resultTruncated), "exitCode": nullable(row.exitCode),
                "isDebug": nullable(row.isDebug), "note": scriptContent ? NSNull() : nullable(row.note),
                "result": scriptContent ? NSNull() : nullable(row.result),
                "contentOmitted": scriptContent ? "script_execution_content" as Any : NSNull()]
    }

    private static func page<Value>(_ rows: [Value], request: NivoPersonalRecordsRequest,
                                    render: (Value) throws -> [String: Any]) rethrows -> [String: Any] {
        let items = try rows.dropFirst(request.offset).prefix(request.limit).map(render)
        let next = request.offset + items.count
        return ["items": items, "total": rows.count, "offset": request.offset, "limit": request.limit,
                "nextOffset": next < rows.count ? next as Any : NSNull(), "hasMore": next < rows.count,
                "status": rows.isEmpty ? "empty" : "ok"]
    }

    private static func nullable<Value>(_ value: Value?) -> Any { value.map { $0 as Any } ?? NSNull() }

    private static func timestamp(_ date: Date?) throws -> Any {
        guard let date else { return NSNull() }
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max) else {
            throw NivoLifeError.invalidField("record_timestamp")
        }
        return Int64(milliseconds)
    }

    private static func decoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }

    private static func archiveData(_ file: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(NivoRoutineArchive.maximumBytes) else {
            throw NivoLifeError.invalidField("personal_records_archive")
        }
        let data = try Data(contentsOf: file)
        guard data.count <= NivoRoutineArchive.maximumBytes else { throw NivoLifeError.invalidField("personal_records_archive_size") }
        return data
    }
}
