import Foundation

/// 本机迁移的存储无关规则，系统适配器负责持锁和条件删除。
enum NivoLocalCredentialMigration {
    /// 只迁移本App的API、OAuth和环境变量。
    static func includes(service: String, account: String) -> Bool {
        guard !account.isEmpty, account.utf8.count <= 512, !account.contains("\0") else { return false }
        if service == "io.github.nanomuse.app.envvar" { return true }
        let prefix = "io.github.nanomuse.app.provider."
        guard service.hasPrefix(prefix), service.count > prefix.count,
              service.utf8.count <= prefix.utf8.count + 512, !service.contains("\0") else { return false }
        return ["api-key", "oauth-token", "manual-oauth-token", "oauth-email", "oauth-gcp-project", "oauth-base-url"].contains(account)
    }

    /// 迁移时先确认本机副本，再按来源快照移除同步条目。
    static func migrate<Value: Equatable>(readCloud: () throws -> Value?, readLocal: () throws -> Value?,
        insertLocal: (Value) throws -> Void, removeCloud: (Value) throws -> Void) throws {
        guard let source = try readCloud() else { return }
        let local = try readLocal()
        if local == nil { try insertLocal(source) }
        let expectedLocal = local ?? source
        guard try readLocal() == expectedLocal, try readCloud() == source else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try removeCloud(source)
        guard try readCloud() == nil, try readLocal() == expectedLocal else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
