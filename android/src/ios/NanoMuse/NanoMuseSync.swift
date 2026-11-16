//
//  NanoMuseSync.swift
//  nanoMuse
//
//  Contract C7, display rules C8: the account's conversations are the same
//  on every device. This is the client: a side table that gives each local
//  session a `cid` (upstream's schema is not touched), a push of the
//  person's line when it is sent and of the final assistant text when the
//  turn ends, a pull on launch, foreground, the hub's `sync` frame and every
//  minute, and the one-main-chat rule. The whole eligible history goes up
//  on sign-in (oldest first, 200 a POST, the first conversation included);
//  what comes down is inserted into the chat by time, deduplicated by `mid`,
//  and shown as the other device's bubble with a "From {device}" caption.
//  Pulled side conversations are ordinary chats here. Files and images stay
//  where they were made; only their names and sizes travel.
//  C9 (0.1.38): side chats are per device — "Also sync side chats", default
//  off: only the main goes up, the pull asks `scope=main`, side rows that
//  still arrive are ignored. Switching it on pulls everything once
//  (`since=0&scope=all&tail=300`, idempotent) and the side chats go up with
//  the next push. The first pull of a table is `since=0&tail=300`: the last
//  300 texts per conversation, not the whole history. Presence — "{device}
//  is working…" — is NanoMusePresence; this file tells it when a turn's
//  user line has been pushed and when the turn's end has.
//  C10 (0.1.39): a conversation belongs to the account that first pushed or
//  pulled it — the table that maps it is that account's, and every account
//  that ever synced on this phone keeps its table (`Tables`). Signed in as B,
//  the lists show B's and the unowned conversations, the push takes the same
//  (an unowned one becomes B's with its first push), and A's stay on the
//  phone, hidden, until A is back. A different account than last time starts
//  its table's cursor over (a `tail` pull) and clears presence. Signed out,
//  everything on the phone shows and nothing moves. Accounts are told apart
//  by the relay's opaque `account.id`, never by the identifier.
//  Relay: GET/PUT /v1/sync/state, GET/POST /v1/sync/changes,
//  DELETE /v1/sync/conversations/{cid}, DELETE /v1/sync/changes.
//

import Foundation
import SwiftUI
import UIKit

extension Notification.Name {
    /// A main conversation arrived from another device while this phone's main chat was still a
    /// draft; the object is the local session id the shell should show as the main chat.
    static let nanoMuseMainChatAdopt = Notification.Name("nanoMuseMainChatAdopt")
    /// C10: the signed-in account is not the one the tables were open for; the object is the
    /// new account's key. The lists re-read, the main chat re-resolves.
    static let nanoMuseAccountSwitched = Notification.Name("nanoMuseAccountSwitched")
}

@MainActor
final class NanoMuseSync: ObservableObject {
    static let shared = NanoMuseSync()

    // MARK: - Side table

    // nanoMuse: 与可移植回归共用真实持久模型，宿主只负责页面和网络接入。
    typealias Entry = NivoRelayEntry
    typealias Pending = NivoRelayPending
    private typealias Store = NivoRelayStore
    private typealias Tables = NivoRelayTables
    private typealias Lease = NivoRelaySyncLifecycle.Lease

    private enum Keys {
        /// The local switch (Data controls). Default on, as the contract says.
        static let enabled = "nanomuse.sync.enabled"
        /// C9: "Also sync side chats", per device. Default off.
        static let sideChats = "nanomuse.sync.sidechats"
    }

    static let pushLimit = 200
    /// C9: how many texts per conversation a first (or switch-on) pull asks for.
    static let tail = 300

    // MARK: - Observable state

    @Published private(set) var syncing = false
    @Published private(set) var lastError: String?
    /// What the relay says about the account's switch; nil until asked.
    @Published private(set) var serverEnabled: Bool?
    @Published private(set) var conversationCount = 0
    @Published private(set) var messageCount = 0
    /// Bumped when the side table changes, so the drawer's badges re-read.
    @Published private(set) var revision = 0

    private var store = Store()
    /// C10: the other accounts' tables (and the current one's last saved copy).
    private var checkpoint = NivoRelaySyncState()
    private var tables: Tables { checkpoint.tables }
    private var loaded: Bool { checkpoint.isLoaded }
    private var lifecycle = NivoRelaySyncLifecycle()
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var controlIntents = 0
    private var started = false
    private var inForeground = false
    private var pullAgain = false
    private var pushAgain = false
    private var pushDebounce: Task<Void, Never>?
    private var pullTimer: Timer?
    /// 401: nothing more until the account changes.
    private var haltedAccount: String?
    private var observers: [NSObjectProtocol] = []
    /// C9: the presence this phone owes the relay once the next push has gone through —
    /// session id → working. `true` after the user line, `false` after the turn's end.
    private var workingToSend: [String: Bool] = [:]
    /// A pull that starts at 0 whatever the cursor says (the side-chat switch turned on).
    private var fullPullWanted = false

    private init() {}

    // MARK: - Switch

