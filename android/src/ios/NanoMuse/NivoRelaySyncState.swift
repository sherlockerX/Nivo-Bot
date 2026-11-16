import Foundation

/// 一个本机会话在中继账户中的映射与已确认消息。
struct NivoRelayEntry: Codable, Equatable, Sendable {
    var cid: String
    /// 主会话或旁聊，首次建立映射时确定。
    var kind: String
    /// 来源设备；本机发起时为空。
    var fromDevice: String?
    var fromDeviceName: String?
    /// 中继已确认的会话标题与更新时间。
    var pushedTitle: String?
    var pushedUpdatedAt: Int?
    /// 中继已经收到或本机已经接收的小写消息ID。
    var knownMids: Set<String> = []

    /// 上传前根据实际消息身份判断是否需要读取正文，时间仅作辅助信号。
    func requiresMessageScan(present: Set<String>, intro: Set<String>, updatedAt: Int) -> Bool {
        pushedUpdatedAt != updatedAt || knownMids != present.union(intro)
    }

    /// 上传消息时一并确保父会话存在，中继清空不应导致新消息被拒。
    func requiresConversationUpload(title: String, updatedAt: Int, hasMessageChanges: Bool) -> Bool {
        hasMessageChanges || pushedTitle != title || pushedUpdatedAt != updatedAt
    }
}

/// 会话正被使用时暂存的入站消息，随游标一起持久化。
struct NivoRelayPending: Codable, Equatable, Sendable {
    var mid: String
    var cid: String
    var role: String
    var text: String
    var createdAt: Int
    var deviceName: String
}

/// 每个账户独立保存游标、会话映射和等待重试的操作。
struct NivoRelayStore: Codable, Equatable, Sendable {
    /// 当前表的账户身份，不能由正在返回的网络响应决定。
    var account = ""
    var cursor = 0
    /// 本机会话ID到中继记录的映射。
    var entries: [String: NivoRelayEntry] = [:]
    /// 同一账户的设备共享一个主会话ID。
    var mainCid: String?
    /// 已在本机删除、尚待中继确认的会话。
    var pendingDeletes: [String] = []
    /// 首次上传必须等拉取成功，以便复用账户已有的主会话。
    var pulled = false
    /// 入站消息ID到来源设备名称的映射。
    var remoteMids: [String: String] = [:]
    /// 等待正在运行的会话释放后写入的消息。
    var deferred: [NivoRelayPending] = []
    /// 再次登录时恢复此账户上次使用的主会话。
    var mainSession: String?
    /// 先保存本机ID，再创建数据库会话；中断后重放仍使用同一个ID。
    var pendingCreations: Set<String> = []

    init(account: String = "") {
        self.account = account
    }

    /// 本机删除完成后排队发送中继删除，调用方随后持久化完整映射。
    mutating func removeLocalConversation(_ localID: String) {
        guard let entry = entries[localID] else { return }
        applyConversationDeletion(cid: entry.cid, localID: localID, replacementCID: nil)
        if !pendingDeletes.contains(entry.cid) { pendingDeletes.append(entry.cid) }
    }

