import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 账户隔离的教练仓库，全部命令在一个actor中校验、归约并原子落盘。
actor NivoCoachV2Store {
    typealias Writer = @Sendable (Data, URL) throws -> Void
    typealias Clock = @Sendable () -> Int64
    private let directory: URL
    private let writer: Writer
    private let clock: Clock
    private var ownerKey: String?
    private var state: NivoCoachState?
    private var generation = UUID()
    private var backupToken: UUID?

    /// 注入磁盘和时钟以覆盖写入失败、跨账户及延迟复核边界。
    init(directory: URL, writer: @escaping Writer = { data, url in try data.write(to: url, options: .atomic) },
         clock: @escaping Clock = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.directory = directory
        self.writer = writer
        self.clock = clock
    }

    /// 损坏文件不被空状态覆盖，初始快照也必须先落盘再可见。
    func open(ownerKey: String) throws {
        guard backupToken == nil else { throw NivoPersonalBackupError.busy }
        if self.ownerKey == ownerKey, state != nil { return }
        close()
        self.ownerKey = ownerKey
        let url = fileURL(ownerKey)
        let seeds = try NivoCoachCurriculum.seededTracks()
        if FileManager.default.fileExists(atPath: url.path) {
            let decoded = try JSONDecoder().decode(NivoCoachState.self, from: Data(contentsOf: url))
            try Self.validate(decoded)
            let migrated = try NivoCoachCurriculum.migrate(decoded, seeds: seeds)
            if migrated != decoded { try commit(migrated) }
            else { state = decoded }
        } else {
            var initial = NivoCoachState()
            initial.tracks = seeds
            try commit(initial)
        }
    }

    /// 页面重试只允许重开宿主已经绑定的账户，迟到的重试不能切换仓库归属。
    func retryOpen(ownerKey expectedOwner: String) throws {
        guard ownerKey == expectedOwner else { throw NivoLifeError.accountChanged }
        try open(ownerKey: expectedOwner)
    }

    /// 撤销代次，退出后再次登录同一账号也不能复活旧请求。
    func close() {
        guard backupToken == nil else { return }
        ownerKey = nil; state = nil; generation = UUID()
    }

    /// 宿主在启动异步工作前捕获代次，不能由模型参数提供。
    func access(ownerKey expectedOwner: String) throws -> UUID {
        _ = try snapshot(ownerKey: expectedOwner)
        return generation
    }

    /// 返回一致的值快照，调用方不会持有仓库可变状态。
    func snapshot() throws -> NivoCoachState {
        guard backupToken == nil, ownerKey != nil, let state else { throw NivoLifeError.accountChanged }
        return state
    }

    /// 每次读取再次核对进入时捕获的账户。
    func snapshot(ownerKey expectedOwner: String) throws -> NivoCoachState {
        guard ownerKey == expectedOwner else { throw NivoLifeError.accountChanged }
        return try snapshot()
    }

    /// 精确重试先回放原始回执；新操作必须匹配当前版本，最终只写一次文件。
    func execute(_ command: NivoCoachCommand, context: NivoCoachCommandContext) throws -> NivoCoachCommandResult {
        try requireAccess(ownerKey: context.ownerKey, generation: context.generation)
        let original = try snapshot()
        try NivoTodoRules.validateOperationID(command.operationID)
        try NivoCoachPolicy.authorize(command, context: context, state: original)
        if let stored = original.operations[command.operationID] { return try replay(stored, command: command, context: context) }
        try NivoTodoRules.requireRevision(command.expectedRevision, actual: original.revision)
        var candidate = original
        let applied = try NivoCoachReducer.apply(command, context: context, state: &candidate, now: clock())
        try requireRecoveredArchives(before: original, after: candidate, ownerKey: context.ownerKey)
        let result = NivoCoachCommandResult(revision: try NivoCoachReducer.increment(original.revision), targetID: applied.id, dataJSON: applied.data)
        let receipt = NivoCoachCommandReceipt(request: command, ownerKey: context.ownerKey,
            chatSessionID: context.chatSessionID, userMessageID: context.user?.id ?? "", isHost: context.isHost, result: result)
        candidate.operations[command.operationID] = String(decoding: try encode(receipt), as: UTF8.self)
        try commit(candidate)
        return result
    }

    /// 新课会改变迟到消息的课次校验，因此旧归档未处理完时整个候选事务必须回退。
    private func requireRecoveredArchives(before: NivoCoachState, after: NivoCoachState, ownerKey: String) throws {
        let existing = Set(before.sessions.map(\.id))
        let files = NivoCoachArchiveFiles(directory: directory, writer: writer)
        for lesson in after.sessions where !existing.contains(lesson.id) && !lesson.chatSessionID.isEmpty {
            let pending = files.read(owner: ownerKey, chatID: lesson.chatSessionID)
            guard pending.failures.isEmpty else { throw NivoLifeError.corruptStore }
            guard pending.entries.isEmpty else { throw NivoLifeError.invalidTransition("pending_archive") }
        }
    }

    private func replay(_ stored: String, command: NivoCoachCommand, context: NivoCoachCommandContext) throws -> NivoCoachCommandResult {
        let receipt = try JSONDecoder().decode(NivoCoachCommandReceipt.self, from: Data(stored.utf8))
        guard receipt.request == command, receipt.ownerKey == context.ownerKey,
              receipt.chatSessionID == context.chatSessionID, receipt.isHost == context.isHost,
              receipt.userMessageID == (context.user?.id ?? "") else { throw NivoLifeError.operationConflict }
        var result = receipt.result
        result.isReplaySnapshot = true
        return result
    }

    /// 宿主绑定单独入口，不允许模型自报聊天ID来改变授权范围。
    func bindTopicConversation(topicID: String, chatSessionID: String, ownerKey: String, generation: UUID) throws {
        try hostMutation(ownerKey: ownerKey, generation: generation) {
            try NivoCoachHostRules.bind(topicID: topicID, chatSessionID: chatSessionID, state: &$0)
        }
    }

    /// 删除聊天归档专题并撤销证据，旧链接不会重新建出同一个专题聊天。
    func invalidateConversation(chatSessionID: String, reason: String, ownerKey: String, generation: UUID) throws {
        try hostMutation(ownerKey: ownerKey, generation: generation) {
            try NivoCoachHostRules.invalidateConversation(chatSessionID: chatSessionID, reason: reason, state: &$0)
        }
    }

    /// 编辑或删除消息保留历史摘录，但撤销依赖原话、题目或摘要的证据。
    func invalidateSourceMessages(chatSessionID: String, messageIDs: Set<String>, ownerKey: String, generation: UUID) throws {
        try hostMutation(ownerKey: ownerKey, generation: generation) {
            try NivoCoachHostRules.invalidateMessages(chatSessionID: chatSessionID, messageIDs: messageIDs, state: &$0)
        }
    }

    /// 已落盘用户回合由宿主自动归档，结束后的追问仍留在上一节课。
    func registerConversationUser(_ user: NivoSavedUserTurn, expectedSessionID: String?, generation: UUID) throws {
        let now = clock()
        try hostMutation(ownerKey: user.ownerKey, generation: generation) {
            try NivoCoachHostRules.registerUser(user, expectedSessionID: expectedSessionID, state: &$0, now: now)
        }
    }

    /// 最终可见正文落盘后才允许给验证题补绑消息ID。
    func recordConversationReply(chatSessionID: String, messageID: String, text: String, expectedSessionID: String?,
                                 ownerKey: String, generation: UUID, sourceDigest: String? = nil, sourceCreatedAt: Int64? = nil) throws {
        let now = sourceCreatedAt ?? clock()
        try hostMutation(ownerKey: ownerKey, generation: generation) {
            try NivoCoachHostRules.recordReply(chatSessionID: chatSessionID, messageID: messageID, text: text,
                expectedSessionID: expectedSessionID, state: &$0, now: now, sourceDigest: sourceDigest)
        }
    }

    /// 聊天入库前先暂存归档意图，故障重启后仍能找到首次课次与来源签名。
    @discardableResult
    func stageArchive(_ entry: NivoCoachArchiveEntry, generation: UUID) throws -> NivoCoachArchiveEntry {
        try requireAccess(ownerKey: entry.ownerKey, generation: generation)
        let snapshot = try snapshot()
        guard snapshot.sessions.contains(where: { $0.id == entry.lessonID && $0.chatSessionID == entry.chatID }) else {
            throw NivoLifeError.invalidField("coach_archive_lesson")
        }
        return try NivoCoachArchiveFiles(directory: directory, writer: writer).put(entry)
    }

    /// 恢复读取仍要求当前账户代次，不能借助队列读取已经切走的账户。
    func pendingArchives(chatSessionID: String, ownerKey: String, generation: UUID) throws -> NivoCoachArchiveRead {
        try requireAccess(ownerKey: ownerKey, generation: generation)
        return NivoCoachArchiveFiles(directory: directory, writer: writer).read(owner: ownerKey, chatID: chatSessionID)
    }

    /// 正文已核验且归档提交后才清理暂存；清理失败可再次幂等归档。
    func finishArchive(_ entry: NivoCoachArchiveEntry, generation: UUID) throws {
        try requireAccess(ownerKey: entry.ownerKey, generation: generation)
        try NivoCoachArchiveFiles(directory: directory, writer: writer).remove(entry)
    }

    /// 从当前一致快照计算专题成长。
    func progress(topicID: String) throws -> NivoCoachTopicProgress { NivoCoachTeaching.progress(try snapshot(), topicID: topicID) }

    /// 账户删除只触及该账户的哈希目录。
    func removeAccount(ownerKey: String) throws {
        guard backupToken == nil else { throw NivoPersonalBackupError.busy }
        if self.ownerKey == ownerKey { close() }
        let folder = fileURL(ownerKey).deletingLastPathComponent()
        guard folder.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().pathComponents == directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents else {
            throw NivoLifeError.invalidField("account_path")
        }
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }

    /// 快照与待整理队列一起冻结，不能在正文写入中途导出半条训练记录。
    func beginBackup(ownerKey: String, token: UUID) throws -> (state: NivoCoachState, archives: [NivoCoachArchiveEntry]) {
        guard backupToken == nil else { throw NivoPersonalBackupError.busy }
        let snapshot = try snapshot(ownerKey: ownerKey)
        let files = NivoCoachArchiveFiles(directory: directory, writer: writer)
        var archives: [NivoCoachArchiveEntry] = []
        for chatID in Set(snapshot.topics.map(\.chatSessionID).filter { !$0.isEmpty }) {
            let pending = files.read(owner: ownerKey, chatID: chatID)
            guard pending.failures.isEmpty else { throw NivoLifeError.corruptStore }
            archives.append(contentsOf: pending.entries)
        }
        backupToken = token
        generation = UUID()
        return (snapshot, archives)
    }

    /// 在租约内写入已验证合并结果，归档队列保留首次来源冲突规则。
    func installBackup(_ candidate: NivoCoachState, archives: [NivoCoachArchiveEntry], token: UUID) throws {
        guard backupToken == token, let ownerKey else { throw NivoLifeError.accountChanged }
        try Self.validate(candidate)
        try commit(candidate)
        let files = NivoCoachArchiveFiles(directory: directory, writer: writer)
        for entry in archives {
            guard entry.ownerKey == ownerKey,
                  candidate.sessions.contains(where: { $0.id == entry.lessonID && $0.chatSessionID == entry.chatID }) else {
                throw NivoPersonalBackupError.invalidPackage
            }
            try files.put(entry)
        }
    }

    /// 恢复后只从磁盘重建，回滚也使用同一个重载入口。
    func endBackup(token: UUID) {
        guard backupToken == token else { return }
        backupToken = nil
        close()
    }

    private func hostMutation(ownerKey: String, generation: UUID, change: (inout NivoCoachState) throws -> Void) throws {
        try requireAccess(ownerKey: ownerKey, generation: generation)
        let original = try snapshot()
        var candidate = original
        try change(&candidate)
        if candidate != original { try commit(candidate) }
    }

    private func requireAccess(ownerKey: String, generation: UUID) throws {
        guard backupToken == nil, self.ownerKey == ownerKey, self.generation == generation, state != nil else { throw NivoLifeError.accountChanged }
    }

    private func commit(_ next: NivoCoachState) throws {
        guard let ownerKey else { throw NivoLifeError.accountChanged }
        var committed = next
        committed.revision = try NivoCoachReducer.increment(next.revision)
        refreshProgress(&committed)
        try Self.validate(committed)
        let url = fileURL(ownerKey)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer(encode(committed), url)
        state = committed
    }

    private func refreshProgress(_ state: inout NivoCoachState) {
        let projection = state
        for index in state.tracks.indices {
            let related = projection.topics.filter { $0.courseID == projection.tracks[index].id }
            let controlled = Set(related.map(\.unitID))
            let achieved = related.filter { NivoCoachTeaching.progress(projection, topicID: $0.id).isDemonstrated }
            state.tracks[index].demonstrated.subtract(controlled)
            state.tracks[index].demonstrated.formUnion(achieved.map(\.unitID))
        }
    }

    static func validate(_ state: NivoCoachState) throws {
        guard state.schemaVersion == 3 else { throw NivoLifeError.unsupportedVersion(state.schemaVersion) }
        guard state.revision >= 0,
              unique(state.tracks.map(\.id)), unique(state.sessions.map(\.id)), unique(state.topics.map(\.id)),
              unique(state.drafts.map(\.id)), unique(state.actions.map(\.id)),
              unique(state.topics.map(\.chatSessionID).filter { !$0.isEmpty }) else { throw NivoLifeError.corruptStore }
        for track in state.tracks {
            guard !track.course.version.isEmpty, unique(track.course.units.map(\.id)),
                  track.course.units.contains(where: { $0.id == track.currentUnitID }) else { throw NivoLifeError.corruptStore }
        }
        for session in state.sessions {
            guard session.revision >= 0, unique(session.turns.map(\.id)),
                  state.tracks.contains(where: { $0.id == session.course.id }),
                  session.course.units.contains(where: { $0.id == session.unitID }) else { throw NivoLifeError.corruptStore }
        }
        for action in state.actions where !state.sessions.contains(where: { $0.id == action.sessionID }) { throw NivoLifeError.corruptStore }
    }

    private static func unique(_ values: [String]) -> Bool { !values.contains("") && Set(values).count == values.count }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func fileURL(_ ownerKey: String) -> URL {
        let digest = SHA256.hash(data: Data(ownerKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest, isDirectory: true).appendingPathComponent("state.json")
    }
}
