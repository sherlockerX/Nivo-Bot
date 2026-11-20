import Foundation

/// 模型详情的可编辑字段与存储模型分离，未展示的能力和推理元数据随原记录保留。
@MainActor
struct NivoProviderModelForm {
    private static let EDITABLE_MODALITIES: ModelModality = [
        .imageInput, .pdfInput, .audioInput, .videoInput, .imageOutput, .audioOutput,
    ]

    var modelID: String
    var displayName: String
    var contextWindowText: String
    var maxOutputTokensText: String
    var isThinkingSupported: Bool
    var isHidden: Bool
    var selectedModalities: ModelModality

    /// 每次从确认保存的模型完整填充表单；空值同时清空旧输入，供重置后重新使用。
    init(entry: ModelEntry) {
        let effective = entry.model
        modelID = entry.baseModel.id
        displayName = effective.displayName
        contextWindowText = effective.contextWindow.map { String($0) } ?? ""
        maxOutputTokensText = entry.overrides.maxOutputTokens.map { String($0) } ?? ""
        isThinkingSupported = effective.supportsReasoning ?? false
        isHidden = entry.isHidden
        selectedModalities = effective.capabilities.supportedModalities.intersection(Self.EDITABLE_MODALITIES)
    }

    /// 只提交表单提供的编辑，版本由仓库在持久化事务中推进。
    func applying(to entry: ModelEntry) -> ModelEntry {
        let effective = entry.model
        let base = baseModel(from: entry)
        var overrides = entry.overrides
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? base.displayName : displayName
        if name != effective.displayName { overrides.displayName = name == base.displayName ? nil : name }
        overrides.maxOutputTokens = Self.tokens(maxOutputTokensText)
        let context = Self.tokens(contextWindowText)
        if context != effective.contextWindow { overrides.contextWindow = context == base.contextWindow ? nil : context }
        if isThinkingSupported != (effective.supportsReasoning ?? false) {
            overrides.supportsReasoning = isThinkingSupported == (base.supportsReasoning ?? false) ? nil : isThinkingSupported
        }
        applyModality(to: &overrides, entry: entry)
        return ModelEntry(uuid: entry.uuid, providerInstanceId: entry.providerInstanceId,
            model: base, overrides: overrides, isCustom: entry.isCustom, isHidden: isHidden,
            userModifiedAt: entry.userModifiedAt)
    }

    private func applyModality(to overrides: inout ModelOverrides, entry: ModelEntry) {
        let effective = entry.model.capabilities.supportedModalities
        let selection = selectedModalities.intersection(Self.EDITABLE_MODALITIES)
        guard selection != effective.intersection(Self.EDITABLE_MODALITIES) else { return }
        // 没有文本或视频输出开关时不能擅自增删这些能力；未操作模态时也不新增覆盖。
        let updated = effective.subtracting(Self.EDITABLE_MODALITIES).union(selection)
        overrides.modalityOverride = updated == entry.baseModel.capabilities.supportedModalities ? nil : updated
    }

    private func baseModel(from entry: ModelEntry) -> LLMModel {
        let identifier = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = entry.baseModel
        guard entry.isCustom, !identifier.isEmpty, identifier != original.id else { return original }
        // ID是不可变字段，改名时完整保留目录声明，避免丢掉服务商支持的推理档位。
        var renamed = LLMModel(id: identifier, displayName: original.displayName, provider: original.provider,
            modalityOverride: original.modalityOverride, contextWindow: original.contextWindow,
            maxOutputTokens: original.maxOutputTokens, supportsReasoning: original.supportsReasoning,
            interleavedReasoningField: original.interleavedReasoningField,
            reasoningEffortValues: original.reasoningEffortValues, declaresNoEffortTiers: original.declaresNoEffortTiers)
        renamed.effortDeclarationIsAuthoritative = original.effortDeclarationIsAuthoritative
        return renamed
    }

    private static func tokens(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
