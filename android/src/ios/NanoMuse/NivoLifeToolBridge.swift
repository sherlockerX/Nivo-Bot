import Foundation
import UIKit

/// 主聊天的待办与专注工具。写入仍由NivoLifeModel和串行仓库完成。
@MainActor
enum NivoLifeToolBridge {
    struct Result { var output: String; var success: Bool }
    static let todoQuery = "todo_query"
    static let todoCommand = "todo_command"
    static let focusQuery = "focus_query"
    static let focusCommand = "focus_command"

    static func definitions(includeCommands: Bool = true) -> [AgentToolDefinition] {
        let tools = [
            AgentToolDefinition(name: todoQuery, description: "Read tasks and reusable groups/tags in the current account. Query exact IDs and revisions before changes.", parameters: [
                "kind": AgentToolParam(type: .string, description: "tasks, detail or categories", enumValues: ["tasks", "detail", "categories"]),
                "targetId": AgentToolParam(type: .string, description: "Exact task ID for detail"),
                "status": AgentToolParam(type: .string, description: "Task status", enumValues: ["all", "todo", "in_progress", "done"]),
                "search": AgentToolParam(type: .string, description: "Search current task text, ID, group and tags"),
                "dateField": AgentToolParam(type: .string, description: "scheduled, due, completed or created", enumValues: ["scheduled", "due", "completed", "created"]),
                "startDate": AgentToolParam(type: .string, description: "Inclusive YYYY-MM-DD"), "endDate": AgentToolParam(type: .string, description: "Inclusive YYYY-MM-DD"),
                "limit": AgentToolParam(type: .integer, description: "1..50"), "offset": AgentToolParam(type: .integer, description: "Pagination offset")
            ], required: []),
            AgentToolDefinition(name: todoCommand, description: "Create or change a task only when explicitly requested. Completion requires an exact report from the current user message.", parameters: [
                "action": AgentToolParam(type: .string, description: "Requested action", enumValues: ["create", "update", "start", "complete", "reopen", "delete", "create_category", "delete_category"]),
                "operationId": AgentToolParam(type: .string, description: "Stable ID reused for exact retries"), "targetId": AgentToolParam(type: .string, description: "Exact task ID except create"), "expectedRevision": AgentToolParam(type: .integer, description: "Fresh task revision except create"),
                "payload": AgentToolParam(type: .string, description: "JSON object with title, notes, groupName, tags, isImportant, isUrgent, scheduledDate and dueDate. Dates use YYYY-MM-DD; null clears a date. Omitted fields are unchanged."), "userQuote": AgentToolParam(type: .string, description: "Exact current-user completion sentence"), "completedDate": AgentToolParam(type: .string, description: "Optional YYYY-MM-DD for complete only"),
                "categoryKind": AgentToolParam(type: .string, description: "group or tag", enumValues: ["group", "tag"]), "categoryName": AgentToolParam(type: .string, description: "Exact category name"), "expectedCreatedAt": AgentToolParam(type: .integer, description: "Fresh category generation")
            ], required: ["action", "operationId"]),
            AgentToolDefinition(name: focusQuery, description: "Read real focus timers and measured duration. Breaks and unfinished sessions are excluded from statistics.", parameters: [
                "kind": AgentToolParam(type: .string, description: "sessions, active, detail or statistics", enumValues: ["sessions", "active", "detail", "statistics"]), "targetId": AgentToolParam(type: .string, description: "Exact focus session ID"), "startDate": AgentToolParam(type: .string, description: "Statistics start YYYY-MM-DD"), "endDate": AgentToolParam(type: .string, description: "Statistics end YYYY-MM-DD"), "limit": AgentToolParam(type: .integer, description: "1..50"), "offset": AgentToolParam(type: .integer, description: "Pagination offset")
            ], required: []),
            AgentToolDefinition(name: focusCommand, description: "Control a real timer only when explicitly requested. Never fabricate past duration.", parameters: [
                "action": AgentToolParam(type: .string, description: "start, pause, resume, finish or delete", enumValues: ["start", "pause", "resume", "finish", "delete"]), "operationId": AgentToolParam(type: .string, description: "Stable ID reused for exact retries"), "targetId": AgentToolParam(type: .string, description: "Exact session ID except start"), "expectedRevision": AgentToolParam(type: .integer, description: "Fresh session revision except start"), "title": AgentToolParam(type: .string, description: "Title when starting"), "taskId": AgentToolParam(type: .string, description: "Optional task ID"), "mode": AgentToolParam(type: .string, description: "pomodoro, stopwatch or break", enumValues: ["pomodoro", "stopwatch", "break"]), "minutes": AgentToolParam(type: .integer, description: "1..180 minutes")
            ], required: ["action", "operationId"])
        ]
        return includeCommands ? tools : tools.filter { $0.name == todoQuery || $0.name == focusQuery }
    }

