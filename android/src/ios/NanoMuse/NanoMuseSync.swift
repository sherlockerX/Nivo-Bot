import Foundation
import Combine

extension Notification.Name {
    /// 主聊天身份变更时通知页面重新选择本机会话。
    static let nanoMuseMainChatAdopt = Notification.Name("nanoMuseMainChatAdopt")
    /// 历史事务恢复后通知页面重新读取本地档案归属。
    static let nanoMuseAccountSwitched = Notification.Name("nanoMuseAccountSwitched")
}

/// 兼容旧聊天的本地归属和来源标记，不再注册监听、轮询或传输正文。
@MainActor
final class NanoMuseSync: ObservableObject {
    static let shared = NanoMuseSync()
    static let tail = 300

    @Published private(set) var syncing = false
    @Published private(set) var lastError: String?
    @Published private(set) var serverEnabled: Bool? = false
    @Published private(set) var conversationCount = 0
    @Published private(set) var messageCount = 0
    @Published private(set) var revision = 0

    private var checkpoint = NivoRelaySyncState()
    private var store = NivoRelayStore()
    private var accountKey: String { NanoMuseAccountData.shared.current }

    private init() {}

    /// 旧设置调用保持关闭，无法用持久偏好重新启用云服务。
    var enabled: Bool { get { false } set { if newValue { rejectCloudOperation() } } }
    var sideChats: Bool { false }

    /// 仅用于识别旧资料的归属键，不代表登录状态或网络授权。
    nonisolated static func accountKey(id: String?, hint: String?, apiKey: String?) -> String {
        if let id, !id.isEmpty { return id }
        if let hint, !hint.isEmpty { return hint }
        if let apiKey, !apiKey.isEmpty { return String(apiKey.suffix(8)) }
        return ""
    }

    /// 保留旧格式的纯数据契约，运行路径不会发送此地址。
    nonisolated static func pullPath(since: Int, sideChats: Bool, tail: Int? = nil) -> String {
        var path = "/v1/sync/changes?since=\(since)&limit=500&scope=\(sideChats ? "all" : "main")"
        if let tail { path += "&tail=\(tail)" }
        return path
    }

    /// 历史记录的主聊和旁聊分类规则。
    nonisolated static func takes(kind: String, sideChats: Bool) -> Bool { kind == "main" || sideChats }

    /// 保持历史档案隔离，当前档案仍可认领尚无归属的聊天。
    nonisolated static func visible(owner: String?, current: String) -> Bool {
        current.isEmpty || owner == nil || owner == current
    }

    /// 读取失败时由调用方显示错误，不能把坏映射当成无归属记录。
    func ownerChecked(of sessionId: String) throws -> String? {
        try loadChecked()
        if store.entries[sessionId] != nil { return store.account }
        return checkpoint.tables.stores.first { $0.value.entries[sessionId] != nil }?.key
    }

    /// 页面来源标记允许缺省，错误仍保存在可观察状态中。
    func owner(of sessionId: String) -> String? {
        do { return try ownerChecked(of: sessionId) }
        catch { lastError = error.localizedDescription; return nil }
    }

    /// 只有当前本地档案的聊天进入页面与AI读取范围。
    func shows(_ sessionId: String) -> Bool {
        do {
            let recordOwner = try ownerChecked(of: sessionId)
            return !NanoMuseFeedFlow.isFeedSession(sessionId)
                && Self.visible(owner: recordOwner, current: accountKey)
                && NanoMuseAccountData.shared.shows(sessionId)
        } catch { lastError = error.localizedDescription; return false }
    }

    /// 为列表和本地AI查询使用相同的档案过滤规则。
    func visible(_ sessions: [ChatSession]) -> [ChatSession] { sessions.filter { shows($0.id) } }

    /// 保留旧主聊天定位，不因云账号缓存被清理而跳到空聊天。
    var rememberedMainSession: String? {
        load()
        return store.mainSession
    }

    /// 返回历史中继标识，仅用于旧消息的显示关联。
    func cid(for sessionId: String) -> String? {
        load()
        return store.entries[sessionId]?.cid
    }

    /// 原设备名称是已有消息的本地元数据，不再查询远程设备。
    func fromDevice(mid: String) -> String? {
        load()
        guard let name = store.remoteMids[mid.lowercased()] else { return nil }
        return name.isEmpty ? AppLocalized("A device") : name
    }

    /// 历史聊天仍显示已有来源，当前手机生成的记录不添加来源标记。
    func originDeviceName(for sessionId: String) -> String? {
        load()
        guard let entry = store.entries[sessionId], let source = entry.fromDevice,
              source != NanoMuseHub.shared.deviceId else { return nil }
        return entry.fromDeviceName
    }

    /// 只清理已删除聊天的本地映射，不再生成远程删除任务。
    func conversationWillBeDeleted(_ sessionId: String) {
        do {
            try loadChecked()
            guard let entry = store.entries[sessionId], !store.account.isEmpty else { return }
            var candidate = checkpoint.tables
            var changed = store
            changed.applyConversationDeletion(cid: entry.cid, localID: sessionId, replacementCID: nil)
            candidate.stores[changed.account] = changed
            try checkpoint.commit(candidate, to: Self.syncFiles())
            store = changed
            revision += 1
        } catch { lastError = error.localizedDescription }
    }

    /// 仅供已存在的中断事务恢复，保留严格的磁盘提交边界。
    func dropTable(for account: String) throws {
        try loadChecked()
        guard !account.isEmpty else { return }
        var candidate = checkpoint.tables
        candidate.stores.removeValue(forKey: account)
        if candidate.current == account { candidate.current = "" }
        try checkpoint.commit(candidate, to: Self.syncFiles())
        store = candidate.stores[accountKey] ?? NivoRelayStore(account: accountKey)
        revision += 1
    }

    /// 原账号缓存清理只刷新本地视图，不触发远程拉取或本地资料删除。
    func accountChanged() {
        load()
        NanoMusePresence.shared.reset()
        revision += 1
        NotificationCenter.default.post(name: .sessionDidUpdate, object: nil)
    }

    /// 旧调用点保持无副作用，避免正常聊天反复出现已移除服务的错误。
    func start() { load() }
    func turnFinished(session: String) {}
    func userMessageSent(session: String) {}
    func conversationChanged(_ sessionId: String) {}
    func onHubFrame(_ frame: [String: Any]) {}
    func pull() {}
    func push() {}

    /// 不可达旧设置页若收到调用，明确报告服务已移除。
    func refreshState() async { rejectCloudOperation() }
    func setEnabled(_ on: Bool) async { if on { rejectCloudOperation() } }
    func setSideChats(_ on: Bool) { if on { rejectCloudOperation() } }
    func deleteSynced() async { rejectCloudOperation() }

    private func rejectCloudOperation() { lastError = NivoLocalModeError.cloudRemoved.localizedDescription }

    private static func syncFiles() throws -> NivoRelaySyncFile {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return NivoRelaySyncFile(url: directory.appendingPathComponent("nanomuse-sync-accounts.json"),
            legacyURL: directory.appendingPathComponent("nanomuse-sync.json"))
    }

    private func load() {
        do { try loadChecked() } catch { lastError = error.localizedDescription }
    }

    private func loadChecked() throws {
        try checkpoint.load(from: Self.syncFiles())
        // 本地身份与旧账号验证已解绑，绝不使用已清空的账号缓存选择历史表。
        store = checkpoint.tables.stores[accountKey] ?? NivoRelayStore(account: accountKey)
    }
}
