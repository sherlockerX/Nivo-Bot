import Foundation
import CryptoKit

/// 保存后的原话边界，在所有个人数据工具中复用。
enum NivoUserTurnEvidence {
    /// 附件提示可能与用户文本同存一行，授权仍只取用户实际输入的原话。
    static func validated(_ row: RawMessage, text: String, sessionID: String, owner: String) -> NivoSavedUserTurn? {
        guard row.sessionId == sessionID, row.role == .user, !row.isToolResultOnly,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (row.parts.contains(where: { part in
                  if case .text(let stored) = part { return stored == text || stored.hasPrefix(text + "\n") }
                  return false
              }) || row.parts.compactMap({ part -> String? in
                  if case .text(let stored) = part { return stored }; return nil
              }).joined(separator: "\n") == text) else { return nil }
        return NivoSavedUserTurn(id: row.id, text: text, ownerKey: owner, chatSessionID: sessionID,
                                 createdAt: Int64(row.createdAt.timeIntervalSince1970 * 1_000), sourceDigest: digest(row))
    }

    /// 来源签名覆盖完整文本分段，追加或删减原话也会撤销旧证据。
    static func digest(_ row: RawMessage) -> String {
        let parts = row.parts.compactMap { part -> String? in if case .text(let text) = part { return text }; return nil }
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
extension AIChatViewModel {
    /// 从当前轮次的持久化历史定位数据库ID，再读库验证，未落盘和定时消息都不授权写入。
    func nmSavedUserTurn(_ message: ChatMessage?) async -> NivoSavedUserTurn? {
        guard let message, message.role == .user, !message.isQueued, !message.isCompactedHistory,
              message.nmRoutine == nil, message.nmFromDevice == nil,
              let scope = NivoLifeModel.shared.accessScope, let sessionId,
              NanoMuseSync.shared.shows(sessionId) else { return nil }
        if let authorization = nmPersonalRecordsAuthorization,
           message.nmSourceMessageIDs.contains(authorization.user.id) {
            return try? await nmRequireRecordsAccess(authorization)
        }
        // 归档恢复可核对已有来源ID，但这份证据本身不产生任何工具读取权限。
        guard message.nmSourceMessageIDs.count == 1, let identifier = message.nmSourceMessageIDs.first,
              let row = try? await ChatStore.shared.nmLoadEvidenceMessage(id: identifier),
              NivoLifeModel.shared.accessScope == scope, self.sessionId == sessionId,
              NanoMuseAccountData.shared.current == scope.ownerKey,
              NanoMuseSync.shared.shows(sessionId) else { return nil }
        return NivoUserTurnEvidence.validated(row, text: message.content, sessionID: sessionId, owner: scope.ownerKey)
    }
}
