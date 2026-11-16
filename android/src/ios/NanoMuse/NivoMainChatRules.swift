import Foundation

/// 首页只能自动恢复可编辑的普通聊天，专属训练与定时任务始终留在各自入口。
enum NivoMainChatRules {
    static let coachSource = "coach_practice"
    static let routineSource = "nanomuse-routine"

    /// 只保留选择主聊天所需的字段，账户可见性由调用方在生成候选前检查。
    struct Candidate: Sendable {
        let id: String
        let updatedAt: Date
        let isRemote: Bool
        let source: String?
    }

    /// 旧记录没有source时仍是普通聊天，未知来源也不擅自改变原有用途。
    static func isEligible(isRemote: Bool, source: String?) -> Bool {
        !isRemote && source != coachSource && source != routineSource
    }

    /// 有效的固定会话优先，否则使用最近的普通聊天；只有专属会话时应创建空草稿。
    static func select(_ candidates: [Candidate], preferredID: String?) -> String? {
        let eligible = candidates.filter { isEligible(isRemote: $0.isRemote, source: $0.source) }
        if let preferredID, eligible.contains(where: { $0.id == preferredID }) { return preferredID }
        return eligible.max {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt < $1.updatedAt
        }?.id
    }
}
