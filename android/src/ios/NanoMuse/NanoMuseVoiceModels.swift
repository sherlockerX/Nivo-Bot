import Foundation
import SwiftUI

/// 模型页与运行时共用的语音模型识别和选择顺序。
enum NanoMuseVoiceModels {
    nonisolated private static let INPUT_FAMILIES = [
        "fun-asr", "paraformer", "qwen3-asr",
    ]
    nonisolated private static let OUTPUT_FAMILIES = [
        "cosyvoice", "qwen3-tts",
    ]

    /// 这些专用语音家族的方向先于宽泛的Qwen视觉推断，用户显式覆盖仍由调用方保留。
    nonisolated static func inferredModality(
        id: String, displayName: String
    ) -> ModelModality? {
        let name = (id + " " + displayName).lowercased()
        if INPUT_FAMILIES.contains(where: { name.contains($0) }) {
            return [.audioInput, .textOutput]
        }
        if OUTPUT_FAMILIES.contains(where: { name.contains($0) }) {
            return [.textInput, .audioOutput]
        }
        return nil
    }

    /// 优先采用仍可用的设备本地选择，再依次尝试分组成员，均不可用时交给System。
    nonisolated static func preferredEntryId(
        overrideEntryId: String?, groupMemberEntryIds: [String],
        canUse: (String) -> Bool
    ) -> String? {
        if let overrideEntryId, canUse(overrideEntryId) { return overrideEntryId }
        return groupMemberEntryIds.first(where: canUse)
    }
}

/// 模型页的语音输入和朗读入口，与聊天语音面板共享选择状态及解析规则。
@MainActor
struct NanoMuseVoiceModelsSection: View {
    @ObservedObject private var selection = VoiceSelectionStore.shared
    @ObservedObject private var store = ProviderConfigStore.shared
    @State private var picker: NanoMuseVoiceModelSlot?

    var body: some View {
        VStack(spacing: 8) {
            NanoMuseCard {
                ForEach(NanoMuseVoiceModelSlot.allCases) { slot in
                    if slot == .output { NanoMuseRowDivider() }
                    Button { picker = slot } label: { row(slot) }
                        .buttonStyle(.plain)
                }
            }
            NanoMuseCaption(text: AppLocalized("Used for voice input, read-aloud and the quick test. A speech model typed in by hand can be picked once its name says what it does (qwen3-asr-flash, fun-asr-realtime, cosyvoice-v3-flash, qwen3-tts-flash). The voice call keeps its own Model Studio models in its settings."))
        }
        .sheet(item: $picker) { slot in
            NavigationStack { VoiceModelSelectorView(direction: slot.direction) }
        }
    }

    /// 模型名称直接取运行时解析结果，配置或本地选择变化后随观察对象重新计算。
    private func row(_ slot: NanoMuseVoiceModelSlot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: slot == .input ? "mic" : "speaker.wave.2")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(slot.title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(label(slot.direction))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .truncationMode(.middle)
                .layoutPriority(-1)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    /// 使用与语音输入、朗读相同的有效模型，System回退显示手机自带。
    private func label(_ direction: VoiceDirection) -> String {
        let entry = direction == .input
            ? VoiceProviderResolver.resolvedInputEntry()
            : VoiceProviderResolver.resolvedOutputEntry()
        guard let entry,
              !VoiceProviderResolver.isSystemEntry(entry.providerInstanceId) else {
            return AppLocalized("Built into the phone")
        }
        guard let instance = store.instance(for: entry.providerInstanceId) else {
            return entry.model.displayName
        }
        return "\(instance.label) · \(entry.model.displayName)"
    }
}

/// 模型页只描述语音用途，具体候选、System音色与快速测试沿用已有统一选择器。
@MainActor
struct VoiceModelSelectorView: View {
    let direction: VoiceDirection
    @ObservedObject private var store = ProviderConfigStore.shared
    @ObservedObject private var selection = VoiceSelectionStore.shared

    var body: some View {
        UnifiedModelPicker(config: config)
    }

    /// 分组选择保留分组绑定，清除本地模型覆盖后继续采用分组顺序和故障回退。
    private var config: ModelPickerConfig {
        var result: ModelPickerConfig = direction == .input ? .voiceInput() : .voiceOutput()
        let systemId = VoiceProviderResolver.systemEntryId
        let isWrongDirection = result.isDisabled
        let usableIds = Set(store.modelEntries.compactMap { entry -> String? in
            guard isWrongDirection?(entry) != true else { return nil }
            return VoiceProviderResolver.usableEntry(entry.id, direction: direction) == nil ? nil : entry.id
        })
        result.isDisabled = { entry in
            entry.providerInstanceId != systemId && !usableIds.contains(entry.id)
        }
        result.currentEntryId = {
            if let selected = VoiceProviderResolver.effectiveOverrideEntryId(direction: direction) {
                return selected
            }
            let groupId = direction == .input ? store.voiceInputGroupId : store.voiceOutputGroupId
            return groupId == nil ? VoiceProviderResolver.systemEntryId : nil
        }
        result.currentGroupId = {
            guard VoiceProviderResolver.effectiveOverrideEntryId(direction: direction) == nil else {
                return nil
            }
            return direction == .input ? store.voiceInputGroupId : store.voiceOutputGroupId
        }
        result.onSelectGroup = { group in
            if direction == .input {
                store.voiceInputGroupId = group.id
                selection.inputEntryId = nil
            } else {
                store.voiceOutputGroupId = group.id
                selection.outputEntryId = nil
                VoiceOutputPlayer.shared.resetActiveModel()
            }
        }
        return result
    }
}

/// 用于呈现语音选择弹层的稳定标识，不改变现有VoiceDirection。
private enum NanoMuseVoiceModelSlot: String, CaseIterable, Identifiable {
    case input, output

    var id: String { rawValue }
    var direction: VoiceDirection { self == .input ? .input : .output }
    var title: String {
        self == .input ? AppLocalized("Speech to text") : AppLocalized("Text to speech")
    }
}
