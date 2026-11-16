import Foundation

// nanoMuse: 凭证恢复先准备无正文的回滚收据，日志落盘后再执行可验证的插入。
/// 沿用备份凭证格式和已有Keychain服务，读取、解码及写入失败全部交给导入器处理。
enum BackupSecretsImporter {
    struct Result {
        var providersRestored = 0
        var providersSkippedExisting = 0
        var envVarsRestored = 0
        var envVarsSkippedExisting = 0
        var mcpOAuthRestored = 0
        var mcpOAuthSkippedExisting = 0
        var total: Int { providersRestored + envVarsRestored + mcpOAuthRestored }
    }

    /// 分享副本没有secrets.json是正常情况；文件存在但不可读或内容错误必须报错。
    @MainActor
    static func prepare(from root: URL) throws -> NivoCredentialRestore.Plan? {
        let url = root.appendingPathComponent("secrets.json")
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
        guard data.count <= 16 * 1_024 * 1_024 else { throw NivoCredentialRestoreError.invalidValue }
        let secrets = try JSONDecoder().decode(BackupSecrets.self, from: data)
        guard secrets.v == 1 else { throw NivoCredentialRestoreError.invalidValue }
        let items = try providerItems(secrets.providers) + environmentItems(secrets.envVars) + mcpItems(secrets.mcpOAuth)
        return try NivoCredentialRestore.prepare(items)
    }

    /// 只统计Keychain回读验证成功的插入；部分失败由外层统一回滚，不返回成功计数。
    static func restore(_ plan: NivoCredentialRestore.Plan) throws -> Result {
        let outcome = try NivoCredentialRestore.apply(plan)
        var result = Result()
        result.providersRestored = owners(outcome.inserted.filter { $0.kind.isProvider }).count
        result.providersSkippedExisting = owners(outcome.kept.filter { $0.kind.isProvider }).count
        result.envVarsRestored = outcome.inserted.filter { $0.kind == .environment }.count
        result.envVarsSkippedExisting = outcome.kept.filter { $0.kind == .environment }.count
        result.mcpOAuthRestored = owners(outcome.inserted.filter { $0.kind == .mcpTokens || $0.kind == .mcpClientSecret }).count
        result.mcpOAuthSkippedExisting = owners(outcome.kept.filter { $0.kind == .mcpTokens || $0.kind == .mcpClientSecret }).count
        return result
    }

    private static func owners(_ targets: [NivoCredentialRestoreReceipt.Target]) -> Set<String> { Set(targets.map(\.owner)) }

    private static func providerItems(_ providers: [BackupSecrets.ProviderSecret]) throws -> [NivoCredentialRestore.Item] {
        var result: [NivoCredentialRestore.Item] = []
        for provider in providers {
            let fields: [(NivoCredentialRestoreReceipt.Kind, String?)] = [
                (.providerAPIKey, provider.apiKey), (.providerManualToken, provider.manualOAuthToken),
                (.providerEmail, provider.oauthEmail), (.providerProject, provider.oauthGcpProject),
                (.providerOAuthToken, provider.oauthToken)
            ]
            for (kind, encoded) in fields {
                guard let encoded else { continue }
                let data = try decode(encoded, isText: kind != .providerOAuthToken)
                if kind == .providerOAuthToken { _ = try JSONSerialization.jsonObject(with: data) }
                result.append(.init(target: .init(kind: kind, owner: provider.instanceId), data: data))
            }
        }
        return result
    }

    private static func environmentItems(_ variables: [BackupSecrets.EnvVarSecret]) throws -> [NivoCredentialRestore.Item] {
        try variables.map { .init(target: .init(kind: .environment, owner: $0.name), data: try decode($0.value, isText: true)) }
    }

    @MainActor
    private static func mcpItems(_ servers: [BackupSecrets.MCPOAuthSecret]) throws -> [NivoCredentialRestore.Item] {
        var result: [NivoCredentialRestore.Item] = []
        for server in servers {
            let token = try decode(server.token, isText: false)
            _ = try JSONDecoder().decode(MCPOAuthController.StoredTokens.self, from: token)
            result.append(.init(target: .init(kind: .mcpTokens, owner: server.serverId), data: token))
            if let secret = server.clientSecret {
                result.append(.init(target: .init(kind: .mcpClientSecret, owner: server.serverId), data: try decode(secret, isText: true)))
            }
        }
        return result
    }

    private static func decode(_ encoded: String, isText: Bool) throws -> Data {
        guard let data = Data(base64Encoded: encoded), !isText || String(data: data, encoding: .utf8) != nil else {
            throw NivoCredentialRestoreError.invalidValue
        }
        return data
    }
}