    static func promptParagraph() -> String {
        "Personal task and focus queries are available in authorized foreground user conversations. Writes are restricted to the main chat. Query exact IDs and revisions before writes, reuse operationId for exact retries, and report success only when success=true. Completion requires an exact quote of the current user's explicit completion report; plans or assistant claims never count. Focus duration comes only from device-measured intervals."
    }

    static func execute(name: String, args: [String: Any], model: NivoLifeModel, sessionID: String?, currentUser: NivoSavedUserTurn?,
                        host: AIChatViewModel, authorization: NivoPersonalRecordsAuthorization?) async throws -> Result {
        guard UIApplication.shared.applicationState == .active else { return failure("This tool requires a foreground user conversation.") }
        guard let sessionID else { return failure("A saved conversation is required.") }
        let isQuery = name == todoQuery || name == focusQuery
        guard isQuery || sessionID == UserDefaults.standard.string(forKey: NanoMuseMainChat.key) else { return failure("Changes are available only in the main chat.") }
        guard let currentUser, currentUser.chatSessionID == sessionID else { return failure("A current saved user turn is required.") }
        guard let scope = model.accessScope, currentUser.ownerKey == scope.ownerKey,
              currentUser.ownerKey == NanoMuseAccountData.shared.current else { return failure("Personal data is still loading; try again shortly.") }
        do {
            _ = try await host.nmRequireRecordsAccess(authorization)
            let result: Result
            switch name {
            case todoQuery:
                try await model.refreshForTool(scope: scope)
                _ = try await host.nmRequireRecordsAccess(authorization)
                result = try queryTodo(args, model: model)
            case todoCommand: result = try await commandTodo(args, model: model, scope: scope, user: currentUser)
            case focusQuery:
                try await model.refreshForTool(scope: scope)
                _ = try await host.nmRequireRecordsAccess(authorization)
                result = try queryFocus(args, model: model)
            case focusCommand: result = try await commandFocus(args, model: model, scope: scope, user: currentUser)
            default: return failure("Unknown life tool.")
            }
            guard model.accessScope == scope, scope.ownerKey == NanoMuseAccountData.shared.current else { throw NivoLifeError.accountChanged }
            _ = try await host.nmRequireRecordsAccess(authorization)
            guard result.output.utf8.count <= 2 * 1_024 * 1_024 else { return failure("Result is too large; reduce the limit. No text was truncated.") }
            return result
        } catch is CancellationError { throw CancellationError()
        } catch let error as NivoLifeError {
            if case .staleRevision = error { return failure("stale_revision: query the latest item before a new operation.") }
            return failure(NivoLifeModel.message(error))
        } catch { return failure(error.localizedDescription) }
    }

    private static func queryTodo(_ args: [String: Any], model: NivoLifeModel) throws -> Result {
        try NivoLifeToolInput.requireFields(args, allowed: ["kind", "targetId", "status", "search", "dateField", "startDate", "endDate", "limit", "offset"])
        let kind = try string(args, "kind", default: "tasks")
        if kind == "categories" {
            let search = try string(args, "search", default: "")
            guard search.utf16.count <= 200 else { throw ToolError.invalid("search is too long") }
            let (limit, offset) = try pagination(args, defaultLimit: 50)
            let rows = model.categories.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            let page = Array(rows.dropFirst(Int(offset)).prefix(Int(limit)))
            return success(["items": page.map(categoryJSON), "total": rows.count, "offset": offset,
                            "nextOffset": offset + limit < rows.count ? offset + limit : NSNull()])
        }
        if kind == "detail" {
            guard let id = args["targetId"] as? String, let task = model.tasks.first(where: { $0.id == id && $0.deletedAt == nil }) else { throw ToolError.notFound }
            return success(taskJSON(task, detail: true))
        }
        guard kind == "tasks" else { throw ToolError.invalid("Unknown query kind") }
        let status = try string(args, "status", default: "all")
        guard ["all", "todo", "in_progress", "done"].contains(status) else { throw ToolError.invalid("Unknown task status") }
        let search = try string(args, "search", default: "")
        guard search.utf16.count <= 200 else { throw ToolError.invalid("search is too long") }
        let dateField = try string(args, "dateField", default: "scheduled")
        guard ["scheduled", "due", "completed", "created"].contains(dateField) else { throw ToolError.invalid("Unknown date field") }
        let startDay = try day(args["startDate"])
        let endDay = try day(args["endDate"])
        guard startDay == nil || endDay == nil || startDay! <= endDay! else { throw ToolError.invalid("startDate must not follow endDate") }
        let rows = model.tasks.filter { task in
            guard task.deletedAt == nil, status == "all" || task.status.rawValue == status else { return false }
            guard search.isEmpty || ([task.id, task.title, task.notes, task.groupName] + task.tags).contains(where: { $0.localizedCaseInsensitiveContains(search) }) else { return false }
            let selectedDay: Int64? = {
                switch dateField {
                case "due": return task.dueDay
                case "completed": return task.completedDay
                case "created": return NivoLifeDay.value(Date(timeIntervalSince1970: Double(task.createdAt) / 1_000))
                default: return task.scheduledDay
                }
            }()
            guard startDay != nil || endDay != nil else { return true }
            guard let selectedDay else { return false }
            return (startDay == nil || selectedDay >= startDay!) && (endDay == nil || selectedDay <= endDay!)
        }.sorted { $0.updatedAt > $1.updatedAt }
        let (limit, offset) = try pagination(args, defaultLimit: 20)
        let page = Array(rows.dropFirst(Int(offset)).prefix(Int(limit)))
        return success(["items": page.map { taskJSON($0, detail: false) }, "total": rows.count, "offset": offset, "nextOffset": offset + limit < rows.count ? offset + limit : NSNull()])
    }

