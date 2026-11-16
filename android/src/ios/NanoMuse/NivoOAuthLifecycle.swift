import Foundation

/// OAuth请求绑定账户与提供商恢复代次，往返后不能借用另一次登录的身份。
struct NivoOAuthScope: Equatable, Sendable {
    let ownerKey: String
    let accountGeneration: UInt64
    let providerGeneration: UInt64
}

/// 登录、刷新和资料发现共用的操作身份，不含任何凭证或秘密摘要。
struct NivoOAuthOperation: Equatable, Sendable {
    let instanceID: String
    let generation: UUID
    let scope: NivoOAuthScope
}

/// 每个实例独立撤销；校验与同步凭证写入都在主线程，之间不能插入await。
@MainActor
final class NivoOAuthLifecycle {
    private var operations: [String: NivoOAuthOperation] = [:]
    private var loginGenerations: [String: UUID] = [:]
    private var cancellations: [String: (generation: UUID, action: () -> Void)] = [:]

    /// 新登录替代旧刷新；同代刷新共享身份，账户或恢复变化自动产生新身份。
    func begin(instanceID: String, scope: NivoOAuthScope, replacing: Bool = false) throws -> NivoOAuthOperation {
        try Task.checkCancellation()
        if !replacing, let current = operations[instanceID], current.scope == scope {
            // 新登录尚未提交时，旧存储仍可能可读；不能借新代次刷新旧账户。
            guard loginGenerations[instanceID] == nil else { throw CancellationError() }
            return current
        }
        invalidate(instanceID: instanceID)
        let operation = NivoOAuthOperation(instanceID: instanceID, generation: UUID(), scope: scope)
        operations[instanceID] = operation
        if replacing { loginGenerations[instanceID] = operation.generation }
        return operation
    }

    /// 已取消、已退出或跨账户的结果连错误回退也不能继续执行。
    func validate(_ operation: NivoOAuthOperation, scope: NivoOAuthScope) throws {
        try Task.checkCancellation()
        guard operations[operation.instanceID] == operation, operation.scope == scope else {
            throw CancellationError()
        }
    }

    /// 浏览器回调等待也要随操作结束，防止返回页面后继续长时间占用登录状态。
    func registerCancellation(_ operation: NivoOAuthOperation, action: @escaping () -> Void) throws {
        try validate(operation, scope: operation.scope)
        cancellations[operation.instanceID] = (operation.generation, action)
    }

    /// 旧请求的收尾不能取消或移除后续登录；成功凭证的代次继续用于刷新。
    func finish(_ operation: NivoOAuthOperation) {
        if loginGenerations[operation.instanceID] == operation.generation {
            loginGenerations[operation.instanceID] = nil
        }
        if cancellations[operation.instanceID]?.generation == operation.generation {
            cancellations[operation.instanceID] = nil
        }
    }

    /// 放弃表单、退出、删除实例时先作废结果，再清理浏览器和凭证。
    func invalidate(instanceID: String) {
        operations[instanceID] = nil
        loginGenerations[instanceID] = nil
        let cancellation = cancellations.removeValue(forKey: instanceID)
        cancellation?.action()
    }

    /// 延后执行的取消只针对原操作，不能撤销已经重新开始的登录。
    func invalidate(_ operation: NivoOAuthOperation) {
        guard operations[operation.instanceID] == operation else { return }
        invalidate(instanceID: operation.instanceID)
    }

    /// 账户切换或恢复开始时主动释放回调等待，不等旧网络超时。
    func invalidateAll() {
        operations.removeAll()
        loginGenerations.removeAll()
        let actions = cancellations.values.map(\.action)
        cancellations.removeAll()
        for action in actions { action() }
    }
}
