import Foundation

/// iCloud修改聊天时与普通聊天、定时执行、账户事务和个人备份共用占位边界。
@MainActor
enum NivoCloudChatAccess {
    /// 等待现有操作结束，保留来访事件；取消由上层保留旧游标，不能当作已应用。
    static func acquire(sessionID: String?) async throws -> UUID? {
        while true {
            try Task.checkCancellation()
            if canApply {
                guard let sessionID, !sessionID.isEmpty else { return nil }
                if let token = try? NivoChatAccountAccess.beginSynchronizedEdit([sessionID]) { return token }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// 同步可更新已归属其他账户的SQLite聊天，但不能在账户文件安装或恢复中途操作。
    private static var canApply: Bool {
        let account = NanoMuseAccountData.shared
        return account.isReady && !account.isChangingAccount && !NivoPersonalBackupAccess.isBusy
            && !BackupRestoreJournal.hasPendingRecovery
    }

    /// 查找来源后再占位，SQL事务再次核对来源，防止等待期间同ID记录发生变化。
    static func delete(recordType: String, id: String) async throws -> Bool {
        _ = try await acquire(sessionID: nil)
        guard let transferToken = NivoCloudExportAccess.begin() else { throw NivoPersonalBackupError.busy }
        defer { NivoCloudExportAccess.end(transferToken) }
        let sessionID = try await ChatStore.shared.nmRemoteChatSession(recordType: recordType, id: id)
        let token = try await acquire(sessionID: sessionID)
        defer { if let token { NivoScheduledRunScopes.shared.endConversationEdit(token) } }
        return try await ChatStore.shared.nmApplyRemoteChatDeletion(recordType: recordType, id: id,
            expectedSessionID: sessionID)
    }

    /// 本地迁移沿用全局数据传输租约和每会话占位，读取目标到提交期间不允许切号或恢复。
    static func backfillLegacyReferences(isCurrent: () -> Bool) async throws {
        guard isCurrent() else { throw CancellationError() }
        guard let transferToken = NivoCloudExportAccess.begin() else { throw NivoPersonalBackupError.busy }
        defer { NivoCloudExportAccess.end(transferToken) }
        let identifiers = try await ChatStore.shared.nmLegacyBackfillSessionIDs()
        guard isCurrent() else { throw CancellationError() }
        let editToken = try NivoChatAccountAccess.beginSynchronizedEdit(identifiers)
        defer { NivoScheduledRunScopes.shared.endConversationEdit(editToken) }
        _ = try await ChatStore.shared.backfillRemoteToLocal(expectedSessionIDs: identifiers)
    }

    /// 旧协议消息名可能不含会话ID，严格查询来源后占位，整会话级联保留本机副本。
    static func deleteLegacyMessage(recordName: String, deviceID: String,
                                    preservingSessions: Set<String>) async throws {
        _ = try await acquire(sessionID: nil)
        guard let transferToken = NivoCloudExportAccess.begin() else { throw NivoPersonalBackupError.busy }
        defer { NivoCloudExportAccess.end(transferToken) }
        let identity = try NivoCloudReferenceSQL.MessageIdentity(recordName: recordName)
        let owner = try await ChatStore.shared.nmLegacyMessageSession(id: identity.id, deviceID: deviceID)
        if let claimed = identity.sessionID, let owner, claimed != owner { throw NivoCloudChatSQLError.messageOwnerChanged }
        let sessionID = identity.sessionID ?? owner
        let editToken = try await acquire(sessionID: sessionID)
        defer { if let editToken { NivoScheduledRunScopes.shared.endConversationEdit(editToken) } }
        try await ChatStore.shared.nmDeleteLegacyMessage(identity, deviceID: deviceID,
            expectedSessionID: sessionID, preservingSessions: preservingSessions)
    }

    /// 只清理参考会话也要占用数据传输边界，防止备份恢复在异步交接中替换数据库。
    static func deleteLegacySession(id: String, deviceID: String) async throws {
        _ = try await acquire(sessionID: nil)
        guard let transferToken = NivoCloudExportAccess.begin() else { throw NivoPersonalBackupError.busy }
        defer { NivoCloudExportAccess.end(transferToken) }
        try await ChatStore.shared.deleteRemoteSession(id: id, deviceId: deviceID)
    }
}
