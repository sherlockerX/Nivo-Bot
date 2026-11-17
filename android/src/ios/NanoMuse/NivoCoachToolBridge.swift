import Foundation
import UIKit
import CoreFoundation

/// Android Coach v2 的主聊天工具桥。查询和命令都只访问当前账户的Coach v2快照，
/// 不接受路径、Markdown或模型自行伪造的用户身份。
@MainActor
enum NivoCoachToolBridge {
    struct Result { var output: String; var success: Bool }
    static let query = "coach_query"
    static let command = "coach_command"
    private static let queryKinds = ["overview", "courses", "sessions", "drafts", "actions", "topics"]
    private static var actions: [String] { NivoCoachPolicy.actions }

    static func definitions(includeCommands: Bool = true) -> [AgentToolDefinition] {
        let tools = [
            AgentToolDefinition(name: query, description: "Read the current account's structured Coach courses, sessions, topics and drafts. Query exact IDs before changes.", parameters: [
                "kind": AgentToolParam(type: .string, description: "overview, courses, sessions, drafts, actions or topics", enumValues: queryKinds),
                "targetId": AgentToolParam(type: .string, description: "Exact object ID for detail"),
                "limit": AgentToolParam(type: .integer, description: "1..30"),
                "offset": AgentToolParam(type: .integer, description: "Pagination offset")
            ], required: []),
            AgentToolDefinition(name: command, description: "Apply one explicitly requested Coach v2 change. Use current global revision and stable operationId; success means the local snapshot was saved.", parameters: [
                "action": AgentToolParam(type: .string, description: "Controlled Coach action", enumValues: actions),
                "operationId": AgentToolParam(type: .string, description: "Stable retry identifier"),
                "expectedRevision": AgentToolParam(type: .integer, description: "Current global Coach revision"),
                "targetId": AgentToolParam(type: .string, description: "Exact course, session, topic or draft ID"),
                "text": AgentToolParam(type: .string, description: "Current user text, teaching text or confirmation"),
                "payload": AgentToolParam(type: .string, description: "JSON object for unit, assessment, course or lesson fields")
            ], required: ["action", "operationId", "expectedRevision"])
        ]
        return includeCommands ? tools : tools.filter { $0.name == query }
    }

    static func promptParagraph() -> String {
        "Coach is local structured learning data. The foreground main chat manages courses; a daily-practice conversation is restricted to its bound topic. Query exact IDs and the global revision before mutations. Reuse the entire original request and operationId for exact retries. Save draft goals as exact current user quotes. Propose with a course and sourceStatus; activate only with draftRevision after the user explicitly confirms in a later message. Teach normally and answer free questions. Host archives real user messages and final visible assistant text. coach_reply can add a practice/review assessment with dimension and optional reviewOfSessionId; its text must appear in the final visible reply. When pendingTurnId exists, include it as payload.requestTurnId. answer marks an existing saved user turn as an independent attempt only if a traceable question preceded it. Evidence entries need criterionId, turnId, quote, reason and met. Ordinary teaching, hints and plans never certify mastery. Real-action criteria require action_report quoting the user's actual event; a simulation does not qualify. End lessons with end_lesson, which does not mean mastery. Delayed review is checked against the host clock and previous independent evidence. Never edit Coach files with shell tools or claim success when success=false."
    }

