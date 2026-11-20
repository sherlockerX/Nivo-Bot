import Foundation

/// 模型工具的授权说明；聊天绑定不授予终端调用其他模型的权限。
enum NivoModelUseDiagnostics {
    static let noModelsHint =
        "No authorized, enabled models match this request. Open Settings > Model Groups > " +
        "Models nanoMuse Can Call at Runtime (minis://settings/model-groups) to add models or groups. " +
        "Chat model selection is separate; --all does not grant access to other configured models."
}

/// 错误保留原始模型或供应商身份，操作建议作为独立字段传入。
enum ModelUseError: LocalizedError {
    case modelNotFound(String, hint: String? = nil)
    case providerNotFound(String)
    case invalidInput(String)
    case modalityNotSupported(model: String, required: String, supported: [String])

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let identifier, let hint):
            let base = "Model '\(identifier)' not found. Use 'minis-model-use list' to see available models."
            return hint.map { base + "\n" + $0 } ?? base
        case .providerNotFound(let provider):
            return "No available authorized model matches --provider '\(provider)'. Use 'minis-model-use list' to see provider labels."
        case .invalidInput(let message):
            return message
        case .modalityNotSupported(let model, let required, let supported):
            return "Model '\(model)' does not support \(required). Supported modalities: \(supported.joined(separator: ", ")). Use 'minis-model-use list' to find a model with the required capability."
        }
    }
}