    private static func commandTodo(_ args: [String: Any], model: NivoLifeModel,
                                    scope: NivoLifeScope, user: NivoSavedUserTurn) async throws -> Result {
        let action = try required(args, "action"), operationID = try required(args, "operationId")
        guard ["create", "update", "start", "complete", "reopen", "delete", "create_category", "delete_category"].contains(action) else {
            throw ToolError.invalid("Unsupported task action")
        }
        try NivoLifeToolInput.requireFields(args, allowed: todoFields(action))
        try NivoTodoRules.validateOperationID(operationID)
        var request = NivoTodoToolCommand(action: action, identity: try identity(user))
        if action == "create_category" || action == "delete_category" {
            request.categoryKind = try categoryKind(required(args, "categoryKind"))
            request.categoryName = try required(args, "categoryName")
            if action == "delete_category" { request.expectedCreatedAt = try revision(args, "expectedCreatedAt") }
        } else {
            if action != "create" {
                request.targetID = try required(args, "targetId")
                request.expectedRevision = try revision(args, "expectedRevision")
            }
            if action == "create" || action == "update" { request.patch = try NivoLifeToolInput.patch(args) }
            if action == "complete" {
                request.userQuote = try completionQuote(args, user: user)
                request.completedDay = try day(args["completedDate"])
            } else if args["completedDate"] != nil { throw ToolError.invalid("completedDate is only valid for complete") }
        }
        let saved = try await model.performToolResult(scope: scope) { repository, captured, clock in
            try await repository.executeTodoToolResult(request, operationID: operationID, scope: captured,
                now: clock.wallMs, today: NivoLifeDay.value())
        }
        switch saved.value {
        case .task(let task):
            var data = taskJSON(task, detail: true)
            data["deleted"] = task.deletedAt != nil
            data["isReplaySnapshot"] = saved.isReplay
            data["currentState"] = model.tasks.first(where: { $0.id == task.id }).map { taskJSON($0, detail: true) } ?? NSNull()
            return success(data)
        case .category(let category):
            var data = categoryJSON(category)
            data["isReplaySnapshot"] = saved.isReplay
            data["currentState"] = model.categories.first(where: { $0.id == category.id }).map(categoryJSON) ?? NSNull()
            return success(data)
        }
    }

