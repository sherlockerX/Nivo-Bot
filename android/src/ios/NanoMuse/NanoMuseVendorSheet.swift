//
//  NanoMuseVendorSheet.swift
//  nanoMuse
//
//  A provider of one's own from the catalogue (contract C11, docs/parity.md item 32): the
//  sheet opens on one vendor — paste its key (*Get a key* opens the vendor's key page), or
//  sign in with a plan one already pays for (ChatGPT through upstream's Codex OAuth, Claude,
//  OpenRouter, Kimi's device code) — and the provider is added with the vendor's endpoint,
//  its models fetched, a group named after it made the chat default when the person had
//  none. Every vendor of `providers.json` (or of the relay's guidance) goes through here;
//  the two-preset `NanoMuseOwnKeySheet` is what it replaces. Android: OwnKeyPresets +
//  upstream's AddProviderScreen with `?preset=`.
//

import SwiftUI

/// Adding a catalogue vendor to the phone: the instance, the key or the sign-in, the defaults.
@MainActor
enum NanoMuseVendorSetup {
    /// `https://api.deepseek.com/v1` → (`https://api.deepseek.com`, true): upstream keeps the
    /// `/v1` as a switch beside the base.
    static func split(_ endpoint: String) -> (base: String, appendV1: Bool) {
        var e = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while e.hasSuffix("/") { e.removeLast() }
        if e.lowercased().hasSuffix("/v1") { return (String(e.dropLast(3)), true) }
        return (e, false)
    }

    /// The upstream type a sign-in runs under: Kimi's device code has a type of its own; the others their vendor's.
    static func providerType(_ vendor: NanoMuseVendor, auth: String?) -> ProviderType {
        if auth == NanoMuseCatalogue.authKimi { return .kimiCode }
        if auth == NanoMuseCatalogue.authOpenRouter { return .openRouter }
        return vendor.providerType
    }

    /// The instance of this vendor already on the phone, if any: by the endpoint's host for an
    /// OpenAI-shaped one, by the type for upstream's own (OpenRouter, Anthropic, Gemini, xAI,
    /// Kimi), never the relay's.
    static func existingInstance(_ vendor: NanoMuseVendor, auth: String?, mainland: Bool) -> ProviderInstance? {
        let cloudId = NanoMuseCloud.instance?.id
        let type = providerType(vendor, auth: auth)
        let credential: ProviderCredential = auth == nil ? .apiKey : .oauth
        let hosts = Set([vendor.baseURL, vendor.baseURLGlobal ?? ""].compactMap(NanoMuseProxy.hostOf))
        return ProviderConfigStore.shared.instances.first { inst in
            guard inst.id != cloudId, inst.providerType == type, inst.credentialType == credential else { return false }
            if type == .openAI && auth == nil {
                guard let host = NanoMuseProxy.hostOf(inst.customBaseURL ?? "") else { return false }
                return hosts.contains(host)
            }
            return true
        }
    }

    /// The vendor answered the key with 401 or 403: the key is not kept, the sheet says why.
    struct Refused: LocalizedError {
        let status: Int
        let vendorMessage: String
        var errorDescription: String? {
            NanoMuseMediaWords.refused(status: status, vendorMessage: vendorMessage) + " " + AppLocalized("Check the key and paste it again.")
        }
    }

    /// 先在内存中探测新密钥；新实例、模型和默认组共同保存，原有实例只在探测后替换未变化的密钥。
    @discardableResult
    static func install(_ vendor: NanoMuseVendor, apiKey: String, mainland: Bool, chinese: Bool,
                        sourceScope: NivoOAuthScope,
                        onRestoreFinished: (@MainActor (NivoOAuthScope) -> Void)? = nil) async throws -> ProviderInstance? {
        try NivoOAuthAccess.validateScope(sourceScope)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let existing = existingInstance(vendor, auth: nil, mainland: mainland)
        let inst: ProviderInstance = existing ?? {
            let (base, v1) = split(vendor.baseURL(mainland: mainland))
            return ProviderInstance(label: vendor.displayName(chinese: chinese), providerType: vendor.providerType, credentialType: .apiKey, customBaseURL: base.isEmpty ? nil : base, appendV1Suffix: v1)
        }()
        let previousKey: NivoCredentialSyncKeychain.ProviderSnapshot?
        if existing != nil { previousKey = try NivoCredentialSyncKeychain.providerSnapshot(instanceID: inst.id) }
        else { previousKey = nil }
        var models: [LLMModel] = []
        do {
            models = try await ProviderConfigStore.fetchModelsWithFallback(inst, forceRefresh: true,
                apiKeyOverride: key, rejectUnauthorized: true).models
        } catch {
            try NivoOAuthAccess.validateScope(sourceScope)
            if let refusal = refusal(error) { throw refusal }
            // 不提供模型列表的端点仍允许保存，后续刷新沿用原有目录回退规则。
        }
        try NivoOAuthAccess.validateScope(sourceScope)
        if existing == nil {
            if models.isEmpty { models = ModelsDevAPI.fetchModels(forBaseURL: vendor.baseURL(mainland: mainland)) }
            try await NivoProviderJSONImport.create(inst, apiKey: key, sourceScope: sourceScope, models: models,
                defaultChatModel: vendor.defaults["chat"] ?? "", onRestoreFinished: onRestoreFinished)
            return inst
        }
        try await NivoProviderJSONImport.update(inst, models: models, defaultChatModel: vendor.defaults["chat"] ?? "",
            apiKey: key, expectedKey: previousKey, sourceScope: sourceScope, onRestoreFinished: onRestoreFinished)
        return inst
    }

