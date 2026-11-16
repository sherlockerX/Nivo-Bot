import Foundation

/// 修正旧目录把默认文本能力并入专用媒体模型的情况，用户手动设置仍具有最高优先级。
enum NivoDedicatedMediaModel {
    static func modality(_ identifier: String) -> ModelModality? {
        let name = identifier.lowercased().split(separator: "/").last.map(String.init) ?? identifier.lowercased()
        let images = ["qwen-image", "gpt-image", "dall-e", "dalle-", "imagen-", "flux-", "flux."]
        if images.contains(where: { name.hasPrefix($0) }) || (name.hasPrefix("wan") && name.contains("-image")) {
            return [.textInput, .imageInput, .imageOutput]
        }
        let videos = ["sora", "veo", "kling", "hailuo", "seedance", "minimax-h"]
        if videos.contains(where: { name.hasPrefix($0) }) || (name.hasPrefix("wan") && (name.contains("t2v") || name.contains("i2v"))) {
            return [.textInput, .imageInput, .videoOutput]
        }
        return nil
    }
}

/// 聊天、教练与定时任务共用最终生效的文本能力，混合媒体输出不取消文本能力。
extension LLMModel {
    var nmSupportsConversation: Bool {
        let modalities = capabilities.supportedModalities
        guard modalities.contains(.textInput), modalities.contains(.textOutput) else { return false }
        // 嵌入、排序与审核服务常被代理错误标成文本，仍不支持会话协议。
        let identifier = id.lowercased()
        return !["embedding", "embed-", "rerank", "moderation"].contains { identifier.contains($0) }
    }
}

/// 统一凭证、显示状态和能力门槛，避免预检与实际回退选择不同类型的模型。
@MainActor
extension ProviderConfigStore {
    func nmIsUsableChatEntry(_ entry: ModelEntry) -> Bool {
        guard !entry.isHidden, entry.model.nmSupportsConversation,
              let instance = instance(for: entry.providerInstanceId) else { return false }
        return instance.isEnabled && instance.hasAnyCredential
    }

    /// 新建任务和没有历史会话的新聊天遵循相同提供商顺序。
    var nmLatestChatEntry: ModelEntry? {
        for instance in instances.reversed() {
            if let entry = modelEntries.last(where: { $0.providerInstanceId == instance.id && nmIsUsableChatEntry($0) }) {
                return entry
            }
        }
        return nil
    }
}