    /// The local switch; the relay's own is `serverEnabled`.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.enabled) == nil ? true : UserDefaults.standard.bool(forKey: Keys.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    /// C9: whether this device's side chats travel too. Default off: they stay on this phone and
    /// the other devices' side chats do not come here.
    var sideChats: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.sideChats) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sideChats) }
    }

    /// The side-chat switch: on → one pull of everything (idempotent — what is here already is
    /// known by mid), then this phone's side chats go up with the next push. Off → the pushes
    /// and pulls narrow to the main; what came down stays, as ordinary chats.
    func setSideChats(_ on: Bool) {
        guard on != sideChats else { return }
        do {
            try loadChecked()
            invalidateRequests()
            if on, !store.account.isEmpty {
                // 范围扩展必须先保存回溯起点，重启不能漏掉此前没有拉取的旁聊。
                store.cursor = 0
                store.pulled = false
                try save()
            }
            sideChats = on
            revision += 1
            fullPullWanted = on
            if active { pull() }
        } catch { note(error) }
    }

    /// The query a pull makes. `tail` is asked on a table's first pull (cursor 0) and on the
    /// switch-on pull; otherwise the pull is incremental.
    nonisolated static func pullPath(since: Int, sideChats: Bool, tail: Int? = nil) -> String {
        var path = "/v1/sync/changes?since=\(since)&limit=500&scope=\(sideChats ? "all" : "main")"
        if let tail { path += "&tail=\(tail)" }
        return path
    }

    /// The cid of a mapped session, for presence; nil for a draft or an unmapped chat.
    func cid(for sessionId: String) -> String? {
        if !loaded { load() }
        return store.entries[sessionId]?.cid
    }

    /// Whether a conversation of `kind` is this device's business under the switch.
    nonisolated static func takes(kind: String, sideChats: Bool) -> Bool {
        kind == "main" || sideChats
    }

    private var active: Bool {
        // 个人构建关闭此中继会话同步入口，iCloud同步使用独立设置。
        // nanoMuse: 备份冻结期间不拉取新的正文或删除，保证教练引用与聊天快照一致。
        !NanoMuseOffline.isOn && NanoMuseAccountData.shared.isReady
            && !NanoMuseAccountData.shared.isChangingAccount && !NivoPersonalBackupAccess.isBusy
            && !BackupRestoreJournal.hasPendingRecovery
            && NanoMuseCloud.isSignedIn && enabled && haltedAccount != accountKey
    }

    /// C10: the key a table is filed under — the relay's opaque `account.id`; the 0.1.38 key
    /// (the hint, or the key's tail) only for a relay that sends no id. "" when signed out.
    private var accountKey: String {
        Self.accountKey(id: NanoMuseCloud.account?.id, hint: NanoMuseCloud.account?.hint, apiKey: NanoMuseCloud.apiKey)
    }

    /// What 0.1.38 filed the one table under, to find it again the first time after the update.
    private var legacyAccountKey: String {
        Self.accountKey(id: nil, hint: NanoMuseCloud.account?.hint, apiKey: NanoMuseCloud.apiKey)
    }

    /// The table's key for an account: its id when the relay gave one, else the hint, else the
    /// key's last eight characters; "" for none of the three (signed out).
    nonisolated static func accountKey(id: String?, hint: String?, apiKey: String?) -> String {
        if let id, !id.isEmpty { return id }
        if let hint, !hint.isEmpty { return hint }
        if let apiKey, !apiKey.isEmpty { return String(apiKey.suffix(8)) }
        return ""
    }

    /// C10, rule 2: whether a session is shown and pushed under the signed-in account — one no
    /// account has synced yet, or one of the current account's. Signed out, everything shows.
    nonisolated static func visible(owner: String?, current: String) -> Bool {
        current.isEmpty || owner == nil || owner == current
    }

    // MARK: - C10: whose conversation

    /// The account a session belongs to — the one whose table maps it (it was pushed to or
    /// pulled from that account); nil for a session no account has synced.
    func owner(of sessionId: String) -> String? {
        do { return try ownerChecked(of: sessionId) }
        catch { note(error); return nil }
    }

    /// 账户迁移不能把不可读映射当成无归属，调用方必须处理失败。
    func ownerChecked(of sessionId: String) throws -> String? {
        try loadChecked(activateAccount: false)
        if store.entries[sessionId] != nil { return store.account }
        for (key, table) in tables.stores where key != store.account && table.entries[sessionId] != nil { return key }
        return nil
    }

    /// Whether the lists show this session right now: C10 (`visible(owner:current:)` over the
    /// sync tables) and C12 (the owner row, `NanoMuseAccountData.shows`) both agree, and it is
    /// not the feed's working conversation, which is the agent's and no chat of the person's.
    func shows(_ sessionId: String) -> Bool {
        load()
        return loaded && (accountKey.isEmpty || store.account == accountKey)
            && !NanoMuseFeedFlow.isFeedSession(sessionId)
            && Self.visible(owner: owner(of: sessionId), current: accountKey) && NanoMuseAccountData.shared.shows(sessionId)
    }

    /// C12: the account's table goes with its chats (a sign-out without *Keep*, *Delete
    /// account*): a later sign-in starts a fresh table rather than reading the missing
    /// sessions as deletions and tombstoning them on the account's other devices.
    func dropTable(for account: String) throws {
        try loadChecked(activateAccount: false)
        guard !account.isEmpty else { return }
        var candidate = tables
        candidate.stores.removeValue(forKey: account)
        if candidate.current == account { candidate.current = "" }
        try checkpoint.commit(candidate, to: Self.syncFiles())
        if store.account == account {
            store = Store()
            workingToSend = [:]
            invalidateRequests()
        }
        revision += 1
    }

    /// The sessions the lists show: `shows` over a list.
    func visible(_ sessions: [ChatSession]) -> [ChatSession] {
        sessions.filter { shows($0.id) }
    }

    /// The local session the Chat tab showed when the current account was last signed in, if
    /// it is remembered (set when the account was switched away from).
    var rememberedMainSession: String? {
        if !loaded { load() }
        return store.mainSession
    }

    /// NanoMuseCloud signed an account in or out: the tables are re-filed now rather than at
    /// the next push, so the lists and the main chat follow at once. Signed in, the account's
    /// chats come down now (Android's `ConversationSync.signedIn`): before, nothing pulled
    /// until the app was sent to the background and back or a session changed, so a fresh
    /// sign-in sat on an empty draft while the other device's main chat waited on the relay.
    func accountChanged() {
        invalidateRequests()
        serverEnabled = nil
        conversationCount = 0
        messageCount = 0
        load()
        if accountKey.isEmpty {
            // signed out: what the relay said about the account's conversations is forgotten and
            // the lists show everything on the phone again; the table waits for an account
            workingToSend = [:]
            NanoMusePresence.shared.reset()
            revision += 1
            NotificationCenter.default.post(name: .sessionDidUpdate, object: nil)
            return
        }
        signedIn()
    }

    /// A new key for the signed-in account: the stop after a 401 is over, whatever account the
    /// key is for (signing in again as the same account used to stay halted until the app was
    /// killed), the tail comes down, the minute pull starts, and this phone's own history
    /// follows (the pull schedules the push).
    private func signedIn() {
        haltedAccount = nil
        guard started, active else { return }
        pull()
        if inForeground { startPullTimer() }
    }

    /// The signed-in account is not the one `store` is for: file the current table, take the
    /// account's own (re-keyed from the 0.1.38 key when that is how it was filed) or a fresh
    /// one, start its cursor over (rule 4), clear presence, tell the lists and the main chat.
    private func activate(_ key: String) throws {
        var candidate = tables
        let previous = tables.current
        if !previous.isEmpty {
            // 当前主会话偏好可能已经属于新账户，不把它覆盖到离开的账户。
            candidate.stores[previous] = store
        }
        let legacyKey = legacyAccountKey
        var next: Store
        if let own = candidate.stores[key] {
            next = own
        } else if !legacyKey.isEmpty, legacyKey != key, let legacy = candidate.stores.removeValue(forKey: legacyKey) {
            next = legacy
        } else {
            next = Store(account: key)
        }
        next.account = key
        // the cursor over: the next pull is the tail pull, and the push waits for it
        next.cursor = 0
        next.pulled = false
        candidate.current = key
        candidate.stores[key] = next
        try checkpoint.commit(candidate, to: Self.syncFiles())
        store = next
        invalidateRequests()
        workingToSend = [:]
        fullPullWanted = false
        if haltedAccount != key { haltedAccount = nil }
        NanoMusePresence.shared.reset()
        // the lists and the Chat tab: off the view update that may have asked for the table
        Task { @MainActor [self] in
            guard accountKey == key, store.account == key else { return }
            revision += 1
            NotificationCenter.default.post(name: .nanoMuseAccountSwitched, object: key)
            NotificationCenter.default.post(name: .sessionDidUpdate, object: nil)
        }
    }

    // MARK: - Lifecycle

    /// 身份只在进程内比较，凭证不进入持久化表或诊断日志。
    private var currentIdentity: NivoRelaySyncLifecycle.Identity {
        .init(account: accountKey, credential: NanoMuseCloud.apiKey ?? "", endpoint: NanoMuseCloud.baseURL,
              accountGeneration: NanoMuseAccountData.shared.generation)
    }

    /// 停用、切号、切换同步范围时撤销旧意图；实际请求结束前继续保留占位。
    private func invalidateRequests() {
        lifecycle.invalidate()
        pullAgain = false
        pushAgain = false
        pushDebounce?.cancel()
        pushDebounce = nil
    }

    private func beginOperation(requiresActive: Bool = true) throws -> Lease? {
        if requiresActive { try loadChecked() }
        guard !requiresActive || active else { return nil }
        guard NanoMuseAccountData.shared.isReady, !NanoMuseAccountData.shared.isChangingAccount,
              !NivoPersonalBackupAccess.isBusy, !BackupRestoreJournal.hasPendingRecovery,
              !requiresActive || store.account == accountKey else { return nil }
        guard let lease = lifecycle.begin(currentIdentity) else { return nil }
        syncing = true
        return lease
    }

    private func requireCurrent(_ lease: Lease, requiresActive: Bool = true) throws {
        try Task.checkCancellation()
        guard lifecycle.accepts(lease, identity: currentIdentity),
              !requiresActive || store.account == lease.intent.identity.account,
              NanoMuseAccountData.shared.isReady, !NanoMuseAccountData.shared.isChangingAccount,
              !NivoPersonalBackupAccess.isBusy, !BackupRestoreJournal.hasPendingRecovery,
              !requiresActive || active else { throw CancellationError() }
    }

    private func endOperation(_ lease: Lease) {
        guard lifecycle.end(lease) else { return }
        syncing = false
        let waiters = operationWaiters
        operationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        drainRequests()
    }

    private func waitForOperation() async {
        guard lifecycle.isBusy else { return }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func drainRequests() {
        guard !lifecycle.isBusy, controlIntents == 0, active else { return }
        if pullAgain { pullAgain = false; pull(); return }
        if pushAgain { pushAgain = false; schedulePush() }
    }

    /// Called once from the app root: load the table, watch the app's life, pull.
    func start() {
        guard !started else { return }
        started = true
        load()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.foregrounded() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.backgrounded() }
        })
        observers.append(center.addObserver(forName: .sessionDidUpdate, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedulePush() }
        })
        foregrounded()
    }

    private func foregrounded() {
        inForeground = true
        guard active else { return }
        pull()
        startPullTimer()
    }

    /// The minute pull while the app is in front (contract C7: at launch, on the hub's `sync` frame, and once a minute).
    private func startPullTimer() {
        pullTimer?.invalidate()
        pullTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pull() }
        }
    }

    private func backgrounded() {
        inForeground = false
        pullTimer?.invalidate()
        pullTimer = nil
        pushDebounce?.cancel()
        pushDebounce = nil
        guard active else { return }
        push()
    }

    /// The hub heard `{"type":"sync","what":"conversations","cursor":N,"from":id}`.
    func onHubFrame(_ frame: [String: Any]) {
        guard (frame["what"] as? String ?? "conversations") == "conversations" else { return }
        if let from = frame["from"] as? String, from == NanoMuseHub.shared.deviceId { return }
        let cursor = (frame["cursor"] as? Int) ?? Int((frame["cursor"] as? Double) ?? 0)
        if cursor > store.cursor { pull() }
    }

    // MARK: - Hooks from the chat

    /// A turn finished in `session` (the real id, or a draft id that is not a session yet).
    func turnFinished(session: String) {
        guard !session.hasPrefix(NanoMuseMainChat.draftPrefix) else { return }
        if active { workingToSend[session] = false } // C9: "working: false" follows the turn's last push
        schedulePush()
        // Texts that arrived while this chat was busy go in once the activity tracker has let go.
        if active, !store.deferred.isEmpty {
            let intent = lifecycle.intent(for: currentIdentity)
            Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                guard self.lifecycle.accepts(intent, identity: self.currentIdentity) else { return }
                await self.flushDeferred()
            }
        }
    }

    /// C8: the person's line goes up when it is sent, not when the turn ends. Called by the view
    /// model right after the user row is written; the turn's assistant text follows at the end.
    func userMessageSent(session: String) {
        guard active, !session.hasPrefix(NanoMuseMainChat.draftPrefix) else { return }
        workingToSend[session] = true // C9: "working: true" follows the push of this line
        pushDebounce?.cancel()
        pushDebounce = nil
        push()
    }

    /// C9: the presence owed after a push that went through — one POST per session, never retried.
    private func sendWorking() {
        let owed = workingToSend
        workingToSend = [:]
        for (session, on) in owed {
            guard let entry = store.entries[session], Self.takes(kind: entry.kind, sideChats: sideChats) else { continue }
            NanoMusePresence.shared.send(cid: entry.cid, working: on)
        }
    }

    /// The device a pulled text was written on — the bubble's "From {device}" — or nil for this
    /// phone's own. Cheap: a dictionary lookup, read for every row the chat lays out.
    func fromDevice(mid: String) -> String? {
        if !loaded { load() }
        guard let name = store.remoteMids[mid.lowercased()] else { return nil }
        return name.isEmpty ? AppLocalized("A device") : name
    }

    /// The chat was renamed (or otherwise changed) — push soon.
    func conversationChanged(_ sessionId: String) {
        schedulePush()
    }

    /// The chat is about to be deleted locally: remember its cid for the tombstone.
    func conversationWillBeDeleted(_ sessionId: String) {
        do {
            try loadChecked()
            guard store.entries[sessionId] != nil else { return }
            store.removeLocalConversation(sessionId)
            try save()
            schedulePush()
        } catch { note(error) }
    }

    /// The device a synced chat came from, for the drawer's "From Pixel 8"; nil for this phone's own.
    func originDeviceName(for sessionId: String) -> String? {
        _ = revision
        load()
        guard let entry = store.entries[sessionId], let id = entry.fromDevice, id != NanoMuseHub.shared.deviceId else { return nil }
        if let live = NanoMuseHub.shared.others.first(where: { $0.id == id }) { return live.name }
        return entry.fromDeviceName
    }

    // MARK: - Data controls

    /// Reads the relay's switch and counts.
    func refreshState() async {
        guard NanoMuseCloud.isSignedIn, let token = NanoMuseCloud.apiKey else { return }
        var request: Lease?
        do {
            guard controlIntents == 0, let lease = try beginOperation(requiresActive: false) else { return }
            request = lease
            defer { endOperation(lease) }
            let reply = try await NanoMuseCloud.call("GET", "/v1/sync/state", body: nil, token: token)
            try requireCurrent(lease, requiresActive: false)
            apply(state: reply)
            lastError = nil
        } catch {
            note(error, for: request)
        }
    }

    /// The switch: off → the relay deletes everything and this phone stops; on → an empty store,
    /// this phone's conversations go up again.
    func setEnabled(_ on: Bool) async {
        var request: Lease?
        controlIntents += 1
        defer { controlIntents -= 1; drainRequests() }
        do {
            invalidateRequests()
            enabled = on
            // 本地文件损坏也必须允许关闭云端同步；重新开启才要求本机表完整可读。
            if on { try loadChecked() }
            let intent = lifecycle.intent(for: currentIdentity)
            await waitForOperation()
            guard lifecycle.accepts(intent, identity: currentIdentity), !Task.isCancelled,
                  let lease = try beginOperation(requiresActive: false) else { return }
            request = lease
            defer { endOperation(lease) }
            let token = lease.intent.identity.credential
            let reply = try await NanoMuseCloud.call("PUT", "/v1/sync/state", body: ["enabled": on], token: token)
            try requireCurrent(lease, requiresActive: false)
            apply(state: reply)
            lastError = nil
            if on {
                for key in store.entries.keys { store.entries[key]?.knownMids = []; store.entries[key]?.pushedTitle = nil }
                // The relay's store is empty again: pull first (the cursor keeps counting), then
                // everything this phone has goes up — the full backfill, oldest first.
                store.pulled = false
                try save()
                pullAgain = true
                if inForeground { startPullTimer() }
            } else {
                pullTimer?.invalidate()
                pullTimer = nil
            }
        } catch {
            note(error, for: request)
        }
    }

    /// "Delete synced conversations": the store is wiped, the switch stays.
    func deleteSynced() async {
        var request: Lease?
        controlIntents += 1
        defer { controlIntents -= 1; drainRequests() }
        do {
            // 尽量准备本地映射，但文件故障不阻止用户删除中继中的数据。
            load()
            invalidateRequests()
            let intent = lifecycle.intent(for: currentIdentity)
            await waitForOperation()
            guard lifecycle.accepts(intent, identity: currentIdentity), !Task.isCancelled,
                  let lease = try beginOperation(requiresActive: false) else { return }
            request = lease
            defer { endOperation(lease) }
            let token = lease.intent.identity.credential
            _ = try await NanoMuseCloud.call("DELETE", "/v1/sync/changes", body: nil, token: token)
            try requireCurrent(lease, requiresActive: false)
            conversationCount = 0
            messageCount = 0
            lastError = nil
            // 中继删除不清除本机已上传标记，否则下一次定时同步会立即把全部旧聊天再上传。
            // 此操作不需要改写本地表，文件损坏也不应掩盖已完成的云端删除。
        } catch {
            note(error, for: request)
        }
    }

    private func apply(state reply: [String: Any]) {
        if let on = reply["enabled"] as? Bool {
            serverEnabled = on
            if !on { enabled = false }
        }
        if let counts = reply["counts"] as? [String: Any] {
            conversationCount = (counts["conversations"] as? Int) ?? 0
            messageCount = (counts["messages"] as? Int) ?? 0
        }
        // C9: who is at work on what, as the relay remembers it (unexpired only).
        if let working = reply["working"] as? [[String: Any]] { NanoMusePresence.shared.apply(list: working) }
    }

    // MARK: - Push

    private func schedulePush() {
        guard active else { return }
        // Signed in since the last foreground: the minute pull starts now.
        if inForeground, pullTimer == nil { foregrounded() }
        pushDebounce?.cancel()
        let intent = lifecycle.intent(for: currentIdentity)
        pushDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self,
                  self.lifecycle.accepts(intent, identity: self.currentIdentity) else { return }
            self.push()
        }
    }

    /// Everything the relay does not have yet: new or changed conversations, new texts, tombstones.
    func push() {
        guard active else { return }
        do { try loadChecked() } catch { note(error); return }
        // A table that never pulled pulls first: the account's main may already exist, and our
        // main must join it rather than race it. The pull schedules this push when it is done.
        guard store.pulled else { pull(); return }
        if lifecycle.isBusy || controlIntents > 0 { pushAgain = true; return }
        let lease: Lease
        do {
            guard let started = try beginOperation() else { return }
            lease = started
        } catch { note(error); return }
        Task { @MainActor [self] in
            defer { endOperation(lease) }
            do {
                try requireCurrent(lease)
                try await pushTombstones(lease: lease)
                try await pushChanges(lease: lease)
                try requireCurrent(lease)
                lastError = nil
                sendWorking()
            } catch {
                note(error, for: lease)
            }
        }
    }

    private func pushTombstones(lease: Lease) async throws {
        guard !store.pendingDeletes.isEmpty else { return }
        for cid in store.pendingDeletes {
            try requireCurrent(lease)
            do {
                _ = try await NanoMuseCloud.call("DELETE", "/v1/sync/conversations/\(cid)", body: nil,
                    token: lease.intent.identity.credential)
            } catch let error as NanoMuseCloudError where error.status == 404 {
                // already gone
            }
            try requireCurrent(lease)
            store.pendingDeletes.removeAll { $0 == cid }
            try save()
        }
    }

    private func pushChanges(lease: Lease) async throws {
        // Oldest first (C8): a sign-in backfills the whole history in the order it happened, the
        // first conversation at the head.
        let every = await eligibleSessions().sorted { $0.createdAt < $1.createdAt }
        try requireCurrent(lease)
        let mainId = ownMainSessionId()
        let alive = try await ChatStore.shared.nmAccountSessionIDs()
        try requireCurrent(lease)
        // C9: with the side-chat switch off only the main chat goes up — the one mapped as main,
        // or the shell's main when it has no entry yet. The side chats stay this phone's.
        // C10, rule 3: another account's conversations never go up under this one — only the
        // current account's and the unowned (which become this account's with this push).
        // C12: nor the chats another account, or nobody, owns on this phone.
        let sideChats = sideChats
        let sessions = every.filter { session in
            guard !store.pendingCreations.contains(session.id), Self.visible(owner: owner(of: session.id), current: store.account), NanoMuseAccountData.shared.shows(session.id) else { return false }
            return sideChats || session.id == mainId || store.entries[session.id]?.kind == "main"
        }

        // Sessions that vanished without passing through the drawer's delete (Clear-all, upstream list).
        for id in Array(store.entries.keys) where !alive.contains(id) && !store.pendingCreations.contains(id) {
            store.removeLocalConversation(id)
        }
        if !store.pendingDeletes.isEmpty {
            try save()
            try await pushTombstones(lease: lease)
        }

        var conversations: [[String: Any]] = []
        var messages: [[String: Any]] = []
        // What each message record came from, to mark it known once accepted.
        var pending: [(session: String, mid: String, deleted: Bool)] = []

        let previousEntryCount = store.entries.count
        for session in sessions { ensureEntry(for: session, isMain: session.id == mainId) }
        if previousEntryCount != store.entries.count { try save() }

        for session in sessions {
            try requireCurrent(lease)
            guard let entry = store.entries[session.id] else { continue }
            // The shell's main can map as side when another local session already holds the shared cid.
            guard Self.takes(kind: entry.kind, sideChats: sideChats) else { continue }
            let updated = Int(session.updatedAt.timeIntervalSince1970)
            let sendsMetadata = entry.requiresConversationUpload(title: session.title ?? "", updatedAt: updated, hasMessageChanges: false)
            var conversation: [String: Any] = [
                "cid": entry.cid,
                "kind": entry.kind,
                "created_at": Int(session.createdAt.timeIntervalSince1970),
                "updated_at": updated,
            ]
            if let title = session.title, !title.isEmpty { conversation["title"] = title }
            if sendsMetadata { conversations.append(conversation) }
            let previousMessageCount = messages.count

            // 清空与裁剪不保证改变会话时间，先严格读ID判定删除，再决定是否解码正文。
            let present = try await ChatStore.shared.nmRelayMessageIDs(sessionID: session.id)
            try requireCurrent(lease)
            // The first conversation's opening (what the app said on the agent's behalf) is virtual
            // here — in the message list, never in the database — so the other devices get it
            // from this table, under stable ids, dated just before the person's first line.
            let intro = Self.introRecords(for: session, cid: entry.cid)
            let introMids = Set(intro.compactMap { $0["mid"] as? String })
            guard entry.requiresMessageScan(present: present, intro: introMids, updatedAt: updated) else { continue }
            let local = try await ChatStore.shared.nmRelayMessages(sessionID: session.id, excludingKnown: entry.knownMids)
            try requireCurrent(lease)
            // Texts that were deleted here since the relay got them.
            for mid in entry.knownMids where !present.contains(mid) && !introMids.contains(mid) {
                messages.append(["mid": mid, "cid": entry.cid, "role": "user", "text": "", "created_at": Int(Date().timeIntervalSince1970), "deleted": true])
                pending.append((session.id, mid, true))
            }
            for record in intro {
                guard let mid = record["mid"] as? String, !entry.knownMids.contains(mid) else { continue }
                messages.append(record)
                pending.append((session.id, mid, false))
            }
            for message in local.sorted(by: { $0.createdAt < $1.createdAt }) {
                let mid = message.id.lowercased()
                // What came down from another device is theirs to push, not ours.
                guard !entry.knownMids.contains(mid), store.remoteMids[mid] == nil, let record = Self.record(message, cid: entry.cid) else { continue }
                messages.append(record)
                pending.append((session.id, mid, false))
            }
            if !sendsMetadata, entry.requiresConversationUpload(title: session.title ?? "", updatedAt: updated,
                hasMessageChanges: messages.count > previousMessageCount) {
                conversations.append(conversation)
            }
        }

        guard !conversations.isEmpty || !messages.isEmpty else { return }

        // 会话和消息分别分批；只有全部批次完成后，才确认本次会话的更新时间。
        // 否则第二批失败时，第一批写入的时间会让下次上传误以为整段历史已经同步。
        var rejectedSessions = Set<String>()
        var conversationOffset = 0
        var messageOffset = 0
        repeat {
            try requireCurrent(lease)
            let sendingConversations = conversationOffset < conversations.count
            let messageStart = messageOffset
            let messageEnd = sendingConversations ? messageOffset : min(messageOffset + Self.pushLimit, messages.count)
            let conversationStart = conversationOffset
            let conversationEnd = min(conversationOffset + Self.pushLimit, conversations.count)
            let body: [String: Any] = [
                "device": NanoMuseHub.shared.deviceId,
                "conversations": Array(conversations[conversationStart..<conversationEnd]),
                "messages": Array(messages[messageStart..<messageEnd]),
            ]
            let reply = try await NanoMuseCloud.call("POST", "/v1/sync/changes", body: body,
                token: lease.intent.identity.credential)
            try requireCurrent(lease)
            let receipt = try NivoRelayPushReceipt.decode(JSONSerialization.data(withJSONObject: reply))
            let rejectedMids = Set(receipt.rejected.compactMap(\.mid))
            let rejectedCids = Set(receipt.rejected.compactMap(\.cid))
            for session in sessions where store.entries[session.id].map({ rejectedCids.contains($0.cid) }) == true {
                rejectedSessions.insert(session.id)
            }
            for (session, mid, deleted) in pending[messageStart..<messageEnd] {
                if rejectedMids.contains(mid) { rejectedSessions.insert(session); continue }
                guard !rejectedSessions.contains(session) else { continue }
                if deleted {
                    store.entries[session]?.knownMids.remove(mid)
                    store.remoteMids.removeValue(forKey: mid)
                } else {
                    store.entries[session]?.knownMids.insert(mid)
                }
            }
            try save()
            if let clash = receipt.rejected.first(where: { $0.reason == "main_exists" }),
               let shared = clash.cidMain, let rejected = clash.cid {
                try adoptMain(shared, rejectedCid: rejected)
                return
            }
            conversationOffset = conversationEnd
            messageOffset = messageEnd
        } while messageOffset < messages.count || conversationOffset < conversations.count
        for session in sessions where !rejectedSessions.contains(session.id) {
            guard store.entries[session.id] != nil else { continue }
            store.entries[session.id]?.pushedTitle = session.title ?? ""
            store.entries[session.id]?.pushedUpdatedAt = Int(session.updatedAt.timeIntervalSince1970)
        }
        if let mainId, let entry = store.entries[mainId], entry.kind == "main", store.mainCid == nil {
            store.mainCid = entry.cid
        }
        try save()
    }

    /// The relay keeps one main conversation; the session we pushed as `rejectedCid` re-posts under it.
    private func adoptMain(_ cidMain: String, rejectedCid: String) throws {
        store.mainCid = cidMain
        guard let sessionId = store.entries.first(where: { $0.value.cid == rejectedCid })?.key else { try save(); return }
        if store.entries.contains(where: { $0.value.cid == cidMain }) {
            // Another local session already is the shared main; this one stays a side chat.
            store.entries[sessionId]?.kind = "side"
            store.entries[sessionId]?.knownMids = []
            store.entries[sessionId]?.pushedTitle = nil
        } else {
            store.entries[sessionId]?.cid = cidMain
            store.entries[sessionId]?.knownMids = []
            store.entries[sessionId]?.pushedTitle = nil
        }
        try save()
        revision += 1
        pushAgain = true
    }

    /// The first conversation's scripted opening as relay records, when `session` is where it
    /// happened: three assistant lines under ids derived from the session (so every push names
    /// the same ones), dated just before the session began. Empty for any other chat.
    private static func introRecords(for session: ChatSession, cid: String) -> [[String: Any]] {
        let flow = NanoMuseFirstConversation.shared
        guard flow.isBound(to: session.id) else { return [] }
        let base = Int(session.createdAt.timeIntervalSince1970) - 3
        return flow.intro().enumerated().map { index, text in
            [
                "mid": "intro-\(session.id.lowercased())-\(index)",
                "cid": cid,
                "role": "assistant",
                "text": text,
                "created_at": base + index,
            ]
        }
    }

    /// The record for a text the relay should have, or nil for what is not synced (tool steps, empties).
    private static func record(_ message: RawMessage, cid: String) -> [String: Any]? {
        if message.isToolResultOnly || message.isInternalBridge { return nil }
        var text = ""
        var attachments: [[String: Any]] = []
        for part in message.parts {
            switch part {
            case .text(let s):
                text += text.isEmpty ? s : "\n" + s
            case .mediaRef(let ref):
                var a: [String: Any] = ["name": ref.originalFileName ?? (ref.relativePath as NSString).lastPathComponent, "mime": ref.mimeType]
                let path = ChatStore.shared.minisBaseURL.appendingPathComponent(ref.relativePath).path
                if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int {
                    a["size"] = size
                }
                attachments.append(a)
            case .toolUse:
                // An assistant step that calls a tool is not the final answer of the turn.
                if message.role == .assistant { return nil }
            case .toolResult:
                return nil
            }
        }
        // The model's `<system-reminder>` notes ride inside the person's text here and are
        // hidden by every screen; the other devices store the record as is, so they go before
        // the push (Android's Transcript does the same). A turn that was only a reminder, such
        // as the stop-and-continue nudge, is not a message at all.
        let trimmed = RawMessage.stripSystemReminders(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return nil }
        var record: [String: Any] = [
            "mid": message.id.lowercased(),
            "cid": cid,
            "role": message.role.rawValue,
            "text": trimmed,
            "created_at": Int(message.createdAt.timeIntervalSince1970),
        ]
        if !attachments.isEmpty { record["attachments"] = attachments }
        return record
    }

    // MARK: - Pull

    /// What the other devices wrote since our cursor, applied in `seq` order.
    func pull() {
        guard active else { return }
        if lifecycle.isBusy || controlIntents > 0 { pullAgain = true; return }
        let lease: Lease
        do {
            guard let started = try beginOperation() else { return }
            lease = started
        } catch { note(error); return }
        Task { @MainActor [self] in
            defer { endOperation(lease) }
            let full = fullPullWanted || store.cursor == 0
            do {
                try requireCurrent(lease)
                var more = true
                var touched = false
                // C9: a table's first pull and the switch-on pull start at 0 and ask for the last
                // `tail` texts per conversation; the switch-on pull leaves the cursor where it is
                // (only ever raised) so nothing is pulled twice later.
                var since = full ? 0 : store.cursor
                while more {
                    try requireCurrent(lease)
                    let path = Self.pullPath(since: since, sideChats: sideChats, tail: full ? Self.tail : nil)
                    let reply = try await NanoMuseCloud.call("GET", path, body: nil, token: lease.intent.identity.credential)
                    try requireCurrent(lease)
                    let page = try NivoRelaySyncPage.decode(JSONSerialization.data(withJSONObject: reply), since: since)
                    let changed = try await apply(changes: page, lease: lease)
                    try requireCurrent(lease)
                    touched = touched || changed
                    let cursor = page.cursor
                    if cursor > store.cursor { store.cursor = cursor }
                    try save()
                    more = page.more
                    since = cursor
                }
                if !store.pulled {
                    store.pulled = true
                    try save()
                }
                if full { fullPullWanted = false }
                lastError = nil
                if touched {
                    revision += 1
                    NotificationCenter.default.post(name: .cloudSyncDidFetchChanges, object: nil)
                    NotificationCenter.default.post(name: .sessionDidUpdate, object: nil)
                }
                // Our own texts the relay does not have yet (first pull after sign-in, a new main cid).
                schedulePush()
            } catch {
                note(error, for: lease)
            }
        }
    }

    /// One page. Returns true when something changed locally.
    private func apply(changes reply: NivoRelaySyncPage, lease: Lease) async throws -> Bool {
        var changed = false
        let me = NanoMuseHub.shared.deviceId
        for record in reply.conversations {
            if try await applyConversation(record, lease: lease) { changed = true }
        }

        // Texts, grouped by conversation so each session's ids are read once.
        var presentBySession: [String: Set<String>] = [:]
        for record in reply.messages {
            try requireCurrent(lease)
            let mid = record.mid
            let cid = record.cid
            guard let entry = store.entries.first(where: { $0.value.cid == cid }) else { continue }
            let sessionId = entry.key
            // C9: a side chat's texts stay where they were written while the switch is off.
            guard Self.takes(kind: entry.value.kind, sideChats: sideChats) else { continue }
            if record.deleted {
                // nanoMuse: 消息删除同样持有占位，两种UUID大小写清理属于同一次操作。
                let editToken = try NivoChatAccountAccess.beginConversationEdit([sessionId])
                defer { NivoScheduledRunScopes.shared.endConversationEdit(editToken) }
                try await ChatStore.shared.nmDeleteRelayMessage(messageID: mid, sessionID: sessionId)
                try requireCurrent(lease)
                store.entries[sessionId]?.knownMids.remove(mid)
                store.remoteMids.removeValue(forKey: mid)
                store.deferred.removeAll { $0.mid == mid }
                changed = true
                continue
            }
            // Our own texts are here already (or were deleted here, which the push says): the echo.
            if record.device == me { store.entries[sessionId]?.knownMids.insert(mid); continue }
            if store.entries[sessionId]?.knownMids.contains(mid) == true || store.deferred.contains(where: { $0.mid == mid }) { continue }
            if presentBySession[sessionId] == nil {
                presentBySession[sessionId] = Set(try await ChatStore.shared.nmRelayMessages(sessionID: sessionId).map { $0.id.lowercased() })
                try requireCurrent(lease)
            }
            if presentBySession[sessionId]?.contains(mid) == true { store.entries[sessionId]?.knownMids.insert(mid); continue }
            let roleName = record.role
            var text = record.text
            if let attachments = record.attachments, !attachments.isEmpty {
                let names = attachments.map(\.name).filter { !$0.isEmpty }
                if !names.isEmpty {
                    let line = String(format: AppLocalized("Files on the other device: %@"), names.joined(separator: ", "))
                    text = text.isEmpty ? line : text + "\n\n" + line
                }
            }
            guard !text.isEmpty else { store.entries[sessionId]?.knownMids.insert(mid); continue }
            let pending = Pending(mid: mid, cid: cid, role: roleName, text: text,
                createdAt: record.createdAt, deviceName: record.deviceName ?? "")
            if try await insert(pending, into: sessionId, lease: lease) {
                presentBySession[sessionId]?.insert(mid)
                changed = true
            }
        }
        if !store.deferred.isEmpty, try await writeDeferred(lease: lease) { changed = true }
        return changed
    }

    /// 会话映射先落盘，创建或标题更新失败时保持原游标，下一次继续使用预留ID。
    private func applyConversation(_ record: NivoRelaySyncPage.Conversation, lease: Lease) async throws -> Bool {
        try requireCurrent(lease)
        let local = store.entries.first { $0.value.cid == record.cid }
        guard Self.takes(kind: record.kind, sideChats: sideChats) else { return false }
        if record.deleted { return try await removeConversation(record, localID: local?.key, lease: lease) }
        guard !store.pendingDeletes.contains(record.cid) else { return false }
        let sessionID = try reserveConversation(record, localID: local?.key)
        guard let entry = store.entries[sessionID] else { throw NivoLifeError.corruptStore }
        if !store.pendingCreations.contains(sessionID), entry.pushedTitle == record.title {
            let existing = try await ChatStore.shared.nmRemoteChatSession(recordType: "SessionV2", id: sessionID)
            try requireCurrent(lease)
            if existing == sessionID {
                // 元数据没有变化时不占用正在回答的聊天，正文可进入持久延后队列。
                announceMainIfNeeded(record, sessionID: sessionID)
                return false
            }
        }
        let edit = try NivoChatAccountAccess.beginConversationEdit([sessionID])
        defer { NivoScheduledRunScopes.shared.endConversationEdit(edit) }
        let request = NivoRelayChatSQL.Session(id: sessionID, title: record.title.flatMap { $0.isEmpty ? nil : $0 },
            modelID: Self.defaultModelId(), createdAt: Double(record.createdAt), updatedAt: Double(record.updatedAt),
            memoryEnabled: (UserDefaults.standard.object(forKey: "memory.global.enabled") as? Bool) ?? true,
            mayCreate: store.pendingCreations.contains(sessionID), updatesTitle: entry.pushedTitle != record.title,
            onlyIfUntitled: entry.kind == "main" && entry.fromDevice == nil && entry.pushedUpdatedAt == nil)
        let result = try await ChatStore.shared.nmEnsureRelayConversation(request)
        try requireCurrent(lease)
        if result == .missing {
            store.entries.removeValue(forKey: sessionID)
            store.pendingCreations.remove(sessionID)
            store.pendingDeletes.append(record.cid)
            try save()
            return false
        }
        // 认领失败保留预留记录；重放继续绑定原账户，而不是读取迟到回调时的身份。
        if NanoMuseAccountData.shared.owner(of: sessionID) != lease.intent.identity.account {
            try NanoMuseAccountData.shared.claim(sessionID, owner: lease.intent.identity.account)
        }
        store.entries[sessionID]?.pushedTitle = record.title
        if store.pendingCreations.remove(sessionID) != nil { try save() }
        announceMainIfNeeded(record, sessionID: sessionID)
        return result == .inserted || result == .updated
    }

    private func announceMainIfNeeded(_ record: NivoRelaySyncPage.Conversation, sessionID: String) {
        if record.kind == "main", ownMainSessionId() == nil {
            NotificationCenter.default.post(name: .nanoMuseMainChatAdopt, object: sessionID)
        }
    }

    private func reserveConversation(_ record: NivoRelaySyncPage.Conversation, localID: String?) throws -> String {
        if record.kind == "main" { store.mainCid = record.cid }
        if let localID { return localID }
        let main = record.kind == "main" ? ownMainSessionId() : nil
        let adoptsMain = main.map { store.entries[$0]?.kind != "side" } ?? false
        let identifier = (adoptsMain ? main : nil) ?? UUID().uuidString
        let own = store.entries[identifier]
        store.entries[identifier] = Entry(cid: record.cid, kind: record.kind,
            fromDevice: adoptsMain ? own?.fromDevice : record.device,
            fromDeviceName: adoptsMain ? own?.fromDeviceName : record.deviceName)
        if !adoptsMain { store.pendingCreations.insert(identifier) }
        try save()
        return identifier
    }

    private func removeConversation(_ record: NivoRelaySyncPage.Conversation, localID: String?, lease: Lease) async throws -> Bool {
        let preservesSession = localID != nil && localID == ownMainSessionId()
        if let localID {
            let edit = try NivoChatAccountAccess.beginConversationEdit([localID])
            defer { NivoScheduledRunScopes.shared.endConversationEdit(edit) }
            try await ChatStore.shared.nmApplyRelayConversationDeletion(sessionID: localID, conversationID: record.cid,
                preservesSession: preservesSession, deletedAt: Double(record.updatedAt))
            try requireCurrent(lease)
        }
        store.applyConversationDeletion(cid: record.cid, localID: localID,
            replacementCID: preservesSession ? UUID().uuidString.lowercased() : nil)
        try save()
        return localID != nil
    }

    /// One pulled text into its chat, by time (C8: a late row goes where it happened, not at the
    /// end). While that chat runs a turn here the store refuses — the row waits in `deferred` and
    /// `turnFinished` / the next pull write it. Returns true when the row is in the database.
    private func insert(_ pending: Pending, into sessionId: String, lease: Lease) async throws -> Bool {
        try requireCurrent(lease)
        // nanoMuse: 脚本和截断不一定显示聊天忙碌状态，插入也要占位至数据库提交。
        let editToken: UUID
        do { editToken = try NivoChatAccountAccess.beginConversationEdit([sessionId]) }
        catch NivoChatAccessError.busy {
            if !store.deferred.contains(where: { $0.mid == pending.mid }) { store.deferred.append(pending) }
            return false
        } catch NivoLifeError.operationConflict {
            if !store.deferred.contains(where: { $0.mid == pending.mid }) { store.deferred.append(pending) }
            return false
        }
        defer { NivoScheduledRunScopes.shared.endConversationEdit(editToken) }
        let data = try JSONEncoder().encode([ContentPart.text(pending.text)])
        let partsJSON = String(decoding: data, as: UTF8.self)
        try await ChatStore.shared.mergeRemoteMessage(
            id: pending.mid, sessionId: sessionId, role: pending.role, partsJson: partsJSON,
            createdAt: Date(timeIntervalSince1970: TimeInterval(pending.createdAt)), tokenUsageJson: nil, sortOrder: 0,
            reasoningContent: nil, streamInterruptCount: 0
        )
        try requireCurrent(lease)
        try await ChatStore.shared.nmTouchRelaySession(sessionId)
        try requireCurrent(lease)
        store.entries[sessionId]?.knownMids.insert(pending.mid)
        store.remoteMids[pending.mid] = pending.deviceName
        store.deferred.removeAll { $0.mid == pending.mid }
        return true
    }

    /// The texts that waited for a running chat, tried again. True when any went in.
    private func writeDeferred(lease: Lease) async throws -> Bool {
        var wrote = false
        for pending in store.deferred {
            try requireCurrent(lease)
            guard let sessionId = store.entries.first(where: { $0.value.cid == pending.cid })?.key else {
                store.deferred.removeAll { $0.mid == pending.mid }
                continue
            }
            if try await insert(pending, into: sessionId, lease: lease) { wrote = true }
        }
        return wrote
    }

    /// After a turn: the waiting texts go in and the open chat is told.
    private func flushDeferred() async {
        guard active else { return }
        if lifecycle.isBusy || controlIntents > 0 { pullAgain = true; return }
        var request: Lease?
        do {
            guard let lease = try beginOperation() else { return }
            request = lease
            defer { endOperation(lease) }
            let wrote = try await writeDeferred(lease: lease)
            try requireCurrent(lease)
            try save()
            guard wrote else { return }
            revision += 1
            NotificationCenter.default.post(name: .cloudSyncDidFetchChanges, object: nil)
            NotificationCenter.default.post(name: .sessionDidUpdate, object: nil)
        } catch {
            // 失败行仍在延后队列中，下次拉取或回合结束后继续重试。
            note(error, for: request)
        }
    }

    // MARK: - Sessions

    /// This phone's own conversations, as Android picks them: not iCloud copies of another device's,
    /// not the feed's, not a routine's or a goal's working session, not a session another device
    /// opened here through the hub (`task` calls, source "nanomuse-hub").
    private func eligibleSessions() async -> [ChatSession] {
        let all = await ChatStore.shared.listSessions()
        let routineSessions = Set(NanoMuseScheduler.shared.routines.compactMap(\.sessionId))
        let hiddenSources: Set<String> = ["nanomuse-routine", "nanomuse-goal", "nanomuse-hub"]
        return all.filter { session in
            if session.isRemote { return false }
            if NanoMuseFeedFlow.isFeedSession(session.id) { return false }
            if routineSessions.contains(session.id) { return false }
            if let source = session.source, hiddenSources.contains(source) { return false }
            return true
        }
    }

    /// The session the Chat tab shows, when it is a real session.
    private static func localMainSessionId() -> String? {
        guard let id = UserDefaults.standard.string(forKey: NanoMuseMainChat.key), !id.hasPrefix(NanoMuseMainChat.draftPrefix) else { return nil }
        return id
    }

    /// C10: the Chat tab's session when it may be this account's main — unowned, or already the
    /// current account's; nil while another account's conversation is still pinned there.
    private func ownMainSessionId() -> String? {
        guard let id = Self.localMainSessionId() else { return nil }
        return Self.visible(owner: owner(of: id), current: store.account) && NanoMuseAccountData.shared.shows(id) ? id : nil
    }

    private static func defaultModelId() -> String {
        ProviderConfigStore.shared.defaultPrimaryGroupId ?? LLMModel.claudeHaiku45.id
    }

    @discardableResult
    private func ensureEntry(for session: ChatSession, isMain: Bool) -> Entry {
        if let entry = store.entries[session.id] { return entry }
        var kind = "side"
        if isMain {
            // One main per account: ours is main while no other local session already holds the shared cid.
            if let mainCid = store.mainCid, store.entries.contains(where: { $0.value.cid == mainCid }) {
                kind = "side"
            } else {
                kind = "main"
            }
        }
        let cid: String
        if kind == "main", let mainCid = store.mainCid {
            cid = mainCid
        } else {
            cid = UUID().uuidString.lowercased()
        }
        let entry = Entry(cid: cid, kind: kind, fromDevice: nil, fromDeviceName: nil, pushedTitle: nil, pushedUpdatedAt: nil, knownMids: [])
        store.entries[session.id] = entry
        revision += 1
        return entry
    }

    // MARK: - Errors

    private func note(_ error: Error, for lease: Lease? = nil) {
        if error is CancellationError { return }
        if let lease, !lifecycle.accepts(lease.intent, identity: currentIdentity) { return }
        if let cloud = error as? NanoMuseCloudError {
            if cloud.status == 401 {
                invalidateRequests()
                haltedAccount = accountKey
                lastError = AppLocalized("Sign in to sync")
                return
            }
            if cloud.status == 409 || cloud.code == "sync_off" {
                invalidateRequests()
                enabled = false
                serverEnabled = false
                lastError = nil
                return
            }
            if cloud.code == "unreachable" { return }
        }
        lastError = NanoMuseCloud.describe(error)
    }

    // MARK: - Persistence

    /// 不把不可访问的支持目录降级到临时目录，避免生成第二份空的同步状态。
    private static func syncFiles() throws -> NivoRelaySyncFile {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return NivoRelaySyncFile(url: directory.appendingPathComponent("nanomuse-sync-accounts.json"),
            legacyURL: directory.appendingPathComponent("nanomuse-sync.json"))
    }

    /// 只读界面保留错误，网络及账户操作使用可抛错入口阻止空表继续上传。
    private func load() {
        do { try loadChecked() } catch { note(error) }
    }

    private func loadChecked(activateAccount: Bool = true) throws {
        if !loaded {
            try checkpoint.load(from: Self.syncFiles())
            store = tables.stores[tables.current] ?? Store(account: tables.current)
        }
        let account = accountKey
        guard activateAccount, !account.isEmpty else { return }
        if tables.current != account {
            guard !lifecycle.isBusy else { throw NivoLifeError.accountChanged }
            try activate(account)
        }
        if haltedAccount != nil, haltedAccount != account { haltedAccount = nil }
    }

    /// 内存候选与磁盘共同发布；失败恢复最后确认的表，游标和延后队列均可重试。
    private func save() throws {
        guard loaded, !store.account.isEmpty else { throw NivoLifeError.corruptStore }
        var candidate = tables
        if store.account == accountKey, let main = Self.localMainSessionId(), store.entries[main] != nil {
            store.mainSession = main
        }
        candidate.stores[store.account] = store
        candidate.current = store.account
        do {
            try checkpoint.commit(candidate, to: Self.syncFiles())
        } catch {
            store = tables.stores[store.account] ?? Store(account: store.account)
            throw error
        }
    }
}