    /// 401 / 403 from the models fetch, as upstream's APIs report them: `LLMError.invalidAPIKey`
    /// ("OpenAI HTTP 401: {…}") or, for Anthropic, `providerError` ("Failed to fetch models (401): …").
    static func refusal(_ error: Error) -> Refused? {
        if let refusal = error as? Refused { return refusal }
        guard let llm = error as? LLMError else { return nil }
        let text: String
        switch llm {
        case .invalidAPIKey(let detail): text = detail.isEmpty ? "HTTP 401" : detail
        case .providerError(let message): text = message
        default: return nil
        }
        guard let r = text.range(of: "(HTTP |\\()(401|403)", options: .regularExpression) else {
            if case .invalidAPIKey = llm { return Refused(status: 401, vendorMessage: NanoMuseProviderReach.vendorMessage(text)) }
            return nil
        }
        let status = Int(text[r].suffix(3)) ?? 401
        return Refused(status: status, vendorMessage: NanoMuseProviderReach.vendorMessage(text))
    }

    /// 本机无密钥端点也等待配置落盘，使用空鉴权探测模型，不创建空Keychain条目。
    @discardableResult
    static func installLocal(_ vendor: NanoMuseVendor, address: String, chinese: Bool, sourceScope: NivoOAuthScope,
                             onRestoreFinished: (@MainActor (NivoOAuthScope) -> Void)? = nil) async throws -> ProviderInstance? {
        try NivoOAuthAccess.validateScope(sourceScope)
        let (base, v1) = split(address)
        guard let url = URL(string: base), url.host != nil,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let inst = ProviderInstance(label: vendor.displayName(chinese: chinese), providerType: .openAI, credentialType: .apiKey, customBaseURL: base, appendV1Suffix: v1)
        let models = (try? await ProviderConfigStore.fetchModelsForInstance(inst, forceRefresh: true, apiKeyOverride: "")) ?? []
        try NivoOAuthAccess.validateScope(sourceScope)
        try await NivoProviderJSONImport.create(inst, apiKey: nil, sourceScope: sourceScope, models: models,
            defaultChatModel: vendor.defaults["chat"] ?? "", onRestoreFinished: onRestoreFinished)
        return inst
    }

    /// 登录任务使用表单固定的实例身份，配置失败后可重试，不提前发布未保存的实例。
    @discardableResult
    static func signIn(_ vendor: NanoMuseVendor, auth: String, instanceID: String, mainland: Bool, chinese: Bool,
                       sourceScope: NivoOAuthScope,
                       onRestoreFinished: (@MainActor (NivoOAuthScope) -> Void)? = nil) async throws -> ProviderInstance? {
        try NivoOAuthAccess.validateScope(sourceScope)
        let existing = existingInstance(vendor, auth: auth, mainland: mainland)
        guard existing == nil || existing?.id == instanceID else { throw NivoPersonalBackupError.snapshotChanged }
        let id = instanceID
        switch auth {
        case NanoMuseCatalogue.authChatGPT: try await CodexOAuthManager.shared.login(instanceId: id)
        case NanoMuseCatalogue.authClaude: try await ClaudeOAuthManager.shared.login(instanceId: id)
        case NanoMuseCatalogue.authOpenRouter: try await OpenRouterOAuthManager.shared.login(instanceId: id)
        default: return nil
        }
        try NivoOAuthAccess.validateScope(sourceScope)
        if let existing, ProviderConfigStore.shared.instance(for: id) != existing { throw NivoPersonalBackupError.snapshotChanged }
        return try await finishSignIn(vendor, auth: auth, instanceId: id, mainland: mainland, chinese: chinese,
            sourceScope: sourceScope, onRestoreFinished: onRestoreFinished)
    }

