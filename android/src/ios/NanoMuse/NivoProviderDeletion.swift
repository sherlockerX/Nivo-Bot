import Foundation

/// 提供商删除的持久意图，只记录标识和版本，凭证清理材料由系统适配器保管。
struct NivoProviderDeletion: Sendable {
    enum Failure: Error { case invalidJournal, pendingRecovery, missingStage }
    enum Phase: String, Codable, Sendable { case prepared, staged, committed, synchronized, cleaned }

    struct Plan: Codable, Equatable, Sendable {
        var instanceID: String
        var entryIDs: [String]
        var entryUUIDs: [String] = []
        var groupIDs: [String]
        var updatedGroupIDs: [String]
        var ruleIDs: [String]
        var deletedAt: Date
        // 缺失此字段的旧日志仍表示删除整个提供商，独立清理必须显式列出范围。
        var credentialAccounts: [String]? = nil

        var isCredentialOnly: Bool { credentialAccounts != nil }
        var selectedCredentialAccounts: [String] { credentialAccounts ?? NivoCredentialDeletion.accounts }
    }

    struct Journal: Codable, Equatable, Sendable {
        var schema = 1
        var identifier: UUID
        var phase: Phase
        var plan: Plan
        var credentialOutcome: NivoCredentialDeletion.Outcome? = nil

        /// 日志只允许有界标识集合，损坏或未知格式不会进入系统删除适配器。
        func validate() throws {
            guard schema == 1, plan.deletedAt.timeIntervalSince1970.isFinite,
                  Self.validID(plan.instanceID) else { throw Failure.invalidJournal }
            for identifiers in [plan.entryIDs, plan.entryUUIDs, plan.groupIDs, plan.updatedGroupIDs, plan.ruleIDs] {
                guard identifiers.count <= 100_000, identifiers.allSatisfy(Self.validID),
                      Set(identifiers).count == identifiers.count else { throw Failure.invalidJournal }
            }
            guard Set(plan.groupIDs).isDisjoint(with: plan.updatedGroupIDs) else { throw Failure.invalidJournal }
            if let accounts = plan.credentialAccounts {
                guard !accounts.isEmpty, Set(accounts).count == accounts.count,
                      accounts.allSatisfy(NivoCredentialDeletion.accounts.contains),
                      [plan.entryIDs, plan.entryUUIDs, plan.groupIDs, plan.updatedGroupIDs, plan.ruleIDs].allSatisfy(\.isEmpty)
                else { throw Failure.invalidJournal }
            }
            if let outcome = credentialOutcome {
                guard phase == .cleaned,
                      Set(outcome.preservedAccounts).count == outcome.preservedAccounts.count,
                      outcome.preservedAccounts.allSatisfy(plan.selectedCredentialAccounts.contains)
                else { throw Failure.invalidJournal }
            }
        }

        private static func validID(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 4096 && !value.contains("\0")
        }
    }

    /// 宿主串行冻结配置；每个步骤失败都必须传播给发起页面。
    @MainActor
    struct Operations {
        var prepare: (Journal) throws -> Void
        var containsStage: (UUID) throws -> Bool
        var persist: (Journal) async throws -> Void
        var synchronize: (Journal) async throws -> Void
        var cleanup: (Journal) throws -> Void
        var reload: () async throws -> Void
        var discard: (UUID) throws -> Void
        var cleanupOutcome: (Journal) throws -> NivoCredentialDeletion.Outcome = { _ in .init() }
        var settle: (Journal) throws -> Void = { _ in }
    }

    let journalURL: URL

    /// 读取恢复记录，损坏不能按没有记录处理。
    func pending() throws -> Journal? {
        let data: Data
        do { data = try Data(contentsOf: journalURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard data.count <= 33_554_432 else { throw Failure.invalidJournal }
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        try journal.validate()
        return journal
    }

    /// 先保存删除意图，再暂存凭证核对材料；尚未完成的操作不能被后来删除覆盖。
    @MainActor
    @discardableResult
    func run(_ plan: Plan, using operations: Operations) async throws -> NivoCredentialDeletion.Outcome {
        guard try pending() == nil else { throw Failure.pendingRecovery }
        let journal = Journal(identifier: UUID(), phase: .prepared, plan: plan)
        try save(journal)
        try operations.prepare(journal)
        return try await advance(journal, using: operations)
    }

    /// 持久删除的重放入口。
    @MainActor
    @discardableResult
    func recover(using operations: Operations) async throws -> NivoCredentialDeletion.Outcome {
        guard let journal = try pending() else { return .init() }
        if journal.phase == .prepared, try !operations.containsStage(journal.identifier) {
            // 暂存未创建时尚未提交配置，安全撤销这次未开始的删除。
            try FileManager.default.removeItem(at: journalURL)
            return .init()
        }
        return try await advance(journal, using: operations)
    }

    @MainActor
    private func advance(_ original: Journal, using operations: Operations) async throws -> NivoCredentialDeletion.Outcome {
        var journal = original
        if journal.phase != .cleaned {
            guard try operations.containsStage(journal.identifier) else { throw Failure.missingStage }
        }
        if journal.phase == .prepared {
            // 已确认暂存的阶段先落盘，之后缺少暂存不能按“删除尚未开始”撤销。
            journal.phase = .staged
            try save(journal)
        }
        if journal.phase == .staged {
            if !journal.plan.isCredentialOnly { try await operations.persist(journal) }
            journal.phase = .committed
            try save(journal)
        }
        if journal.phase == .committed {
            if !journal.plan.isCredentialOnly { try await operations.synchronize(journal) }
            journal.phase = .synchronized
            try save(journal)
        }
        if journal.phase == .synchronized {
            try operations.cleanup(journal)
            journal.credentialOutcome = try operations.cleanupOutcome(journal)
            journal.phase = .cleaned
            try save(journal)
        }
        // 缓存仍不可读时保留日志与重试入口，不能先解除写入屏障再报告失败。
        try await operations.reload()
        // 草稿登记等关联意图必须先确认终结，失败保留cleaned日志，重启不重新捕获新凭证。
        try operations.settle(journal)
        try operations.discard(journal.identifier)
        try FileManager.default.removeItem(at: journalURL)
        return journal.credentialOutcome ?? .init()
    }

    private func save(_ journal: Journal) throws {
        try journal.validate()
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 33_554_432 else { throw Failure.invalidJournal }
        try data.write(to: journalURL, options: .atomic)
    }
}