    private static func queryFocus(_ args: [String: Any], model: NivoLifeModel) throws -> Result {
        try NivoLifeToolInput.requireFields(args, allowed: ["kind", "targetId", "startDate", "endDate", "limit", "offset"])
        let kind = try string(args, "kind", default: "sessions")
        guard ["sessions", "active", "detail", "statistics"].contains(kind) else { throw ToolError.invalid("Unknown focus query kind") }
        let sampledAt = Int64(Date().timeIntervalSince1970 * 1_000)
        if kind == "statistics" {
            guard let start = try day(args["startDate"]), let end = try day(args["endDate"]), end >= start,
                  end - start <= 3_660 else { throw ToolError.invalid("statistics requires a valid range of at most 3661 days") }
            let calendar = Calendar.current
            let startMs = calendar.startOfDay(for: NivoLifeDay.date(start)).timeIntervalSince1970 * 1_000
            let endMs = calendar.startOfDay(for: NivoLifeDay.date(end + 1)).timeIntervalSince1970 * 1_000
            let duration = NivoFocusRules.duration(sessions: model.focusSessions, spans: model.focusSpans,
                                                   startMs: Int64(startMs), endMs: Int64(endMs))
            return success(["durationMs": duration, "startDate": dateString(start), "endDate": dateString(end),
                            "includesBreaks": false, "sampledAt": sampledAt, "view_url": "minis://views/focus"])
        }
        if kind == "detail" { guard let id = args["targetId"] as? String, let session = model.focusSessions.first(where: { $0.id == id && $0.deletedAt == nil }) else { throw ToolError.notFound }; return success(focusJSON(session, sampledAt: sampledAt)) }
        let start = try day(args["startDate"])
        let end = try day(args["endDate"])
        let rows = try NivoPersonalRecordsFocusQuery.rows(model.focusSessions, kind: kind, startDay: start, endDay: end)
        let (limit, offset) = try pagination(args, defaultLimit: 20)
        let page = Array(rows.dropFirst(Int(offset)).prefix(Int(limit)))
        return success(["items": page.map { focusJSON($0, sampledAt: sampledAt) }, "total": rows.count, "offset": offset,
                        "nextOffset": offset + limit < rows.count ? offset + limit : NSNull(), "limit": limit,
                        "dateField": "startedAt", "timezone": TimeZone.current.identifier,
                        "view_url": "minis://views/focus", "sampledAt": sampledAt])
    }

    private static func commandFocus(_ args: [String: Any], model: NivoLifeModel,
                                     scope: NivoLifeScope, user: NivoSavedUserTurn) async throws -> Result {
        let action = try required(args, "action"), operationID = try required(args, "operationId")
        guard ["start", "pause", "resume", "finish", "delete"].contains(action) else { throw ToolError.invalid("Unsupported focus action") }
        let fields: Set<String> = action == "start"
            ? ["action", "operationId", "title", "taskId", "mode", "minutes"]
            : ["action", "operationId", "targetId", "expectedRevision"]
        try NivoLifeToolInput.requireFields(args, allowed: fields)
        var request = NivoFocusToolCommand(action: action, identity: try identity(user))
        if action == "start" {
            let minutes = try integer(args, "minutes") ?? 25
            guard let mode = NivoFocusMode(rawValue: try string(args, "mode", default: "pomodoro")),
                  (1...180).contains(minutes) else {
                throw ToolError.invalid("mode or minutes is invalid")
            }
            request.mode = mode
            request.minutes = Int(minutes)
            request.title = try string(args, "title", default: "Focus")
            if let value = args["taskId"], !(value is NSNull) { request.taskID = try required(args, "taskId") }
        } else {
            request.targetID = try required(args, "targetId")
            request.expectedRevision = try revision(args, "expectedRevision")
        }
        let saved = try await model.performToolResult(scope: scope) { repository, captured, clock in
            try await repository.executeFocusToolResult(request, operationID: operationID, scope: captured, clock: clock)
        }
        let updated = saved.value
        let sampledAt = Int64(Date().timeIntervalSince1970 * 1_000)
        let current = model.focusSessions.first(where: { $0.id == updated.id })
        var value = focusJSON(updated, sampledAt: sampledAt, isHistorical: saved.isReplay)
        value["isReplaySnapshot"] = saved.isReplay
        value["currentState"] = current.map { focusJSON($0, sampledAt: sampledAt) } ?? NSNull()
        value["outcome"] = action == "pause" && updated.status == .finished ? "deadline_reached" : updated.status.rawValue
        value["view_url"] = "minis://views/focus"
        return success(value)
    }

    private static func todoFields(_ action: String) -> Set<String> {
        let common: Set<String> = ["action", "operationId"]
        switch action {
        case "create": return common.union(["payload"])
        case "update": return common.union(["targetId", "expectedRevision", "payload"])
        case "complete": return common.union(["targetId", "expectedRevision", "userQuote", "completedDate"])
        case "create_category": return common.union(["categoryKind", "categoryName"])
        case "delete_category": return common.union(["categoryKind", "categoryName", "expectedCreatedAt"])
        default: return common.union(["targetId", "expectedRevision"])
        }
    }