    /// 设备码和浏览器授权共用配置提交入口，期间恢复或切号会使旧完成回调失效。
    @discardableResult
    static func finishSignIn(_ vendor: NanoMuseVendor, auth: String, instanceId id: String, mainland: Bool, chinese: Bool,
                             sourceScope: NivoOAuthScope,
                             onRestoreFinished: (@MainActor (NivoOAuthScope) -> Void)? = nil) async throws -> ProviderInstance? {
        try NivoOAuthAccess.validateScope(sourceScope)
        let store = ProviderConfigStore.shared
        if let existing = store.instance(for: id) {
            try await finishExisting(existing, vendor: vendor, sourceScope: sourceScope, onRestoreFinished: onRestoreFinished)
            return existing
        }
        let inst = ProviderInstance(id: id, label: NanoMuseCatalogue.planName(auth: auth, vendor: vendor, chinese: chinese),
            providerType: providerType(vendor, auth: auth), credentialType: .oauth)
        let models = (try? await ProviderConfigStore.fetchModelsForInstance(inst, forceRefresh: true)) ?? []
        try NivoOAuthAccess.validateScope(sourceScope)
        try await NivoProviderJSONImport.createOAuth(inst, sourceScope: sourceScope, models: models,
            defaultChatModel: vendor.defaults["chat"] ?? "", onRestoreFinished: onRestoreFinished)
        return inst
    }

    /// 已有实例保留用户模型修改；等待写盘及发送登记，失败向原表单传播。
    private static func finishExisting(_ instance: ProviderInstance, vendor: NanoMuseVendor,
                                       sourceScope: NivoOAuthScope,
                                       onRestoreFinished: (@MainActor (NivoOAuthScope) -> Void)?) async throws {
        let models = (try? await ProviderConfigStore.fetchModelsWithFallback(instance, forceRefresh: true).models) ?? []
        try NivoOAuthAccess.validateScope(sourceScope)
        try await NivoProviderJSONImport.update(instance, models: models, defaultChatModel: vendor.defaults["chat"] ?? "",
            sourceScope: sourceScope, onRestoreFinished: onRestoreFinished)
    }
}

/// One vendor: its key, or its sign-in. Opened from the ways-on card and the account page.
struct NanoMuseVendorSheet: View {
    let vendor: NanoMuseVendor
    /// The sign-in to lead with (`oauth-chatgpt` …), or nil for the key.
    var signIn: String? = nil
    var onDone: (ProviderInstance?) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var address = ""
    @State private var busy = false
    @State private var message: String?
    @State private var kimi = false
    @State private var kimiInstanceId = UUID().uuidString
    @State private var browserInstanceId = UUID().uuidString
    @State private var formScope: NivoOAuthScope?
    // 新实例草稿与已有实例登录分开记录，页面关闭只清理前者。
    @State private var oauthDraftID: String?
    @State private var oauthInstanceID: String?
    @State private var oauthTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var hasLeft = false
    /// The provider just saved: the form gives way to the "Use it for" card (0.1.41).
    @State private var saved: ProviderInstance?

    private var mainland: Bool { NanoMuseRegion.isMainland }
    private var chinese: Bool { NanoMuseCatalogue.chinese }
    private var name: String { vendor.displayName(chinese: chinese) }
    private var auth: String? { signIn ?? vendor.signIn }