    /// 旧版没有的可选字段使用兼容值，格式错误仍向外传播。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = try c.decodeIfPresent(String.self, forKey: .account) ?? ""
        cursor = try c.decodeIfPresent(Int.self, forKey: .cursor) ?? 0
        entries = try c.decodeIfPresent([String: NivoRelayEntry].self, forKey: .entries) ?? [:]
        mainCid = try c.decodeIfPresent(String.self, forKey: .mainCid)
        pendingDeletes = try c.decodeIfPresent([String].self, forKey: .pendingDeletes) ?? []
        pulled = try c.decodeIfPresent(Bool.self, forKey: .pulled) ?? (cursor > 0)
        remoteMids = try c.decodeIfPresent([String: String].self, forKey: .remoteMids) ?? [:]
        deferred = try c.decodeIfPresent([NivoRelayPending].self, forKey: .deferred) ?? []
        mainSession = try c.decodeIfPresent(String.self, forKey: .mainSession)
        pendingCreations = try c.decodeIfPresent(Set<String>.self, forKey: .pendingCreations) ?? []
    }

    /// 数据库已确认删除后清理来源，主聊天保留本机身份并换用新的中继身份。
    mutating func applyConversationDeletion(cid: String, localID: String?, replacementCID: String?) {
        let messages = localID.flatMap { entries[$0]?.knownMids } ?? []
        for identifier in messages { remoteMids.removeValue(forKey: identifier) }
        deferred.removeAll { $0.cid == cid }
        guard let localID else {
            if mainCid == cid { mainCid = nil }
            return
        }
        pendingCreations.remove(localID)
        if let replacementCID {
            // 中继中的删除标记不可复活，继续使用旧cid会让此后所有新消息被拒绝。
            entries[localID]?.cid = replacementCID
            entries[localID]?.knownMids = []
            entries[localID]?.pushedTitle = nil
            entries[localID]?.pushedUpdatedAt = nil
            if mainCid == cid { mainCid = replacementCID }
        } else {
            entries.removeValue(forKey: localID)
            if mainCid == cid { mainCid = nil }
            if mainSession == localID { mainSession = nil }
        }
    }
}

/// 设备上的全部账户映射；其他账户的数据保留但不参与当前同步。
struct NivoRelayTables: Codable, Equatable, Sendable {
    var stores: [String: NivoRelayStore] = [:]
    /// 最后激活的账户；首次登录前为空。
    var current = ""
}

/// 从旧宿主提取的文件入口，由真实文件回归约束读取和提交行为。
struct NivoRelaySyncFile {
    let url: URL
    let legacyURL: URL

    /// 加载既有多账户表，旧单账户表仅在新表不存在时参与迁移。
    func load() throws -> NivoRelayTables {
        if let data = try readIfPresent(url) {
            let tables = try JSONDecoder().decode(NivoRelayTables.self, from: data)
            try tables.validate()
            return tables
        }
        guard let data = try readIfPresent(legacyURL) else { return NivoRelayTables() }
        let saved = try JSONDecoder().decode(NivoRelayStore.self, from: data)
        let tables = NivoRelayTables(stores: [saved.account: saved], current: saved.account)
        try tables.validate()
        return tables
    }

    /// 保存完整账户表，调用者随后发布新的游标和映射。
    func save(_ tables: NivoRelayTables) throws {
        try tables.validate()
        let data = try JSONEncoder().encode(tables)
        try data.write(to: url, options: .atomic)
    }

    private func readIfPresent(_ location: URL) throws -> Data? {
        do { return try Data(contentsOf: location) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
}

/// 只有写盘成功才能发布新游标，失败后仍能从最后一次持久快照重放。
struct NivoRelaySyncState {
    private(set) var tables = NivoRelayTables()
    private(set) var isLoaded = false

    /// 读取失败不改变内存状态，稍后解锁或修复文件后可以再次读取。
    mutating func load(from files: NivoRelaySyncFile) throws {
        guard !isLoaded else { return }
        tables = try files.load()
        isLoaded = true
    }

    /// 候选包含会话映射、延后消息、删除队列和游标，共同提交。
    mutating func commit(_ candidate: NivoRelayTables, to files: NivoRelaySyncFile) throws {
        guard isLoaded else { throw NivoLifeError.corruptStore }
        try files.save(candidate)
        tables = candidate
    }
}

extension NivoRelayTables {
    /// 旧可选字段允许缺省，账户归属和游标异常不能被当作全新空表。
    func validate() throws {
        guard current.isEmpty || stores[current] != nil else { throw NivoLifeError.corruptStore }
        for (key, store) in stores {
            guard !key.isEmpty, key == store.account, store.cursor >= 0 else { throw NivoLifeError.corruptStore }
            guard store.entries.allSatisfy({ !$0.key.isEmpty && !$0.value.cid.isEmpty
                && ["main", "side"].contains($0.value.kind) }) else { throw NivoLifeError.corruptStore }
            guard store.pendingCreations.isSubset(of: Set(store.entries.keys)) else { throw NivoLifeError.corruptStore }
        }
    }
}
