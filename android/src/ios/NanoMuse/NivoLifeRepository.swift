import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 串行账户仓库，所有关联数据在一次原子替换中提交，落盘失败不发布新状态。
actor NivoLifeRepository {
    typealias Writer = @Sendable (Data, URL) throws -> Void
    private let directory: URL
    private let writer: Writer
    private var scope: NivoLifeScope?
    private var state: NivoLifeState?
    private var pendingSettlement: NivoLifeState?
    private var generation: UInt64 = 0
    private var backupToken: UUID?

    /// 写入器可注入磁盘故障，生产默认使用Foundation原子文件替换。
    init(directory: URL, writer: @escaping Writer = { data, url in
        try data.write(to: url, options: .atomic)
    }) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.writer = writer
    }

    /// 切换身份先作废旧凭证，暂停旧账号计时后再载入新账号。
    func open(ownerKey: String, clock: NivoFocusClockSample) throws -> NivoLifeScope {
        guard backupToken == nil else { throw NivoPersonalBackupError.busy }
        if let scope, scope.ownerKey == ownerKey { return scope }
        generation &+= 1
        scope = nil
        if let pendingSettlement {
            try persist(pendingSettlement)
            self.pendingSettlement = nil
        }
        if var previous = state {
            if let index = previous.focusSessions.firstIndex(where: { $0.isActive && $0.status == .running }) {
                try settleFocus(at: index, state: &previous, clock: clock)
                try persistSettlement(previous)
            }
        }
        state = nil
        let path = fileURL(ownerKey: ownerKey)
        let loaded: NivoLifeState
        if FileManager.default.fileExists(atPath: path.path) {
            loaded = try decodeStore(Data(contentsOf: path), ownerKey: ownerKey)
        } else {
            loaded = NivoLifeState(ownerKey: ownerKey)
        }
        let selected = NivoLifeScope(ownerKey: ownerKey, generation: generation)
        state = loaded
        scope = selected
        return selected
    }

    /// 撤销所有旧页面凭证；退出账号时必须等待这个边界。
    func close(clock: NivoFocusClockSample) throws {
        guard backupToken == nil else { throw NivoPersonalBackupError.busy }
        generation &+= 1
        scope = nil
        guard var previous = state else { return }
        if let index = previous.focusSessions.firstIndex(where: { $0.isActive && $0.status == .running }) {
            try settleFocus(at: index, state: &previous, clock: clock)
            try persistSettlement(previous)
        }
        state = nil
    }

    /// 删除账户只作用于其哈希目录；先撤销凭证，删除失败也不恢复旧页面的写入资格。
    func removeAccount(ownerKey: String) throws {
        guard backupToken == nil else { throw NivoPersonalBackupError.busy }
        if state?.ownerKey == ownerKey {
            generation &+= 1
            scope = nil
            state = nil
        }
        if pendingSettlement?.ownerKey == ownerKey { pendingSettlement = nil }
        let folder = fileURL(ownerKey: ownerKey).deletingLastPathComponent()
        let expectedParent = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard folder.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().pathComponents == expectedParent.pathComponents else {
            throw NivoLifeError.invalidField("account_path")
        }
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// 查询前结算到期或跨重启的会话，活动查询与详情使用同一份状态。
    func snapshot(scope requested: NivoLifeScope, clock: NivoFocusClockSample) throws -> NivoLifeState {
        var current = try requireState(requested)
        if try reconcileFocus(state: &current, clock: clock) {
            try commit(current, scope: requested)
            return try requireState(requested)
        }
        return current
    }

    /// 碎片查询复用账户代次检查，不另建可与待办错开的内存副本。
    func mosaicSnapshot(scope requested: NivoLifeScope) throws -> NivoMosaicState {
        let current = try requireState(requested)
        return current.mosaic ?? NivoMosaicState(ownerKey: requested.ownerKey)
    }

    /// 新快照已经存在时不再读取或解析旧文件，避免旧副本损坏阻止正常使用。
    func hasMosaic(scope requested: NivoLifeScope) throws -> Bool {
        try requireState(requested).mosaic != nil
    }

    /// 首次迁移旧碎片快照；新容器已有数据时绝不使用旧文件覆盖。
    func importMosaic(_ legacy: NivoMosaicState, scope requested: NivoLifeScope) throws {
        var current = try requireState(requested)
        guard current.mosaic == nil else { return }
        try NivoMosaicRules.validate(legacy, owner: requested.ownerKey)
        current.mosaic = legacy
        try commit(current, scope: requested)
    }

    /// 草稿与清理操作原地替换，不把每次自动保存的全文永久堆积在幂等回执中。
    func updateMosaic<Result>(scope requested: NivoLifeScope,
                             body: (inout NivoMosaicState) throws -> Result) throws -> Result {
        var current = try requireState(requested)
        var mosaic = current.mosaic ?? NivoMosaicState(ownerKey: requested.ownerKey)
        let result = try body(&mosaic)
        try NivoMosaicRules.validate(mosaic, owner: requested.ownerKey)
        current.mosaic = mosaic
        try commit(current, scope: requested)
        return result
    }

    /// 媒体和状态使用同一账户哈希；引用不存在的照片不能发布为已保存记录。
    func requireMosaicMedia(_ path: String?, owner: String) throws {
        guard let path else { return }
        try NivoMosaicRules.validateMediaPath(path)
        let file = directory.deletingLastPathComponent().appendingPathComponent("mosaic-media")
            .appendingPathComponent(NivoFocusPreferences.ownerHash(owner)).appendingPathComponent("images")
            .appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: file.path) else { throw NivoLifeError.invalidField("photo_missing") }
    }

    /// 固定顺序编码用于幂等比较，时间和随机ID仅在第一次执行时产生。
    func transaction<Request: Encodable, Result: Codable>(
        operationID: String, request: Request, scope requested: NivoLifeScope,
        body: (inout NivoLifeState) throws -> Result
    ) throws -> Result {
        try transactionResult(operationID: operationID, request: request, scope: requested, body: body).value
    }

    /// 保留原回执编码，额外返回本次是否命中回执；新旧持久化格式可互相读取。
    func transactionResult<Request: Encodable, Result: Codable>(
        operationID: String, request: Request, scope requested: NivoLifeScope,
        recordsTaskChanges: Bool = true,
        body: (inout NivoLifeState) throws -> Result
    ) throws -> NivoLifeTransactionResult<Result> {
        try NivoTodoRules.validateOperationID(operationID)
        var candidate = try requireState(requested)
        let encodedRequest = try encoder().encode(request)
        if let previous = candidate.operations[operationID] {
            guard previous.request == encodedRequest else { throw NivoLifeError.operationConflict }
            return NivoLifeTransactionResult(value: try JSONDecoder().decode(Result.self, from: previous.result), isReplay: true)
        }
        let previousTasks = candidate.tasks
        let result = try body(&candidate)
        if recordsTaskChanges {
            NivoTodoBackupHistory.recordingChanges(from: previousTasks, in: &candidate, operationID: operationID)
        }
        candidate.operations[operationID] = NivoLifeOperation(
            request: encodedRequest, result: try encoder().encode(result)
        )
        try commit(candidate, scope: requested)
        return NivoLifeTransactionResult(value: result, isReplay: false)
    }

    /// 自动结算只在到期或设备重启时写入，不跟随界面每秒刷新写盘。
    func reconcileFocus(state: inout NivoLifeState, clock: NivoFocusClockSample) throws -> Bool {
        guard let index = state.focusSessions.firstIndex(where: { $0.isActive && $0.status == .running }) else {
            return false
        }
        let session = state.focusSessions[index]
        guard session.bootID != clock.bootID ||
                NivoFocusRules.currentElapsed(session, clock: clock) >= session.targetMs else { return false }
        try settleFocus(at: index, state: &state, clock: clock)
        return true
    }

    /// 将一次计时边界和其区间同时更新到候选快照。
    func settleFocus(at index: Int, state: inout NivoLifeState, clock: NivoFocusClockSample) throws {
        let previous = state.focusSessions[index]
        let result = try NivoFocusRules.mutate(
            previous, action: "pause", expectedRevision: previous.revision,
            clock: clock, spanID: UUID().uuidString
        )
        state.focusSessions[index] = result.session
        if let span = result.span { state.focusSpans.append(span) }
    }

    /// 冻结生成独立的已计量备份副本，不暂停本机正在进行的计时。
    func beginBackup(scope requested: NivoLifeScope, token: UUID, clock: NivoFocusClockSample) throws -> NivoLifeState {
        guard backupToken == nil else { throw NivoPersonalBackupError.busy }
        var snapshot = try requireState(requested)
        if let index = snapshot.focusSessions.firstIndex(where: { $0.isActive && $0.status == .running }) {
            try settleFocus(at: index, state: &snapshot, clock: clock)
        }
        try NivoLifeValidation.validate(snapshot, owner: requested.ownerKey)
        backupToken = token
        generation &+= 1
        scope = nil
        return snapshot
    }

    /// 只允许租约持有者提交完整合并结果；正常写入凭证在恢复后全部失效。
    func backupLiveState(token: UUID) throws -> NivoLifeState {
        guard backupToken == token, let state else { throw NivoLifeError.accountChanged }
        return state
    }

    /// 合并保留本机运行状态，导出用的已结算副本不会覆盖正在计时的原件。
    func installBackup(_ candidate: NivoLifeState, token: UUID) throws {
        guard backupToken == token, state?.ownerKey == candidate.ownerKey else { throw NivoLifeError.accountChanged }
        try NivoLifeValidation.validate(candidate, owner: candidate.ownerKey)
        let committed = try advancing(candidate)
        try persist(committed)
        state = committed
    }

    /// 清空内存后重新读取磁盘，因此回滚结果不会被旧投影再次覆盖。
    func endBackup(token: UUID) {
        guard backupToken == token else { return }
        backupToken = nil
        state = nil
        scope = nil
    }

    private func requireState(_ requested: NivoLifeScope) throws -> NivoLifeState {
        guard backupToken == nil, scope == requested, let state, state.ownerKey == requested.ownerKey else {
            throw NivoLifeError.accountChanged
        }
        return state
    }

    private func commit(_ candidate: NivoLifeState, scope requested: NivoLifeScope) throws {
        _ = try requireState(requested)
        guard candidate.ownerKey == requested.ownerKey else { throw NivoLifeError.accountChanged }
        let committed = try advancing(candidate)
        try persist(committed)
        state = committed
    }

    private func persist(_ candidate: NivoLifeState) throws {
        // 普通事务、退出结算与备份必须满足相同的可重载约束，不能先写坏档案再在重启时发现。
        try NivoLifeValidation.validate(candidate, owner: candidate.ownerKey)
        let path = fileURL(ownerKey: candidate.ownerKey)
        let data = try encoder().encode(candidate)
        guard data.count <= NivoLifeValidation.maximumStoreBytes else { throw NivoLifeError.invalidField("store_size_limit") }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer(data, path)
    }

    /// 退出时落盘失败也冻结边界，重试不得把退出后的时间再次算进专注。
    private func persistSettlement(_ candidate: NivoLifeState) throws {
        let settled = try advancing(candidate)
        do { try persist(settled) }
        catch {
            pendingSettlement = settled
            state = nil
            throw error
        }
    }

    private func advancing(_ candidate: NivoLifeState) throws -> NivoLifeState {
        let previous = candidate.storeRevision ?? 0
        guard previous < Int64.max else { throw NivoLifeError.invalidField("storeRevision") }
        var result = candidate
        result.storeRevision = previous + 1
        return result
    }

    private func fileURL(ownerKey: String) -> URL {
        let digest = SHA256.hash(data: Data(ownerKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest, isDirectory: true).appendingPathComponent("state.json")
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func decodeStore(_ data: Data, ownerKey: String) throws -> NivoLifeState {
        guard data.count <= NivoLifeValidation.maximumStoreBytes else { throw NivoLifeError.corruptStore }
        let loaded: NivoLifeState
        do { loaded = try JSONDecoder().decode(NivoLifeState.self, from: data) }
        catch { throw NivoLifeError.corruptStore }
        do { try NivoLifeValidation.validate(loaded, owner: ownerKey) }
        catch let failure as NivoLifeError {
            if case .unsupportedVersion = failure { throw failure }
            throw NivoLifeError.corruptStore
        }
        return loaded
    }
}