    static func execute(name: String, args: [String: Any], model: NivoLifeModel, sessionID: String?, currentUser: NivoSavedUserTurn?,
                        host: AIChatViewModel, authorization: NivoPersonalRecordsAuthorization?) async throws -> Result {
        guard UIApplication.shared.applicationState == .active else { return failure("Coach tools require the foreground app.") }
        guard let sessionID, let currentUser, let scope = model.accessScope,
              currentUser.ownerKey == scope.ownerKey, currentUser.chatSessionID == sessionID,
              NanoMuseSync.shared.shows(sessionID) else { return failure("A current saved user turn is required.") }
        let isMain = sessionID == UserDefaults.standard.string(forKey: NanoMuseMainChat.key)
        do {
            _ = try await host.nmRequireRecordsAccess(authorization)
            // 全局历史查询只读取现有快照，不触发课程初始化、迁移或来源对账。
            if name == query {
                try NivoLifeToolInput.requireFields(args, allowed: ["kind", "targetId", "limit", "offset"])
                var parameters = args
                parameters["kind"] = "coach"
                parameters["section"] = args["kind"] ?? "overview"
                let request = try NivoPersonalRecordsRequest.parse(parameters)
                let state = try await NivoCoachV2Store.shared.snapshot(ownerKey: scope.ownerKey)
                _ = try await host.nmRequireRecordsAccess(authorization)
                let visible = try NivoPersonalRecordsCoachScope.visible(state, chatID: sessionID,
                    requiresTopic: host.sessionSource == NivoCoachConversationIdentity.source)
                return .init(output: try NivoPersonalRecordsOutput.coach(request, state: visible), success: true)
            }
            guard name == command, isMain || NivoCoachChatContext.shared.isPractice(sessionID) else {
                return failure("Coach changes require the main chat or its bound practice conversation.")
            }
            let generation = try await NivoCoachV2Store.shared.access(ownerKey: scope.ownerKey)
            _ = try await host.nmRequireRecordsAccess(authorization)
            if isMain { try await NivoCoachReconciliation.reconcileAll(scope: scope, generation: generation) }
            else { try await NivoCoachReconciliation.reconcile(chatSessionID: sessionID, scope: scope, generation: generation) }
            guard model.accessScope == scope else { throw NivoLifeError.accountChanged }
            _ = try await host.nmRequireRecordsAccess(authorization)
            let context = NivoCoachCommandContext(ownerKey: scope.ownerKey, generation: generation,
                chatSessionID: sessionID, isMain: isMain, user: currentUser)
            let result = try await command(args, context: context)
            guard model.accessScope == scope, UIApplication.shared.applicationState == .active else { throw NivoLifeError.accountChanged }
            _ = try await host.nmRequireRecordsAccess(authorization)
            NotificationCenter.default.post(name: .nivoCoachStateChanged, object: scope.ownerKey)
            return result
        } catch is CancellationError { throw CancellationError()
        } catch let error as NivoLifeError {
            if case .staleRevision = error { return failure("State changed. Query again before a new operation.", code: "stale_revision") }
            return failure(NivoLifeModel.message(error))
        } catch { return failure(error.localizedDescription) }
    }

    private static func query(_ args: [String: Any], state: NivoCoachState) throws -> Result {
        let kind = string(args, "kind", default: "overview")
        guard queryKinds.contains(kind) else { throw ToolError.invalid("Unknown query kind") }
        let target = string(args, "targetId")
        if !target.isEmpty {
            let detail: Any
            switch kind {
            case "courses": detail = state.tracks.first { $0.id == target }.map { encode($0) } ?? NSNull()
            case "sessions": detail = state.sessions.first { $0.id == target }.map { encode($0) } ?? NSNull()
            case "drafts": detail = state.drafts.first { $0.id == target }.map { encode($0) } ?? NSNull()
            case "actions": detail = state.actions.first { $0.id == target }.map { encode($0) } ?? NSNull()
            case "topics": detail = state.topics.first { $0.id == target }.map { encode($0) } ?? NSNull()
            default: detail = overview(state)
            }
            guard !(detail is NSNull) else { throw ToolError.notFound }
            return success(["revision": state.revision, "data": detail])
        }
        let limit = min(max(integer(args, "limit") ?? 12, 1), 30)
        let offset = max(integer(args, "offset") ?? 0, 0)
        let data: Any
        switch kind {
        case "overview": data = overview(state)
        case "courses": data = Array(state.tracks.dropFirst(Int(offset)).prefix(Int(limit))).map { ["id": $0.id, "title": $0.course.title, "kind": $0.course.kind.rawValue, "currentUnitId": $0.currentUnitID, "paused": $0.paused, "unitCount": $0.course.units.count, "needsCriteriaReview": $0.course.needsCriteriaReview] }
        case "sessions": data = Array(state.sessions.reversed().dropFirst(Int(offset)).prefix(Int(limit))).map { ["id": $0.id, "courseId": $0.course.id, "unitId": $0.unitID, "status": $0.status, "stage": $0.stage, "revision": $0.revision, "topicId": $0.topicID, "mode": $0.mode, "teachingProtocol": $0.teachingProtocol] }
        case "drafts": data = Array(state.drafts.reversed().dropFirst(Int(offset)).prefix(Int(limit))).map { ["id": $0.id, "status": $0.status, "revision": $0.revision, "sourceStatus": $0.sourceStatus, "title": $0.course?.title ?? ""] }
        case "actions": data = Array(state.actions.reversed().dropFirst(Int(offset)).prefix(Int(limit))).map { ["id": $0.id, "sessionId": $0.sessionID, "status": $0.status] }
        case "topics": data = topicSummaries(state: state, offset: offset, limit: limit)
        default: data = []
        }
        let count = count(state, kind: kind)
        return success(["revision": state.revision, "data": data, "total": count, "offset": offset, "nextOffset": offset + limit < count ? offset + limit : NSNull()])
    }

