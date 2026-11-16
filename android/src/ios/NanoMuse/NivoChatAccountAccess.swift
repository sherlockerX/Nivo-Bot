import Foundation

/// 对话占用提示独立于待办的请求幂等冲突，避免把正在运行误报为内容重复。
enum NivoChatAccessError: LocalizedError {
    case busy
    var errorDescription: String? { AppLocalized("Wait for this conversation or task to finish before changing it.") }
}

/// 缓存中的聊天和语音对象也要核对归属，不能只依赖根页面已经切换。
@MainActor
enum NivoChatAccountAccess {
    /// 发送、重试、继续和语音开始共用入口；未认领的新草稿仍可创建。
    static func require(sessionID: String?, scheduledRunID: String? = nil) throws {
        let account = NanoMuseAccountData.shared
        guard account.isReady, !account.isChangingAccount else { throw NivoLifeError.accountChanged }
        if let sessionID, !account.shows(sessionID) { throw NivoLifeError.accountChanged }
        guard !NivoPersonalBackupAccess.isBusy else { throw NivoPersonalBackupError.busy }
        guard NivoScheduledRunScopes.shared.canStart(sessionID: sessionID, runID: scheduledRunID) else {
            throw NivoChatAccessError.busy
        }
    }

    /// 占位贯穿异步清空和删除；界面在持久提交成功后再移除列表项。
    static func requestConversationEdit(_ identifiers: Set<String>) -> UUID? {
        do {
            return try beginConversationEdit(identifiers)
        } catch {
            ShareFeedbackToast.show(NivoLifeModel.message(error))
            return nil
        }
    }

    /// 同步和调试入口沿用同一占位，失败交给调用方重试，后台处理不弹界面提示。
    static func beginConversationEdit(_ identifiers: Set<String>, scheduledRunID: String? = nil) throws -> UUID {
        for identifier in identifiers { try require(sessionID: identifier, scheduledRunID: scheduledRunID) }
        return try beginSynchronizedEdit(identifiers, scheduledRunID: scheduledRunID)
    }

    /// 设备级iCloud可维护隐藏账户的聊天，仍须遵循全局冻结和每个会话的运行占位。
    static func beginSynchronizedEdit(_ identifiers: Set<String>, scheduledRunID: String? = nil) throws -> UUID {
        let account = NanoMuseAccountData.shared
        guard account.isReady, !account.isChangingAccount else { throw NivoLifeError.accountChanged }
        guard !NivoPersonalBackupAccess.isBusy else { throw NivoPersonalBackupError.busy }
        for identifier in identifiers {
            guard !SessionActivityTracker.shared.resolvedActiveSessionIds.contains(identifier),
                  ViewModelCache.shared.get(for: identifier)?.isProcessing != true,
                  ViewModelCache.shared.get(for: identifier)?.isTruncatingForRetry != true else {
                throw NivoChatAccessError.busy
            }
        }
        return try NivoScheduledRunScopes.shared.beginConversationEdit(identifiers, scheduledRunID: scheduledRunID)
    }
}
