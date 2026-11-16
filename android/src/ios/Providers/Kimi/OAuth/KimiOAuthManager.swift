import Foundation

/// Kimi Code / Coding Plan OAuth via RFC 8628 Device Authorization Grant.
///
/// Structure mirrors `CodexOAuthManager` (per-instance Keychain, on-demand
/// refresh with a 5-minute buffer), but the login flow is device-code (no
/// browser redirect) and refresh-failure resolution goes through the pure,
/// unit-tested `KimiOAuthRefreshCoordinator` (compare-before-delete single-flight
/// backstop) so we don't regress the Anthropic refresh-race class of bug.
///
/// ⚠️ Client ID: this uses the OFFICIAL Kimi Code OAuth client, made configurable
/// (not hardcoded in logic) so it can be swapped for a publicly-registrable
/// third-party client when one exists. See the Kimi Code OAuth design notes §7 for the
/// accepted risk. We do NOT copy CLIProxyAPI's registration and do NOT implement
/// anything to circumvent official limits.
@MainActor
final class KimiOAuthManager: ObservableObject {
    static let shared = KimiOAuthManager()
    private init() {}

    private let logger = AppLogger(category: "KimiOAuth")

    /// Refresh this many seconds before expiry (matches Codex/Claude).
    private let refreshBuffer: TimeInterval = 5 * 60

    /// The official Kimi Code OAuth client id (the one the first-party Kimi Code
    /// CLI uses, observed via CLIProxyAPI's public source). Per the recorded
    /// product decision (Kimi Code OAuth design notes §7): use the official client
    /// with the risk documented — NOT a copied CLIProxyAPI registration, and
    /// nothing here circumvents official rate/usage limits. Kept overridable via
    /// the `KimiOAuthClientID` Info.plist key so it can be swapped for a
    /// publicly-registrable third-party client if/when one exists; an explicit
    /// empty override disables login.
    static let officialClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"

    var clientID: String {
        if let override = Bundle.main.object(forInfoDictionaryKey: "KimiOAuthClientID") as? String {
            return override
        }
        return Self.officialClientID
    }

    var isLoginAvailable: Bool { !clientID.isEmpty }

    // MARK: - Instance-level single-flight refresh

    /// One in-flight refresh Task per instanceId — concurrent callers await the
    /// same refresh instead of each firing a token POST (dedup by instance).
    // nanoMuse: 与其他提供商共用带代次和取消校验的生产单飞器。
    private let nmRefreshFlights = OAuthRefreshSingleFlight<KimiTokenStorage>()

    // MARK: - Status accessors (never log token material)

