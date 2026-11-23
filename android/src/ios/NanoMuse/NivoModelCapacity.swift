import Foundation

/// 上下文容量来自哪里；排在前面的优先。
enum NivoCapacitySource {
    case override, endpoint, catalog, estimate

    /// 一句话说明正在使用的上下文长度和来源。
    func text(tokens: Int) -> String {
        switch self {
        case .override: return String(format: AppLocalized("In use: %d tokens, set by you"), tokens)
        case .endpoint: return String(format: AppLocalized("In use: %d tokens, reported by this provider"), tokens)
        case .catalog: return String(format: AppLocalized("In use: %d tokens, from the model catalog"), tokens)
        case .estimate: return String(format: AppLocalized("In use: %d tokens, estimated from the model name"), tokens)
        }
    }
}

/// 模型容量的读取和来源判断。
enum NivoModelCapacity {
    /// 同一模型在不同服务上的上限不同，这些字段是服务自己报告的值，先列出正在使用的那一个。
    private static let contextFields = [
        "loaded_context_length", "context_length", "context_window", "max_context_length", "max_model_len",
    ]
    private static let outputFields = ["max_completion_tokens", "max_output_tokens"]
    /// 小于这个值的不是可用的上下文长度，多半是占位。
    private static let minimumContext = 512

    /// 从`/v1/models`的一项读取容量；`top_provider`是聚合服务实际路由到的上限，与总上限取较小值。
    static func endpointLimits(_ item: [String: Any]) -> (context: Int?, output: Int?) {
        let routed = item["top_provider"] as? [String: Any] ?? [:]
        let context = [first(item, contextFields), first(routed, contextFields)].compactMap { $0 }.min()
        let output = [first(item, outputFields), first(routed, outputFields)].compactMap { $0 }.min()
        let usableContext = context.flatMap { $0 >= minimumContext ? $0 : nil }
        // 输出上限大于上下文长度的值不可用。
        let usableOutput = output.flatMap { $0 <= (context ?? Int.max) ? $0 : nil }
        return (usableContext, usableOutput)
    }

    /// [override]是用户填写的上下文长度，没填为空；用户自己添加的模型，基础值也是用户填写的。
    static func source(base: LLMModel, override: Int?, isCustom: Bool) -> NivoCapacitySource {
        if let override, override > 0 { return .override }
        guard let context = base.contextWindow, context > 0 else { return .estimate }
        if base.isContextWindowFromEndpoint == true { return .endpoint }
        return isCustom ? .override : .catalog
    }

    private static func first(_ item: [String: Any], _ fields: [String]) -> Int? {
        for field in fields {
            if let value = number(item[field]), value > 0 { return value }
        }
        return nil
    }

    /// 有的服务把数字写成字符串或小数。
    private static func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double, value.isFinite, value < Double(Int32.max) { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }
}