    private enum ToolError: LocalizedError { case invalid(String), notFound; var errorDescription: String? { switch self { case .invalid(let text): return text; case .notFound: return "The requested item was not found." } } }
    private static func success(_ value: Any) -> Result { Result(output: json(["success": true, "data": value]), success: true) }
    private static func failure(_ text: String) -> Result {
        let code = text.hasPrefix("stale_revision") ? "stale_revision" : "invalid_request"
        return Result(output: json(["success": false, "message": text, "code": code]), success: false)
    }
    private static func json(_ value: Any) -> String { guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "{\"success\":false,\"message\":\"serialization failed\"}" }; return text }
    private static func string(_ args: [String: Any], _ key: String, default value: String = "") throws -> String { try NivoLifeToolInput.text(args, key, default: value) }
    private static func required(_ args: [String: Any], _ key: String) throws -> String { guard let value = args[key] as? String, !value.isEmpty else { throw ToolError.invalid("Missing \(key)") }; return value }
    private static func integer(_ args: [String: Any], _ key: String) throws -> Int64? { try NivoLifeToolInput.integer(args, key) }
    private static func day(_ value: Any?) throws -> Int64? { try NivoLifeToolInput.day(value) }

    private static func revision(_ args: [String: Any], _ key: String) throws -> Int64 {
        guard let value = try integer(args, key), value >= 0 else { throw NivoLifeError.invalidField(key) }
        return value
    }

    private static func pagination(_ args: [String: Any], defaultLimit: Int64) throws -> (Int64, Int64) {
        let limit = try integer(args, "limit") ?? defaultLimit
        let offset = try integer(args, "offset") ?? 0
        guard (1...50).contains(limit), (0...1_000_000).contains(offset) else { throw NivoLifeError.invalidField("pagination") }
        return (limit, offset)
    }

    private static func identity(_ user: NivoSavedUserTurn) throws -> NivoLifeToolIdentity {
        guard let digest = user.sourceDigest, !user.id.isEmpty else { throw NivoLifeError.invalidField("saved_user_turn") }
        return NivoLifeToolIdentity(chatID: user.chatSessionID, messageID: user.id, sourceDigest: digest)
    }

    private static func completionQuote(_ args: [String: Any], user: NivoSavedUserTurn) throws -> String {
        let quote = try required(args, "userQuote")
        guard quote.utf16.count <= 2_000, user.text.contains(quote),
              NivoTodoCompletionEvidence.isExplicitReport(userText: user.text, quote: quote) else {
            throw ToolError.invalid("Completion report is unclear; quote the user's explicit completion sentence")
        }
        return quote
    }
    private static func dateString(_ day: Int64) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: NivoLifeDay.date(day, timeZone: TimeZone(secondsFromGMT: 0)!))
    }
    private static func categoryKind(_ raw: String) throws -> NivoTodoCategory.Kind { guard let kind = NivoTodoCategory.Kind(rawValue: raw) else { throw ToolError.invalid("categoryKind must be group or tag") }; return kind }
    private static func taskJSON(_ task: NivoTodoTask, detail: Bool) -> [String: Any] {
        var value: [String: Any] = ["id": task.id, "title": task.title, "status": task.status.rawValue, "revision": task.revision,
                                    "groupName": task.groupName, "tags": task.tags, "isImportant": task.isImportant, "isUrgent": task.isUrgent,
                                    "scheduledDate": task.scheduledDay.map(dateString) ?? NSNull(), "dueDate": task.dueDay.map(dateString) ?? NSNull(),
                                    "completedDate": task.completedDay.map(dateString) ?? NSNull()]
        if detail { value["notes"] = task.notes; value["createdAt"] = task.createdAt; value["updatedAt"] = task.updatedAt }
        return value
    }
    private static func categoryJSON(_ category: NivoTodoCategory) -> [String: Any] { ["kind": category.kind.rawValue, "name": category.name, "createdAt": category.createdAt, "updatedAt": category.updatedAt] }
    private static func focusJSON(_ session: NivoFocusSession, sampledAt: Int64, isHistorical: Bool = false) -> [String: Any] {
        let clock = NivoLifeClock.sample()
        // 旧回执不能按当前时钟继续外推；实时值只放在另读的currentState中。
        let current = isHistorical ? session.elapsedMs : NivoFocusRules.currentElapsed(session, clock: clock)
        return ["id": session.id, "title": session.title, "status": session.status.rawValue, "mode": session.mode.rawValue,
                "targetMs": session.targetMs, "elapsedMs": session.elapsedMs, "currentElapsedMs": current,
                "remainingMs": max(0, session.targetMs - current), "revision": session.revision,
                "startedAt": session.startedAt, "endedAt": session.endedAt.map { $0 as Any } ?? NSNull(),
                "groupName": session.groupName, "tags": session.tags,
                "taskId": session.taskId ?? NSNull(), "view_url": "minis://views/focus", "sampledAt": sampledAt]
    }
}
