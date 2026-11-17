import Foundation

/// 只在真实用户操作入口捕获；来源本身不可由模型参数或保存的聊天历史恢复。
struct NivoUserTurnOrigin: Equatable, Sendable {
    let hostID: String
    let sessionID: String?
    let draftID: String
    let scope: NivoLifeScope
    let visibilityID: UUID?

    /// 前台、可见页面和账户就绪缺一不可，任务派发始终拒绝。
    static func capture(hostID: String, sessionID: String?, draftID: String, scope: NivoLifeScope,
                        isForeground: Bool, isVisible: Bool, isDispatch: Bool, visibilityID: UUID? = nil) -> Self? {
        guard isForeground, isVisible, !isDispatch else { return nil }
        return Self(hostID: hostID, sessionID: sessionID, draftID: draftID, scope: scope, visibilityID: visibilityID)
    }

    /// 同一宿主只允许自己的草稿转为正式会话，不能跨账户代次或复用临时消息ID。
    func canBind(hostID: String, sessionID: String, draftID: String,
                 scope: NivoLifeScope, messageID: String, visibilityID: UUID? = nil) -> Bool {
        guard self.hostID == hostID, self.scope == scope, self.visibilityID == visibilityID, !messageID.isEmpty,
              !sessionID.isEmpty else { return false }
        if let original = self.sessionID { return original == sessionID }
        return self.draftID == draftID
    }

    /// 队列只有每一项都来自同一个真实用户上下文时才继承权限。
    static func merged(_ origins: [Self?]) -> Self? {
        guard let candidate = origins.first, let first = candidate,
              origins.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

/// 回合代次和完整消息签名一起固定，取消、切换账户、编辑原话均撤销旧结果。
struct NivoPersonalRecordsAuthorization: Equatable, Sendable {
    let hostID: String
    let turnID: UUID
    let scope: NivoLifeScope
    let user: NivoSavedUserTurn
    var visibilityID: UUID? = nil

    /// 执行期间只接受这一轮实际保存的用户消息，不能按相同文本寻找别的历史消息。
    func matches(hostID: String, turnID: UUID, scope: NivoLifeScope,
                 user: NivoSavedUserTurn) -> Bool {
        self.hostID == hostID && self.turnID == turnID && self.scope == scope && self.user == user
    }
}

/// 普通聊天可以读取账户记录，专题聊天无论从哪个查询入口进入都只见自己的案例。
enum NivoPersonalRecordsCoachScope {
    /// 以已保存绑定为准，缓存缺失不能把专题误判成普通聊天；显式专题失去绑定时拒绝。
    static func visible(_ state: NivoCoachState, chatID: String, requiresTopic: Bool) throws -> NivoCoachState {
        guard !chatID.isEmpty else { throw NivoLifeError.invalidField("coach_scope") }
        let hasBinding = state.topics.contains { $0.chatSessionID == chatID }
        return try NivoCoachPolicy.visible(state, chatID: chatID, isMain: !hasBinding && !requiresTopic)
    }
}

/// 个人工具结果可以参与授权模型回合，但不进入正文诊断或无授权文件读取目录。
enum NivoPersonalRecordsPrivacy {
    static let toolNames: Set<String> = ["personal_records_query", "todo_query", "todo_command",
        "focus_query", "focus_command", "coach_query", "coach_command", "mosaic_query"]

    /// 所有注册、汇总、诊断和文件卸载共用同一组工具名称。
    static func isPersonalTool(_ name: String) -> Bool { toolNames.contains(name) }

    /// 旧历史进入上下文预算路径时也不能把个人结果写到模型可任意重读的目录。
    static func canOffload(_ name: String) -> Bool { !isPersonalTool(name) }

    /// 个人结果仅保留工具名、长度和状态，普通工具保留已有的有界诊断摘要。
    static func historySummary(id: String, name: String, content: String, isError: Bool, hasImage: Bool) -> String {
        let status = (isError ? " [ERROR]" : "") + (hasImage ? " [IMG]" : "")
        let metadata = "tool_result(\(name), id:\(id.prefix(20)), \(content.count)ch\(status))"
        guard !isPersonalTool(name) else { return metadata + ": [personal records omitted]" }
        let head = String(content.prefix(200)) + (content.count > 200 ? "..." : "")
        let tail = content.count > 400 ? " tail=\"...\(content.suffix(200))\"" : ""
        return metadata + ": head=\"\(head)\"" + tail
    }
}
