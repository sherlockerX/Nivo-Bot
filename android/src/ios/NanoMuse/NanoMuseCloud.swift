import Foundation
import UIKit

/// 历史账号资料的解码结构，只用于无损迁移到本地档案。
struct NanoMuseCloudAccount: Codable, Equatable, Sendable {
    var channel: String
    var hint: String
    var granted: Int64
    var used: Int64
    var usedToday: Int64
    var dailyCap: Int64
    var checkedAt: Date
    /// The relay runs without a ceiling: usage is shown, nothing is refused for lack of tokens.
    var unlimited: Bool = false
    /// C10: the relay's opaque id of the account (`account.id` of `/v1/me`) — what the local
    /// conversations are keyed to, never the identifier. Empty from a relay that sends none.
    var id: String = ""
    /// The pool in yuan (`spend.grant` / `spend.left` of `/v1/me`) on a relay that prices in money;
    /// nil from an older relay, from the sign-in reply, or when the account has no pool.
    var grantCny: Double? = nil
    var leftCny: Double? = nil

    var remaining: Int64 { max(granted - used, 0) }
    /// The relay prices in money and this account has a pool to run out of: the Settings row
    /// says what is left of it, as the account page's headline does.
    var poolLeftCny: Double? {
        guard let grantCny, grantCny > 0, let leftCny else { return nil }
        return max(leftCny, 0)
    }
    /// 0..1 of the grant still unspent.
    var fraction: Double {
        guard granted > 0 else { return 0 }
        return min(max(Double(remaining) / Double(granted), 0), 1)
    }

    /// What is left, as the Settings card and the providers row say it: in yuan on a relay that
    /// prices in money (the account page's headline figure), in tokens on an older relay; nil
    /// when the relay runs without a ceiling, where there is nothing to count down.
    var leftLine: String? {
        if unlimited { return nil }
        if let left = poolLeftCny {
            let whole = left.rounded() == left
            return String(format: AppLocalized("%@ left"), "¥" + left.formatted(.number.precision(.fractionLength(whole ? 0 : 2))))
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let left = formatter.string(from: NSNumber(value: remaining)) ?? "\(remaining)"
        return String(format: AppLocalized("%@ left"), left)
    }

    init(channel: String, hint: String, granted: Int64, used: Int64, usedToday: Int64, dailyCap: Int64, checkedAt: Date, unlimited: Bool = false, id: String = "", grantCny: Double? = nil, leftCny: Double? = nil) {
        self.channel = channel
        self.hint = hint
        self.granted = granted
        self.used = used
        self.usedToday = usedToday
        self.dailyCap = dailyCap
        self.checkedAt = checkedAt
        self.unlimited = unlimited
        self.id = id
        self.grantCny = grantCny
        self.leftCny = leftCny
    }

    // `unlimited` and `id` came later; an account cached by an earlier build decodes without them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channel = try c.decode(String.self, forKey: .channel)
        hint = try c.decode(String.self, forKey: .hint)
        granted = try c.decode(Int64.self, forKey: .granted)
        used = try c.decode(Int64.self, forKey: .used)
        usedToday = try c.decode(Int64.self, forKey: .usedToday)
        dailyCap = try c.decode(Int64.self, forKey: .dailyCap)
        checkedAt = try c.decode(Date.self, forKey: .checkedAt)
        unlimited = try c.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        grantCny = try c.decodeIfPresent(Double.self, forKey: .grantCny)
        leftCny = try c.decodeIfPresent(Double.self, forKey: .leftCny)
    }
}

/// The relay's stable error codes (`docs/cloud.md`), or `unreachable` / `http_<status>`.
struct NanoMuseCloudError: LocalizedError, Sendable {
    let code: String
    let message: String
    let status: Int
    /// `retry_after` in seconds, when the relay said when to come back (`provider_busy`).
    var retryAfterS: Int? = nil
    /// Relay 0.22: the refusal is one of the operator's switches, not use (`paused: true` beside `allowance_exhausted`).
    var paused: Bool = false

    var errorDescription: String? { NanoMuseCloud.describe(self) }
}

@MainActor
enum NanoMuseCloud {
    nonisolated static let defaultBase = ""
    static let label = "nanoMuse Cloud"

    private enum Keys {
        static let base = "nanomuse.cloud.base"
        static let instance = "nanomuse.cloud.instance_id"
        static let account = "nanomuse.cloud.account"
        static let fresh = "nanomuse.cloud.fresh_account"
        /// The relay refused the key and the account's data was kept aside (C12); the sign-in page says so until the next sign-in.
        static let ended = "nanomuse.cloud.sign_in_ended"
    }

