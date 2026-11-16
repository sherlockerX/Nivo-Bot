import Foundation

/// 将可移植OAuth生命周期接入应用真实账户和提供商恢复门禁。
@MainActor
enum NivoOAuthAccess {
    private static let lifecycle = NivoOAuthLifecycle()

    private static var scope: NivoOAuthScope {
        NivoOAuthScope(ownerKey: NanoMuseAccountData.shared.current,
            accountGeneration: NanoMuseAccountData.shared.generation,
            providerGeneration: ProviderConfigStore.shared.nmRestoreGeneration)
    }

    /// 表单只捕获一次来源，完成授权后停留的旧页面也不能向恢复后的账户保存。
    static func captureScope() -> NivoOAuthScope { scope }

    /// 同步表单写入前核对显示时的身份，避免旧输入被加入另一个账户。
    static func validateScope(_ expected: NivoOAuthScope) throws {
        try requireAvailable()
        guard expected == scope else { throw CancellationError() }
    }

    /// 新建实例尚未安装也允许授权，但必须属于当前可用的账户与配置代次。
    static func begin(instanceID: String, replacing: Bool = false) throws -> NivoOAuthOperation {
        try requireAvailable()
        return try lifecycle.begin(instanceID: instanceID, scope: scope, replacing: replacing)
    }

    /// 每次网络返回后、写Keychain或采用刷新回退前调用，不能跨await复用校验结果。
    static func validate(_ operation: NivoOAuthOperation) throws {
        try requireAvailable()
        try lifecycle.validate(operation, scope: scope)
    }

    /// 刷新期间同步或手动编辑可能改变Keychain；成功响应也必须保留后来已变更的凭证。
    static func validateCurrentCredential<Token: Codable & RefreshableOAuthToken>(
        _ expected: Token, operation: NivoOAuthOperation
    ) throws {
        try validate(operation)
        let current = try ProviderKeychainHelper.loadOAuthTokenStrict(instanceId: operation.instanceID, as: Token.self)
        try NivoOAuthPersistence.requireUnchanged(accessToken: expected.accessToken, refreshToken: expected.refreshToken,
            currentAccessToken: current?.accessToken, currentRefreshToken: current?.refreshToken)
    }

    /// 只登记本次登录自己的回调服务器，避免旧清理操作关闭新登录。
    static func registerCancellation(_ operation: NivoOAuthOperation, action: @escaping () -> Void) throws {
        try validate(operation)
        try lifecycle.registerCancellation(operation, action: action)
    }

    /// 成功或失败后结束浏览器等待登记，不撤销已经提交的凭证。
    static func finish(_ operation: NivoOAuthOperation) { lifecycle.finish(operation) }

    /// 撤销旧实例的异步写入权限，不替代Keychain删除确认。
    static func invalidate(instanceID: String) { lifecycle.invalidate(instanceID: instanceID) }

    /// Task取消回调可能延后到新登录开始之后，必须限定原操作身份。
    static func invalidate(_ operation: NivoOAuthOperation) { lifecycle.invalidate(operation) }

    /// 恢复和身份切换同步调用，旧回调即使不响应网络取消也无法保存。
    static func invalidateAll() { lifecycle.invalidateAll() }

    private static func requireAvailable() throws {
        try Task.checkCancellation()
        guard NanoMuseAccountData.shared.isReady, !NanoMuseAccountData.shared.isChangingAccount,
              !NivoPersonalBackupAccess.isBusy, !NivoPersonalBackupAccess.hasAccountTransition,
              !BackupRestoreJournal.hasPendingRecovery,
              ProviderConfigStore.shared.nmCanUseProviderCredentials else { throw CancellationError() }
    }
}
