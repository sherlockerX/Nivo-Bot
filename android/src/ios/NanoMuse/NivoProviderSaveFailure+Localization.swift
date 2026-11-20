import Foundation

/// 通用系统错误展示保存阶段；已有的凭证或冲突说明继续保留其可操作的原因。
extension NivoProviderSaveFailure: LocalizedError {
    var errorDescription: String? {
        let message = String(format: String(localized: "nivo.providers.save.failed"), diagnosticCode)
        if let actionable = underlying as? LocalizedError, let detail = actionable.errorDescription {
            return message + "\n" + detail
        }
        return message
    }
}