    private static func command(_ args: [String: Any], context: NivoCoachCommandContext) async throws -> Result {
        let action = try required(args, "action")
        guard actions.contains(action) else { throw ToolError.invalid("Unsupported Coach action") }
        let operationID = try required(args, "operationId")
        try NivoTodoRules.validateOperationID(operationID)
        guard let expected = integer(args, "expectedRevision") else { throw ToolError.invalid("expectedRevision must be an integer") }
        let request = NivoCoachCommand(action: action, operationID: operationID, expectedRevision: expected,
            targetID: string(args, "targetId"), text: string(args, "text"), payload: string(args, "payload"))
        let result = try await NivoCoachV2Store.shared.execute(request, context: context)
        let value = try JSONSerialization.jsonObject(with: Data(result.dataJSON.utf8))
        return success(["revision": result.revision, "targetId": result.targetID, "data": value, "isReplaySnapshot": result.isReplaySnapshot])
    }

    private static func topicSummaries(state: NivoCoachState, offset: Int64, limit: Int64) -> [[String: Any]] {
        state.topics.reversed().dropFirst(Int(offset)).prefix(Int(limit)).map { topic in
            let progress = NivoCoachTeaching.progress(state, topicID: topic.id)
            return ["id": topic.id, "courseId": topic.courseID, "unitId": topic.unitID, "title": topic.title, "status": topic.status,
                    "hasUnderstanding": progress.hasUnderstanding, "hasApplication": progress.hasApplication,
                    "hasDelayedReview": progress.hasDelayedReview, "isDemonstrated": progress.isDemonstrated]
        }
    }

    private static func overview(_ state: NivoCoachState) -> [String: Any] { ["selectedCourseId": state.selectedCourseID, "revision": state.revision, "courses": state.tracks.count, "sessions": state.sessions.count, "drafts": state.drafts.count, "actions": state.actions.count, "topics": state.topics.count] }
    private static func count(_ state: NivoCoachState, kind: String) -> Int { switch kind { case "courses": return state.tracks.count; case "sessions": return state.sessions.count; case "drafts": return state.drafts.count; case "actions": return state.actions.count; case "topics": return state.topics.count; default: return 0 } }
    private static func encode<T: Encodable>(_ value: T) -> Any { guard let data = try? JSONEncoder.sorted.encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }; return object }
    private static func success(_ data: [String: Any]) -> Result { Result(output: json(["success": true, "data": data]), success: true) }
    private static func failure(_ message: String, code: String = "invalid_request") -> Result { Result(output: json(["success": false, "message": message, "code": code]), success: false) }
    private static func json(_ value: Any) -> String { guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "{\"success\":false,\"message\":\"serialization failed\"}" }; return text }
    private static func string(_ args: [String: Any], _ key: String, default fallback: String = "") -> String { args[key] as? String ?? fallback }
    private static func integer(_ args: [String: Any], _ key: String) -> Int64? {
        guard let number = args[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int64(number.stringValue) else { return nil }
        return value
    }
    private static func required(_ args: [String: Any], _ key: String) throws -> String { guard let value = args[key] as? String, !value.isEmpty else { throw ToolError.invalid("Missing \(key)") }; return value }
    private enum ToolError: LocalizedError { case invalid(String), notFound; var errorDescription: String? { switch self { case .invalid(let text): return text; case .notFound: return "Coach object not found; query again." } } }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}
