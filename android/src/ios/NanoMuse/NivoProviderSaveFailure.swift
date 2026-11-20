import Foundation

/// 提供商保存失败保留具体阶段，系统的通用文件错误不能再被误认为用户填错了网址。
struct NivoProviderSaveFailure: Error {
    enum Stage: String, Sendable {
        case baseline = "01", preparation = "02", snapshot = "03", journal = "04"
        case credentials = "05", configuration = "06", completion = "07", rollback = "08"
    }

    let stage: Stage
    let underlying: any Error

    /// 固定阶段和数字码足以定位失败位置，不显示底层错误携带的文件路径或输入值。
    var diagnosticCode: String { "PV-\(stage.rawValue)-\((underlying as NSError).code)" }

    /// 外层协调器不覆盖更接近实际失败位置的诊断阶段。
    static func capture(_ error: any Error, stage: Stage) -> Self {
        (error as? Self) ?? Self(stage: stage, underlying: error)
    }
}
