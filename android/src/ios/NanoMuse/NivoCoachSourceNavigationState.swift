import Foundation

/// 原消息跳转绑定账户代次和真实数据库ID，界面UUID仅作为解析结果。
struct NivoCoachNavigationRequest: Equatable, Sendable {
    let id: UUID
    let chatID: String
    let messageID: String
    let scope: NivoLifeScope
}

/// 一条展示消息可以合并多个持久化消息，来源集合保留这种多对一关系。
struct NivoCoachSourceMessageTarget: Equatable, Sendable {
    let id: UUID
    let sourceIDs: Set<String>
}

/// 只在目标会话已加载且可见时解析；不根据正文相似度猜测位置。
struct NivoCoachSourceNavigationState: Equatable, Sendable {
    enum Decision: Equatable {
        case waiting, discarded, unavailable, scroll(UUID)
    }

    private(set) var pending: NivoCoachNavigationRequest?

    /// 后一次点击取代前一次意图，空ID不会留下旧请求继续跳转。
    mutating func enqueue(chatID: String, messageID: String, scope: NivoLifeScope) -> Bool {
        guard !chatID.isEmpty, !messageID.isEmpty else { pending = nil; return false }
        pending = NivoCoachNavigationRequest(id: UUID(), chatID: chatID, messageID: messageID, scope: scope)
        return true
    }

    /// 切号、备份冻结及同账户恢复均撤销旧来源导航。
    mutating func invalidate(unless scope: NivoLifeScope?) {
        if pending?.scope != scope { pending = nil }
    }

    /// 只有唯一的来源映射才可跳转；加载前或另一会话不得消费请求。
    func decision(scope: NivoLifeScope?, chatID: String?, isReady: Bool, isVisible: Bool,
                  messages: [NivoCoachSourceMessageTarget]) -> Decision {
        guard let pending else { return .waiting }
        guard scope == pending.scope else { return .discarded }
        guard chatID == pending.chatID, isReady, isVisible else { return .waiting }
        let matches = Set(messages.filter { $0.sourceIDs.contains(pending.messageID) }.map(\.id))
        guard matches.count == 1, let identifier = matches.first else { return .unavailable }
        return .scroll(identifier)
    }

    /// 列表完成定位后消费一次，迟到的回调不能清掉用户后来点击的目标。
    mutating func consume(_ identifier: UUID) {
        if pending?.id == identifier { pending = nil }
    }
}