    func isAuthenticated(instanceId: String) -> Bool {
        ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: KimiTokenStorage.self)?.accessToken != nil
    }

    func maskedToken(instanceId: String) -> String? {
        guard let token = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: KimiTokenStorage.self)?.accessToken,
              token.count > 8 else { return nil }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    func logout(instanceId: String) {
        // nanoMuse: 网络即使忽略Task取消，保存屏障仍会拒绝迟到凭证。
        NivoOAuthAccess.invalidate(instanceID: instanceId)
        nmRefreshFlights.invalidate(instanceId: instanceId)
        ProviderKeychainHelper.deleteOAuthToken(instanceId: instanceId)
    }

    // MARK: - Device-code login

    /// Callback surface for the minimal device-code UI: present the user code +
    /// verification URL while `perform` polls in the background.
    struct DeviceLoginPresentation {
        let userCode: String
        let verificationURL: String
    }

    /// Start the device flow: request a device code and hand the presentation
    /// back to the caller (UI), then poll until success/failure. On success the
    /// credentials are persisted to the Keychain for `instanceId`.
    func login(
        instanceId: String,
        // nanoMuse: 展示回调属于主线程，页面无需另开不受取消约束的任务。
        present: @escaping @MainActor (DeviceLoginPresentation) -> Void
    ) async throws {
        // nanoMuse: 设备码登录与浏览器登录使用相同的账户和恢复身份。
        let nmOperation = try NivoOAuthAccess.begin(instanceID: instanceId, replacing: true)
        defer { NivoOAuthAccess.finish(nmOperation) }
        logger.info("Kimi device login START (instance: \(instanceId), clientIDset=\(isLoginAvailable))")
        guard isLoginAvailable else {
            throw LLMError.invalidAPIKey(detail: "Kimi: OAuth client ID not configured — login unavailable")
        }
        let auth = try await requestDeviceAuthorization()
        // nanoMuse: 设备码不写调试日志，返回后先核对本次授权仍然有效。
        try NivoOAuthAccess.validate(nmOperation)
        logger.info("Kimi device authorization received")
        present(.init(userCode: auth.userCode, verificationURL: auth.openURL))
        let token = try await pollForToken(deviceCode: auth.deviceCode,
                                            interval: auth.interval,
                                            expiresIn: auth.expiresIn)
        let deviceId = UUID().uuidString
        let storage = KimiTokenStorage(
            accessToken: token.access,
            refreshToken: token.refresh,
            expireDate: token.expiresIn.map { Date().addingTimeInterval($0) },
            deviceId: deviceId,
            lastRefresh: Date()
        )
        // nanoMuse: 保存失败向调用方传播，不能报告登录或刷新成功。
        try NivoOAuthAccess.validate(nmOperation)
        try ProviderKeychainHelper.saveOAuthToken(storage, instanceId: instanceId)
        logger.info("Kimi device login complete (instance: \(instanceId))")
    }

    private func requestDeviceAuthorization() async throws -> KimiDeviceFlow.DeviceAuthorization {
        let url = URL(string: KimiDeviceFlow.authHost + KimiDeviceFlow.deviceAuthorizationPath)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // auth.kimi.com is a standard RFC 8628 endpoint: it parses
        // application/x-www-form-urlencoded, NOT JSON. A JSON body makes the
        // server see no `client_id` → 400 "client_id is required". And it
        // rejects ANY explicit scope for this client ("invalid_scope") — the
        // device-code request must omit `scope` entirely. (Verified against the
        // live endpoint 2026-07-23.)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(["client_id": clientID])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyErr = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
            throw LLMError.providerError(message: "Kimi device authorization failed: HTTP \(code)\(bodyErr.map { " — \($0)" } ?? "")")
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return try KimiDeviceFlow.parseDeviceAuthorization(json)
    }

    /// application/x-www-form-urlencoded body (RFC 8628 / OAuth token endpoints).
    private static func formEncode(_ params: [String: String]) -> Data {
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        // `+`-encode spaces per the form-url spec (URLComponents leaves them as %20,
        // which servers accept, but be explicit for any strict parser).
        return (comps.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()
    }

    private func pollForToken(
        deviceCode: String, interval: TimeInterval, expiresIn: TimeInterval
    ) async throws -> (access: String, refresh: String?, expiresIn: TimeInterval?) {
        var currentInterval = interval
        let deadline = Date().addingTimeInterval(expiresIn)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(currentInterval * 1_000_000_000))
            let (json, httpOK) = try await postToken(params: [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": deviceCode,
                "client_id": clientID,
            ])
            switch KimiDeviceFlow.classifyPoll(json: json, httpOK: httpOK) {
            case let .success(access, refresh, exp):
                return (access, refresh, exp)
            case .pending:
                continue
            case .slowDown:
                currentInterval = KimiDeviceFlow.bumpedInterval(currentInterval)
            case let .denied(msg):
                throw LLMError.providerError(message: "Kimi login denied: \(msg)")
            case let .expired(msg):
                throw LLMError.providerError(message: "Kimi login code expired: \(msg)")
            case let .fatal(msg):
                throw LLMError.providerError(message: "Kimi login failed: \(msg)")
            }
        }
        throw LLMError.providerError(message: "Kimi login timed out")
    }

    // MARK: - On-demand access token (with single-flight refresh)

    func validAccessToken(instanceId: String) async throws -> String {
        // nanoMuse: 刷新完成后再验证返回值归属，不让旧调用带着新账户凭证继续执行。
        let nmOperation = try NivoOAuthAccess.begin(instanceID: instanceId)
        guard let storage = try ProviderKeychainHelper.loadOAuthTokenStrict(instanceId: instanceId, as: KimiTokenStorage.self) else {
            throw LLMError.invalidAPIKey(detail: "Kimi: no OAuth token found for instance \(instanceId)")
        }
        let needsRefresh = storage.refreshToken != nil
            && (storage.expireDate.map { $0.timeIntervalSinceNow <= refreshBuffer } ?? false)
        guard needsRefresh else {
            guard !storage.accessToken.isEmpty else {
                throw LLMError.invalidAPIKey(detail: "Kimi: access token is empty for instance \(instanceId)")
            }
            return storage.accessToken
        }
        let refreshed = try await refreshSingleFlight(instanceId: instanceId, current: storage)
        try NivoOAuthAccess.validate(nmOperation)
        return refreshed.accessToken
    }

    /// Dedup concurrent refreshes for the same instance to a single Task.
    private func refreshSingleFlight(instanceId: String, current: KimiTokenStorage) async throws -> KimiTokenStorage {
        // nanoMuse: 新登录不复用仍在等待网络的旧刷新。
        let nmOperation = try NivoOAuthAccess.begin(instanceID: instanceId)
        let result = try await nmRefreshFlights.run(instanceId: instanceId, generation: nmOperation.generation) { [weak self] in
            guard let self else { throw LLMError.cancelled }
            return try await self.performRefreshResolved(instanceId: instanceId, current: current, operation: nmOperation)
        }
        try NivoOAuthAccess.validate(nmOperation)
        return result
    }

    private func performRefreshResolved(instanceId: String, current: KimiTokenStorage,
                                        operation: NivoOAuthOperation) async throws -> KimiTokenStorage {
        let staleRefresh = current.refreshToken ?? ""
        do {
            let refreshed = try await performRefresh(refreshToken: staleRefresh, deviceId: current.deviceId)
            // nanoMuse: 保存失败向调用方传播，不能报告登录或刷新成功。
            try NivoOAuthAccess.validateCurrentCredential(current, operation: operation)
            try ProviderKeychainHelper.saveOAuthToken(refreshed, instanceId: instanceId)
            return refreshed
        } catch {
            // nanoMuse: 取消或退出后的错误不能触发旧凭证回退或删除新登录。
            try NivoOAuthAccess.validate(operation)
            if error is CancellationError { throw error }
            // nanoMuse: 存储错误直接传播；读取受限时也不能把当前凭证当作丢失。
            if error is NivoOAuthPersistenceError { throw error }
            let currentCredential = try ProviderKeychainHelper.loadOAuthTokenStrict(instanceId: instanceId, as: KimiTokenStorage.self)
            // Route through the pure compare-before-delete coordinator.
            return try KimiOAuthRefreshCoordinator.resolveAfterRefreshFailure(
                staleRefreshToken: staleRefresh,
                existingStorage: current,
                error: error,
                isFatal: KimiOAuthRefreshCoordinator.isRefreshTokenInvalid,
                loadCurrent: { currentCredential },
                deleteCredentials: { ProviderKeychainHelper.deleteOAuthToken(instanceId: instanceId) },
                log: { [weak self] in self?.logger.info($0) }
            )
        }
    }

    private func performRefresh(refreshToken: String, deviceId: String) async throws -> KimiTokenStorage {
        let (json, httpOK) = try await postToken(params: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        guard httpOK, let access = json["access_token"] as? String else {
            let err = (json["error"] as? String) ?? "unknown"
            throw LLMError.providerError(message: "Kimi token refresh failed: \(err)")
        }
        return KimiTokenStorage(
            accessToken: access,
            refreshToken: (json["refresh_token"] as? String) ?? refreshToken,
            expireDate: (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) },
            deviceId: deviceId,
            lastRefresh: Date()
        )
    }

    /// POST to the token endpoint; returns (json, isHTTP2xx).
    /// Form-urlencoded like the device-authorization request — a JSON body makes
    /// the server reject the grant with "unsupported_grant_type" (it can't read
    /// `grant_type` out of JSON). Verified against the live endpoint 2026-07-23.
    private func postToken(params: [String: String]) async throws -> ([String: Any], Bool) {
        let url = URL(string: KimiDeviceFlow.authHost + KimiDeviceFlow.tokenPath)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(params)
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpOK = (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? -1)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (json, httpOK)
    }
}
