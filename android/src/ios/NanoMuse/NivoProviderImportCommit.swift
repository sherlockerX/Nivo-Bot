import Foundation

/// 单提供商导入的提交边界，复用应用备份日志，失败恢复全部配置和本次插入凭证。
@MainActor
enum NivoProviderImportCommit {
    /// 日志尚在则失败必须回滚；日志已删除仅快照清理失败时，导入已经提交。
    static func run(writeCredentials: @MainActor () throws -> Void,
                    persist: @MainActor () async throws -> Void,
                    synchronize: @MainActor () async throws -> Void = {},
                    finish: @MainActor () throws -> Void,
                    isPending: @MainActor () -> Bool,
                    rollback: @MainActor () async throws -> Void) async throws {
        guard isPending() else { throw CocoaError(.fileReadCorruptFile) }
        var isFinishing = false
        do {
            try Task.checkCancellation()
            try writeCredentials()
            try await persist()
            try Task.checkCancellation()
            try await synchronize()
            try Task.checkCancellation()
            isFinishing = true
            try finish()
        } catch {
            if isFinishing && !isPending() { return }
            let original = error
            // 回滚失败保留日志与快照，不用原始错误掩盖恢复尚未结束的事实。
            try await rollback()
            try finish()
            throw original
        }
    }
}
