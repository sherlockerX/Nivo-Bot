import Foundation

/// 环境变量的可重放文件协议。秘密暂存于Keychain，日志仅保留元数据与操作标识。
struct NivoEnvVarTransaction: Sendable {
    enum Failure: Error { case pendingRecovery, invalidJournal, metadataChanged, missingCredentialStage }
    enum Phase: String, Codable, Sendable { case prepared, committed, awaitingSync }
    enum Checkpoint: Sendable { case journalSaved, credentialStaged, secretApplied, metadataSaved, commitRecorded }

    struct Change: Codable, Equatable, Sendable {
        enum Operation: String, Codable, Sendable { case upsert, delete }
        let id: String
        let operation: Operation
    }

    /// 前后快照用于检测备份或外部写入；日志不能指定任意文件路径或Keychain服务。
    struct Journal: Codable, Equatable, Sendable {
        var schema = 1
        var identifier: UUID
        var phase: Phase
        var before: [EnvVarEntry]
        var after: [EnvVarEntry]
        var writeKey: String?
        var notifySync: Bool
        var createdAt: Date

        var cleanupKeys: [String] {
            let retained = Set(after.map(\.key))
            return before.map(\.key).filter { !retained.contains($0) }
        }

        var changes: [Change] {
            guard notifySync else { return [] }
            let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
            let retained = Set(after.map(\.id))
            return before.filter { !retained.contains($0.id) }.map { Change(id: $0.id, operation: .delete) }
                + after.filter { old[$0.id] != $0 }.map { Change(id: $0.id, operation: .upsert) }
        }

        /// 单次操作只改一个变量，凭证目标必须属于该变量的候选元数据。
        func validate() throws {
            guard schema == 1, createdAt.timeIntervalSince1970.isFinite else { throw Failure.invalidJournal }
            try NivoEnvVarState.validate(before)
            try NivoEnvVarState.validate(after)
            let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
            let new = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
            let changed = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
            let isSecretFill = changed.isEmpty && writeKey != nil && !notifySync
            guard changed.count == 1 || isSecretFill, cleanupKeys.count <= 1 else { throw Failure.invalidJournal }
            if let writeKey {
                guard after.contains(where: { $0.key == writeKey && (isSecretFill || changed.contains($0.id)) }) else {
                    throw Failure.invalidJournal
                }
            }
        }
    }

    /// 系统适配器负责严格读回、幂等写入和清理；任一错误都保留恢复日志。
    struct Credentials {
        var contains: (UUID) throws -> Bool
        var apply: (Journal) throws -> Void
        var cleanup: (Journal) throws -> Void
        var discard: (UUID) throws -> Void
    }

    let fileURL: URL
    var journalURL: URL { fileURL.appendingPathExtension("transaction") }

    /// 缺失与损坏分开处理，无法读取的日志不能被新操作覆盖。
    func pending() throws -> Journal? {
        let data: Data
        do { data = try Data(contentsOf: journalURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard data.count <= 33_554_432 else { throw Failure.invalidJournal }
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        try journal.validate()
        return journal
    }

    /// 文件同步读取与备份必须先确认不存在未完成的跨存储变更。
    func requireSettled() throws {
        guard try pending() == nil else { throw Failure.pendingRecovery }
    }

    /// 日志先落盘，然后才能暂存秘密；完成返回的回执仍须等待同步队列持久化。
    func run(after: [EnvVarEntry], writeKey: String?, notifySync: Bool,
             prepare: (Journal) throws -> Void, using credentials: Credentials,
             checkpoint: (Checkpoint) throws -> Void = { _ in }) throws -> Journal? {
        try requireSettled()
        let journal = Journal(identifier: UUID(), phase: .prepared, before: try NivoEnvVarState.read(fileURL),
            after: after, writeKey: writeKey, notifySync: notifySync, createdAt: Date())
        try save(journal)
        try checkpoint(.journalSaved)
        try prepare(journal)
        try checkpoint(.credentialStaged)
        return try advance(journal, using: credentials, checkpoint: checkpoint)
    }

    /// Keychain暂存尚未产生时安全撤销；正式值已写入时从日志重放剩余步骤。
    func recover(using credentials: Credentials) throws -> Journal? {
        guard let journal = try pending() else { return nil }
        if journal.phase == .prepared, try !credentials.contains(journal.identifier) {
            guard try NivoEnvVarState.read(fileURL) == journal.before else { throw Failure.metadataChanged }
            try FileManager.default.removeItem(at: journalURL)
            return nil
        }
        return try advance(journal, using: credentials, checkpoint: { _ in })
    }

    /// 只有同步队列确认成功才能删回执，迟到回调不能清掉另一笔变更。
    func finish(identifier: UUID) throws {
        guard let journal = try pending(), journal.identifier == identifier,
              journal.phase == .awaitingSync else { throw Failure.invalidJournal }
        guard try NivoEnvVarState.read(fileURL) == journal.after else { throw Failure.metadataChanged }
        try FileManager.default.removeItem(at: journalURL)
    }

    private func advance(_ original: Journal, using credentials: Credentials,
                         checkpoint: (Checkpoint) throws -> Void) throws -> Journal? {
        var journal = original
        let current = try NivoEnvVarState.read(fileURL)
        guard current == journal.after || (journal.phase == .prepared && current == journal.before) else {
            throw Failure.metadataChanged
        }
        if journal.phase != .awaitingSync {
            guard try credentials.contains(journal.identifier) else { throw Failure.missingCredentialStage }
        }
        if journal.phase == .prepared {
            try credentials.apply(journal)
            try checkpoint(.secretApplied)
            if current != journal.after { try NivoEnvVarState.save(journal.after, to: fileURL) }
            try checkpoint(.metadataSaved)
            journal.phase = .committed
            try save(journal)
            try checkpoint(.commitRecorded)
        }
        if journal.phase == .committed {
            try credentials.cleanup(journal)
            journal.phase = .awaitingSync
            try save(journal)
        }
        try credentials.discard(journal.identifier)
        if journal.changes.isEmpty { try finish(identifier: journal.identifier); return nil }
        return journal
    }

    private func save(_ journal: Journal) throws {
        try journal.validate()
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 33_554_432 else { throw Failure.invalidJournal }
        try data.write(to: journalURL, options: .atomic)
    }
}