    /// True after a sign-in that created the account, until the first run's password page was answered.
    static var freshAccount: Bool { UserDefaults.standard.bool(forKey: Keys.fresh) }

    /// True after the relay refused the phone's key and the account's data was put aside (C12)
    /// — the sign-in page tells the person so — until the next sign-in.
    static var signInEnded: Bool { UserDefaults.standard.bool(forKey: Keys.ended) }
    static func clearFreshAccount() { UserDefaults.standard.removeObject(forKey: Keys.fresh) }

    typealias Account = NanoMuseCloudAccount
    typealias CloudError = NanoMuseCloudError

    // MARK: - State

    /// 已移除内置账号服务，不再提供可配置的中继地址。
    static var baseURL: String { "" }

    // MARK: - Own relay

    /// What a person typed, as the base URL it means: a scheme added when none was given
    /// (https), trailing slashes gone. Nil when it is not a URL with a host.
    nonisolated static func normalizedRelay(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty, url.scheme != nil else { return nil }
        var out = text
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// A host on one's own network, where plain http is allowed. The rule is
    /// `NanoMuseProxy.isLocal`, the one the proxy's bypass applies too (and Android's `LanOnly`):
    /// parsed addresses rather than string prefixes, the private, carrier-grade, loopback,
    /// link-local and ULA ranges, `localhost`, a name without a dot, and the local suffixes
    /// with Tailscale's `.ts.net` among them.
    nonisolated static func isPrivateHost(_ host: String) -> Bool {
        NanoMuseProxy.isLocal(host)
    }

    /// Why an address cannot be used as the relay, as a sentence; nil when it can.
    nonisolated static func relayProblem(_ raw: String) -> String? {
        guard let base = normalizedRelay(raw), let url = URL(string: base), let host = url.host else {
            return AppLocalized("Enter the server's address, for example https://relay.example.org.")
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "https" { return nil }
        if scheme == "http" {
            return isPrivateHost(host) ? nil : AppLocalized("Use https unless the server is on your own network.")
        }
        return AppLocalized("Enter the server's address, for example https://relay.example.org.")
    }

    // MARK: - Phone numbers

    /// Whether a phone number cannot get a text-message code before the relay is asked: a
    /// number with a country code other than China's (+86). Bare digits are left to the relay
    /// (its `phone_region` says the same sentence); an e-mail address never qualifies.
    nonisolated static func needsEmailInstead(identifier raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.contains("@") { return false }
        let compact = text.filter { !" -()".contains($0) }
        guard compact.allSatisfy({ $0.isNumber || $0 == "+" }) else { return false }
        if compact.hasPrefix("+") { return !compact.hasPrefix("+86") }
        if compact.hasPrefix("00") { return !compact.hasPrefix("0086") }
        return false
    }

    /// The sentence for a number that cannot get a code (also `describe("phone_region")`).
    nonisolated static var phoneRegionSentence: String {
        AppLocalized("Text-message codes reach mainland-China numbers only. Use an e-mail address instead.")
    }

    /// The provider instance the relay is signed in as, if it still exists.
    static var instance: ProviderInstance? {
        guard let id = UserDefaults.standard.string(forKey: Keys.instance) else { return nil }
        return ProviderConfigStore.shared.instance(for: id, includingRetired: true)
    }

    /// 历史缓存不能重新启用账号认证或内置模型。
    static var isSignedIn: Bool { false }
    static var modelsOn: Bool { false }

    /// 旧界面的兼容入口，启用云模型明确失败，关闭保持幂等。
    @discardableResult
    static func setModelsOn(_ on: Bool) -> Bool { !on }

    static var account: Account? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Keys.account) else { return nil }
            return try? JSONDecoder().decode(Account.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Keys.account)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.account)
            }
        }
    }

    /// 内置账号的凭证不再提供给网络层，旧密钥只由本地迁移器处理。
    static var apiKey: String? { nil }

    /// 事务恢复按保存的提供商ID校验密钥，不能依赖可能还没更新的缓存账号。
    static var transitionInstanceID: String? { UserDefaults.standard.string(forKey: Keys.instance) }

    /// 从事务日志补全身份缓存；日志仅包含公有配置，不包含API密钥。
    static func restoreTransitionIdentity(_ identity: NivoAccountSwitchIdentity) throws {
        guard let encodedProvider = identity.provider, let encodedAccount = identity.account else {
            clear()
            guard UserDefaults.standard.synchronize() else { throw CocoaError(.fileWriteUnknown) }
            // 旧提供商在异步配置确认阶段删除，不能在身份缓存提交时提前清除Keychain。
            return
        }
        let provider = try JSONDecoder().decode(ProviderInstance.self, from: encodedProvider)
        let parsed = try JSONDecoder().decode(Account.self, from: encodedAccount)
        guard try identity.isApplied() else { throw NivoLifeError.accountChanged }
        try NanoMuseAccountData.removeSyncedRelayKey(instanceId: provider.id)
        let store = ProviderConfigStore.shared
        if store.instances.contains(where: { $0.id == provider.id }) { store.updateInstance(provider) }
        else { store.addInstance(provider) }
        UserDefaults.standard.set(provider.id, forKey: Keys.instance)
        account = parsed
        guard UserDefaults.standard.synchronize() else { throw CocoaError(.fileWriteUnknown) }
    }

    /// 兼容旧错误回调，不发出账号检查请求，也不移动或删除学习记录。
    static func refresh() async throws -> Account? { nil }

    /// A sentence for the person, from the relay's stable error codes.
    nonisolated static func describe(_ error: Error) -> String {
        guard let cloud = error as? CloudError else {
            if (error as NSError).domain == NSURLErrorDomain {
                return AppLocalized("Could not reach nanoMuse Cloud. Check the connection and try again.")
            }
            return error.localizedDescription
        }
        switch cloud.code {
        case "bad_identifier":
            return AppLocalized("Enter a phone number or an e-mail address.")
        case "phone_region":
            return phoneRegionSentence
        case "code_wrong":
            return AppLocalized("That code is not right.")
        case "code_expired":
            return AppLocalized("That code has expired. Ask for a new one.")
        case "code_too_often":
            return AppLocalized("A code was sent a moment ago. Wait a little before asking again.")
        case "send_failed":
            return AppLocalized("The code could not be sent. Try again in a minute.")
        case "account_disabled":
            return AppLocalized("This account has been disabled.")
        case "not_invited":
            return AppLocalized("This relay is private; that address is not on its list.")
        case "bad_key":
            return AppLocalized("This sign-in is no longer valid. Sign in again.")
        case "account_deleted":
            return AppLocalized("This account was deleted. Sign in again to start a new one.")
        case "out_of_tokens":
            return AppLocalized("The starter allowance is used up. Add a provider of your own to keep going.")
        case "allowance_exhausted" where cloud.paused:
            // relay 0.22: the operator's switch, not use — the same card, another lead
            return AppLocalized("The free allowance is paused on this relay for now. It is not used up. Add a key of your own or sign in with a plan you already pay for, under Settings → nanoMuse Cloud. Your sign-in, your devices and what is left stay as they are.")
        case "allowance_exhausted":
            return AppLocalized("The free allowance is used up. Use a key of your own, or invite a friend; both are under nanoMuse Cloud in Settings.")
        case "too_large":
            return AppLocalized("That message is too large for the model. Shorten it, leave out some attachments, or start a new chat.")
        case "content_rejected":
            return AppLocalized("The model provider's content check declined this request. Try different words, or start a new chat if it keeps happening: the words it objects to can be earlier in the conversation.")
        case "too_many_in_flight":
            return AppLocalized("Too many requests at once. Try again shortly.")
        case "provider_busy":
            if let s = cloud.retryAfterS, s > 0 {
                return String(format: AppLocalized("The model provider is busy right now. Try again in %@."), NanoMuseProviderReach.duration(s))
            }
            return AppLocalized("The model provider is busy right now. Try again in a moment.")
        case "locked":
            // the password endpoints: too many wrong passwords in a row, not too many requests
            return AppLocalized("Too many wrong attempts. Wait a few minutes, or sign in with a code.")
        case "model_not_offered":
            return AppLocalized("nanoMuse Cloud no longer offers that model. Pick another under Settings → nanoMuse Cloud.")
        case "service_paused":
            return AppLocalized("nanoMuse Cloud is paused by its operator for now; your sign-in and your data are kept. Try again later.")
        case "sync_paused":
            return AppLocalized("Conversation sync is paused on this relay for now; what is stored is kept, and your devices keep working on their own.")
        case "hub_paused":
            return AppLocalized("The device hub is paused on this relay for now; each device keeps working on its own.")
        case "upstream":
            return AppLocalized("nanoMuse Cloud did not answer. Try again in a moment.")
        // The relay's password codes (cloud/nanomuse_cloud/service.py): a 401 `bad_credentials`
        // at sign-in for a wrong address or password, `password_wrong` when the current password
        // given while changing or removing it is not the one set, `no_password` for an account
        // that has none yet, `password_required` when the current one was left out, and
        // `password_short`, `password_long`, `password_weak` from the rules for a new one.
        case "bad_credentials":
            return AppLocalized("Wrong phone number, e-mail or password.")
        case "password_wrong":
            return AppLocalized("That password is not right.")
        case "no_password":
            return AppLocalized("This account has no password yet. Sign in with a code and set one under nanoMuse Cloud.")
        case "password_required":
            return AppLocalized("Enter the current password first.")
        case "password_short":
            return AppLocalized("Use eight characters or more.")
        case "password_weak":
            return AppLocalized("Use a few different characters, not the address itself.")
        case "password_long":
            return AppLocalized("That password is too long.")
        case "invite_bad":
            return AppLocalized("That invite code is not one we know. Check it, or leave it empty.")
        case "signup_closed":
            return AppLocalized("Sign-ups are paused on this relay for now. An account that already exists can still sign in.")
        case "domain_limited":
            return AppLocalized("Today's sign-up limit for addresses at that domain is reached on this relay. Try again tomorrow, or use another address.")
        case "channel_unsupported":
            return AppLocalized("This relay does not send codes to that kind of address. Use the other kind (e-mail or phone number), or sign in with a password.")
        case "daily_cap":
            return AppLocalized("Today's allowance is used up. It resets tomorrow.")
        case "rate_limited":
            return AppLocalized("Too many requests at once. Try again shortly.")
        case "unreachable":
            return AppLocalized("Could not reach nanoMuse Cloud. Check the connection and try again.")
        default:
            // a code we do not know: the status says what kind of thing it was
            switch cloud.status {
            case 413: return AppLocalized("That message is too large for the model. Shorten it, leave out some attachments, or start a new chat.")
            case 401: return AppLocalized("This sign-in is no longer valid. Sign in again.")
            case 500...: return AppLocalized("nanoMuse Cloud did not answer. Try again in a moment.")
            default: break
            }
            let bare = cloud.message.isEmpty || cloud.message.hasPrefix("HTTP ")
            return bare ? AppLocalized("nanoMuse Cloud could not complete the request.") : cloud.message
        }
    }

    // MARK: - Internals

    /// After the key: a default group if the user has none. Nothing of the user's own is
    /// replaced — someone who already has a key and a group keeps them and gets the relay as
    /// one more provider.
    static func parseAccount(_ reply: [String: Any]) -> Account {
        let account = reply["account"] as? [String: Any] ?? [:]
        let tokens = reply["tokens"] as? [String: Any] ?? [:]
        let spend = reply["spend"] as? [String: Any] ?? [:]
        func int64(_ value: Any?) -> Int64 {
            if let n = value as? NSNumber { return n.int64Value }
            if let s = value as? String { return Int64(s) ?? 0 }
            return 0
        }
        func money(_ value: Any?) -> Double? {
            if let n = value as? NSNumber { return n.doubleValue }
            if let s = value as? String { return Double(s) }
            return nil
        }
        return Account(
            channel: account["channel"] as? String ?? "",
            hint: account["hint"] as? String ?? "",
            granted: int64(tokens["granted"]),
            used: int64(tokens["used"]),
            usedToday: int64(tokens["used_today"]),
            dailyCap: int64(tokens["daily_cap"]),
            checkedAt: Date(),
            unlimited: (tokens["unlimited"] as? Bool) ?? ((tokens["unlimited"] as? NSNumber)?.boolValue ?? false),
            id: account["id"] as? String ?? "",
            grantCny: money(spend["grant"]),
            leftCny: money(spend["left"])
        )
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: Keys.instance)
        UserDefaults.standard.removeObject(forKey: Keys.account)
        UserDefaults.standard.removeObject(forKey: Keys.fresh)
        NanoMuseRelayMenu.forget()
        NanoMuseAllowance.shared.forget() // the pinned card, the heads-up and the guidance were this account's
        // another account's devices and their connections are not ours to list
        NanoMuseProfileSync.shared.forget()
        NanoMuseSync.shared.accountChanged() // C10: signed out — the presence of the account that left goes too
    }

    /// 旧同步模块的兼容调用明确拒绝，应用内不再保留账号HTTP传输实现。
    static func call(_ method: String, _ path: String, body: [String: Any]?, token: String?) async throws -> [String: Any] {
        throw NivoLocalModeError.cloudRemoved
    }
}