    var body: some View {
        NavigationStack {
            Group {
                if let saved {
                    NanoMuseUseItForView(instance: saved) {
                        guard canComplete(saved) else { return }
                        onDone(saved)
                        dismiss()
                    }
                } else {
                    form
                }
            }
            .sheet(isPresented: $kimi) {
                let identifier = kimiInstanceId
                let sourceScope = formScope
                KimiDeviceLoginSheet(instanceId: identifier, sourceScope: sourceScope) { success in
                    guard success, !hasLeft else { return }
                    startSave(isOAuth: true) { await finishKimi(identifier, sourceScope: sourceScope) }
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .onAppear {
            hasLeft = false
            if formScope == nil { formScope = NivoOAuthAccess.captureScope() }
        }
        .onDisappear { abandonOAuth() }
    }

    /// After a save: the "Use it for" card when the provider can take a slot, else straight out.
    private func finish(_ inst: ProviderInstance?) {
        if let inst, oauthDraftID == inst.id {
            NivoOAuthDraftHost.shared.complete(instanceID: inst.id)
            oauthDraftID = nil
        }
        // 保存可能在系统关闭后完成，只结算草稿，不再展示用途卡片或调用导航回调。
        guard canCompleteInCurrentScope else { return }
        if let inst, !canComplete(inst) { return }
        if let inst, NanoMuseUseItForView.worthAsking(inst) {
            saved = inst
        } else {
            onDone(inst)
            dismiss()
        }
    }

    /// 保存后发生账户或配置恢复时，旧页面只结算保存，不向新界面传递旧实例。
    private func canComplete(_ instance: ProviderInstance) -> Bool {
        guard canCompleteInCurrentScope else { return false }
        return ProviderConfigStore.shared.instance(for: instance.id) == instance
    }

    private var canCompleteInCurrentScope: Bool {
        guard !hasLeft, let formScope else { return false }
        do { try NivoOAuthAccess.validateScope(formScope); return true }
        catch { return false }
    }

    private var form: some View {
        Form {
            if let auth {
                Section {
                    Button {
                        if auth == NanoMuseCatalogue.authKimi {
                            if let identifier = beginOAuth(auth, proposedID: kimiInstanceId) {
                                kimiInstanceId = identifier
                                kimi = true
                            }
                        } else {
                            startSave(isOAuth: true) { await runSignIn(auth) }
                        }
                    } label: {
                        HStack {
                            Label(String(format: AppLocalized("Sign in with %@"), NanoMuseCatalogue.planName(auth: auth, vendor: vendor, chinese: chinese)), systemImage: "person.crop.circle.badge.checkmark")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy)
                } header: {
                    Text(AppLocalized("A plan you already pay for"))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let message { Text(message).foregroundStyle(.red) }
                        Text(String(format: AppLocalized("Covers %@."), NanoMuseCatalogue.covers(vendor.capabilitiesFor(auth))))
                        if auth == NanoMuseCatalogue.authChatGPT {
                            Text(NanoMuseAllowance.storedGuidance()?.caveat(chinese: chinese).nilIfEmpty ?? AppLocalized("OpenAI's terms cover using a ChatGPT plan inside OpenAI's own Codex; other apps have had this access cut off before (OpenCode, January 2026). If it stops working, an API key does."))
                        }
                    }
                }
            }
            if vendor.local {
                Section {
                    TextField(AppLocalized("Address"), text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(busy)
                    Button {
                        startSave { await saveLocal() }
                    } label: {
                        HStack {
                            Text(AppLocalized("Use this server"))
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text(AppLocalized("On a computer of your own"))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let message { Text(message).foregroundStyle(.red) }
                        Text(AppLocalized("The phone must reach the computer: the same Wi-Fi, or a tunnel. Nothing leaves your network."))
                        let note = vendor.note(chinese: chinese)
                        if !note.isEmpty { Text(note) }
                    }
                }
            }
            if vendor.takesKey {
                Section {
                    SecureField(vendor.keyHint.map { String(format: AppLocalized("Paste the API key (%@)"), $0) } ?? AppLocalized("Paste the API key"), text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(busy)
                    Button {
                        startSave { await save() }
                    } label: {
                        HStack {
                            Text(AppLocalized("Use this key"))
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let url = URL(string: vendor.keyURL(mainland: mainland)), !vendor.keyURL(mainland: mainland).isEmpty {
                        Button {
                            openURL(url)
                        } label: {
                            Label(AppLocalized("Get a key"), systemImage: "arrow.up.right.square")
                        }
                    }
                } header: {
                    Text(AppLocalized("A key of your own"))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let message {
                            Text(message).foregroundStyle(.red)
                        } else {
                            Text(String(format: AppLocalized("The key stays on this phone and is sent only to %@. Covers %@."), NanoMuseProxy.hostOf(vendor.baseURL(mainland: mainland)) ?? name, NanoMuseCatalogue.covers(vendor.capabilities)))
                        }
                        let note = vendor.note(chinese: chinese)
                        if !note.isEmpty { Text(note) }
                    }
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if address.isEmpty { address = vendor.baseURL } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalized("Cancel")) { abandonOAuth(); dismiss() }.disabled(busy)
            }
        }
    }

    private func save() async {
        guard !busy, !hasLeft, let sourceScope = formScope else { return }
        busy = true
        defer { busy = false }
        message = nil
        do {
            guard let inst = try await NanoMuseVendorSetup.install(vendor, apiKey: key, mainland: mainland, chinese: chinese,
                sourceScope: sourceScope, onRestoreFinished: { acceptOwnRestore($0, source: sourceScope) }) else {
                message = AppLocalized("Nothing to add")
                return
            }
            finish(inst)
        } catch {
            // A refused key: the sheet stays open with the vendor's answer under the field.
            message = error.localizedDescription
        }
    }

    private func saveLocal() async {
        guard !busy, !hasLeft, let sourceScope = formScope else { return }
        busy = true
        defer { busy = false }
        message = nil
        do {
            guard let inst = try await NanoMuseVendorSetup.installLocal(vendor, address: address, chinese: chinese,
                sourceScope: sourceScope, onRestoreFinished: { acceptOwnRestore($0, source: sourceScope) }) else {
                message = AppLocalized("That is not an address the phone can reach.")
                return
            }
            finish(inst)
        } catch {
            message = error.localizedDescription
        }
    }

    private func runSignIn(_ auth: String) async {
        guard !busy, !hasLeft, let sourceScope = formScope,
              let identifier = beginOAuth(auth, proposedID: browserInstanceId) else { return }
        browserInstanceId = identifier
        busy = true
        defer { busy = false }
        message = nil
        do {
            let inst = try await NanoMuseVendorSetup.signIn(vendor, auth: auth, instanceID: identifier,
                mainland: mainland, chinese: chinese, sourceScope: sourceScope,
                onRestoreFinished: { acceptOwnRestore($0, source: sourceScope) })
            finish(inst)
        } catch {
            message = error.localizedDescription
        }
    }

    private func finishKimi(_ identifier: String, sourceScope: NivoOAuthScope?) async {
        guard !busy, !hasLeft, let sourceScope else { return }
        busy = true
        defer { busy = false }
        message = nil
        do {
            let inst = try await NanoMuseVendorSetup.finishSignIn(vendor, auth: NanoMuseCatalogue.authKimi,
                instanceId: identifier, mainland: mainland, chinese: chinese, sourceScope: sourceScope,
                onRestoreFinished: { acceptOwnRestore($0, source: sourceScope) })
            finish(inst)
        } catch { message = error.localizedDescription }
    }

    /// 同一表单仅接受自身事务的代次变化，跨账户或外部恢复仍要求重新打开。
    private func acceptOwnRestore(_ current: NivoOAuthScope, source: NivoOAuthScope) {
        guard formScope == source, current.ownerKey == source.ownerKey,
              current.accountGeneration == source.accountGeneration else { return }
        formScope = current
    }

    /// 同步保留任务句柄，双击不能覆盖仍在提交的任务并提前开放草稿清理。
    private func startSave(isOAuth: Bool = false, _ operation: @escaping @MainActor () async -> Void) {
        guard saveTask == nil, !busy, !hasLeft else { return }
        let task = Task { @MainActor in
            defer { saveTask = nil; if isOAuth { oauthTask = nil } }
            await operation()
        }
        saveTask = task
        if isOAuth { oauthTask = task }
    }

    /// 授权开始前固定已有实例身份，新草稿登记失败则不允许写凭证。
    private func beginOAuth(_ auth: String, proposedID: String) -> String? {
        do {
            guard !hasLeft, let formScope else { throw CancellationError() }
            let existing = NanoMuseVendorSetup.existingInstance(vendor, auth: auth, mainland: mainland)
            let identifier = existing?.id ?? proposedID
            try NivoOAuthDraftHost.shared.begin(instanceID: identifier, isExisting: existing != nil,
                sourceScope: formScope)
            oauthInstanceID = identifier
            if existing == nil { oauthDraftID = identifier }
            return identifier
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// 返回、取消和系统关闭均撤销迟到登录，草稿移交宿主后仍有独立重试入口。
    private func abandonOAuth() {
        guard !hasLeft else { return }
        hasLeft = true
        oauthTask?.cancel()
        if let oauthInstanceID { NivoOAuthAccess.invalidate(instanceID: oauthInstanceID) }
        if let oauthDraftID {
            // 取消只表达退出意图；必须等保存提交或回滚结束后才能开放凭证清理。
            NivoOAuthDraftHost.shared.abandon(instanceID: oauthDraftID, after: saveTask ?? oauthTask)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
