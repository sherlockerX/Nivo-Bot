import Foundation

/// 清理普通过期墓碑时保留持久事务的确认回执，防止恢复重放覆盖后续操作。
enum NivoSyncReceiptRetention {
    /// 在ChatStore数据库打开后调用，读取或写入错误由宿主报告。
    static func prune(database: OpaquePointer, before cutoff: Date) throws {
        try NivoSQLiteWrite.execute(database, sql: """
            DELETE FROM deleted_record_tombstones
            WHERE record_type NOT IN ('RelayConversation', 'ProviderDeletionTransaction', 'EnvVarTransaction')
                AND deleted_at < ?
            """, values: [.real(cutoff.timeIntervalSince1970)])
    }
}
