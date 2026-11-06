import Foundation

/// 通话独立保存语音模型配置，密钥始终复用服务商钥匙串。
struct NanoMuseCallSettings: Codable {
    var providerId = ""
    var endpoint = ""
    var asrModel = "fun-asr-realtime"
    var ttsModel = "cosyvoice-v3-flash"
    var voice = "longanyang"
    var silenceMs = 800
    private static let STORAGE_KEY = "nanomuse.call.settings"

    /// 去掉粘贴模型名时附带的空白，避免校验通过后请求使用另一名称。
    var normalized: Self {
        var value = self
        value.providerId = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        value.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        value.asrModel = asrModel.trimmingCharacters(in: .whitespacesAndNewlines)
        value.ttsModel = ttsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        value.voice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    /// 读取设置；损坏或旧版数据回到可编辑的默认配置。
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: STORAGE_KEY),
              let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return settings
    }

    /// 保存非敏感设置，服务商密钥不进入UserDefaults。
    func save() {
        if let data = try? JSONEncoder().encode(normalized) { UserDefaults.standard.set(data, forKey: Self.STORAGE_KEY) }
    }

    /// 只列出启用的百炼服务商，由用户选择与区域匹配的已有凭证。
    @MainActor static var providers: [ProviderInstance] {
        ProviderConfigStore.shared.instances.filter {
            $0.isEnabled && NanoMuseBailianVoice.isModelStudio($0.effectiveCustomBaseURL ?? "")
        }
    }

    /// 校验地址与模型，并保证密钥不会发送到另一服务商的主机。
    @MainActor func connection() throws -> (URL, String) {
        let provider = Self.providers.first { $0.id == providerId }
            ?? (providerId.isEmpty ? Self.providers.first : nil)
        guard let provider,
              let key = ProviderKeychainHelper.loadAPIKey(instanceId: provider.id, caller: "NanoMuseCall"),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: AppLocalized("Add a Model Studio provider with an API key before calling."))
        }
        let derived = try NanoMuseDashScope.endpoint(forBase: provider.effectiveCustomBaseURL ?? "")
        let address = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = address.isEmpty ? derived : URL(string: address),
              url.scheme == "wss", url.host == derived.host,
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.path == "/api-ws/v1/inference" else {
            throw Failure(message: AppLocalized("The call address must use the selected provider's secure WebSocket host."))
        }
        let asr = asrModel.lowercased()
        guard (asr.hasPrefix("fun-asr") || asr.hasPrefix("paraformer")) && asr.contains("realtime"),
              !asr.contains("8k"),
              ttsModel.lowercased().hasPrefix("cosyvoice"),
              !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (200...6000).contains(silenceMs) else {
            throw Failure(message: AppLocalized("Choose a real-time Fun-ASR or Paraformer model, a CosyVoice model and a matching voice."))
        }
        if ttsModel.lowercased().contains("v3.5"), voice == "longanyang" {
            throw Failure(message: AppLocalized("CosyVoice v3.5 needs a cloned or designed voice. Use a voice that matches your model."))
        }
        return (url, key)
    }

    /// 可显示给用户的通话设置错误。
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
