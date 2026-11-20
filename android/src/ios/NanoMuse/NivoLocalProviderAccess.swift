import Foundation

extension ProviderInstance {
    /// 旧服务实例只保留本地配置，不能参与聊天、语音、图像或自动模型刷新。
    var nmIsRetiredCloudProvider: Bool {
        if UserDefaults.standard.string(forKey: "nanomuse.cloud.instance_id") == id { return true }
        return NivoRetiredProviderPolicy.shared.blocks(id: id, baseURL: customBaseURL)
    }
}
