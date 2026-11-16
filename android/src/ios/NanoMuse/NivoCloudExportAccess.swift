import Foundation

/// 云端发送从读取快照到处理回执期间占位，避免备份恢复混入同一批正在发送的配置。
@MainActor
enum NivoCloudExportAccess {
    private static var tokens: Set<UUID> = []
    static var isBusy: Bool { !tokens.isEmpty }

    /// 不排队丢弃脏记录，由同步宿主在恢复结束后重试原发送请求。
    static func begin() -> UUID? {
        let account = NanoMuseAccountData.shared
        guard account.isReady, !account.isChangingAccount, !NivoPersonalBackupAccess.isBusy,
              !BackupRestoreJournal.hasPendingRecovery, !EnvVarStore.hasPendingRecovery else { return nil }
        let identifier = UUID()
        tokens.insert(identifier)
        return identifier
    }

    /// 每个发送仅释放自己的占位，迟到回调不能解除其他任务的边界。
    static func end(_ identifier: UUID) { tokens.remove(identifier) }
}
