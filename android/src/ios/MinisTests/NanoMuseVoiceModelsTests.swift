import XCTest
@testable import Minis

/// 验证设备本地语音选择、专用语音方向及分组/System回退顺序。
final class NanoMuseVoiceModelsTests: XCTestCase {
    @MainActor
    func testSelectionsSurviveStoreRecreation() throws {
        let suiteName = "NanoMuseVoiceModelsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = VoiceSelectionStore(defaults: defaults)
        first.inputEntryId = "provider/fun-asr-realtime"
        first.outputEntryId = "provider/cosyvoice-v3-flash"

        let restored = VoiceSelectionStore(defaults: defaults)
        XCTAssertEqual(restored.inputEntryId, first.inputEntryId)
        XCTAssertEqual(restored.outputEntryId, first.outputEntryId)
        XCTAssertEqual(defaults.string(forKey: "voice.input.overrideEntryId"), first.inputEntryId)
        XCTAssertEqual(defaults.string(forKey: "voice.output.overrideEntryId"), first.outputEntryId)
    }

    @MainActor
    func testClearingASelectionRestoresGroupFollowingWithoutClearingTheOtherDirection() throws {
        let suiteName = "NanoMuseVoiceModelsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selection = VoiceSelectionStore(defaults: defaults)
        selection.inputEntryId = "provider/paraformer-realtime"
        selection.outputEntryId = "provider/qwen3-tts-flash"
        selection.inputEntryId = nil

        let restored = VoiceSelectionStore(defaults: defaults)
        XCTAssertNil(restored.inputEntryId)
        XCTAssertNil(defaults.object(forKey: "voice.input.overrideEntryId"))
        XCTAssertEqual(restored.outputEntryId, "provider/qwen3-tts-flash")
        selection.outputEntryId = nil
        XCTAssertNil(VoiceSelectionStore(defaults: defaults).outputEntryId)
        XCTAssertNil(defaults.object(forKey: "voice.output.overrideEntryId"))
    }

    @MainActor
    func testSystemVariantAndConcreteVoiceIdsSurviveStoreRecreation() throws {
        let suiteName = "NanoMuseVoiceModelsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let system = VoiceProviderResolver.systemEntryId
        let selection = VoiceSelectionStore(defaults: defaults)
        selection.inputEntryId = system + "/system-asr-offline"
        selection.outputEntryId = system + "/com.apple.voice.compact.en-US.Samantha"

        let restored = VoiceSelectionStore(defaults: defaults)
        XCTAssertEqual(restored.inputEntryId, selection.inputEntryId)
        XCTAssertEqual(restored.outputEntryId, selection.outputEntryId)
        XCTAssertEqual(
            VoiceProviderResolver.selectedSystemVoiceId(restored.outputEntryId),
            "com.apple.voice.compact.en-US.Samantha"
        )
    }

    func testManuallyAddedASRNamesHaveOnlyAudioInputAndTextOutput() {
        for modelId in ["fun-asr-realtime", "paraformer-realtime", "qwen3-asr-flash"] {
            let entry = ModelEntry(
                providerInstanceId: "provider",
                model: LLMModel(id: modelId, displayName: modelId, provider: "OpenAI"),
                isCustom: true
            )
            XCTAssertEqual(entry.model.capabilities.supportedModalities, [.audioInput, .textOutput], modelId)
            XCTAssertTrue(VoiceDirection.input.isVoiceModel(entry.model), modelId)
            XCTAssertFalse(VoiceDirection.output.isVoiceModel(entry.model), modelId)
            XCTAssertNil(entry.baseModel.modalityOverride, "有效视图不改写API原始元数据")
        }
    }

    func testManuallyAddedTTSNamesHaveOnlyTextInputAndAudioOutput() {
        for modelId in ["cosyvoice-v3-flash", "qwen3-tts-flash"] {
            let entry = ModelEntry(
                providerInstanceId: "provider",
                model: LLMModel(id: modelId, displayName: modelId, provider: "OpenAI"),
                isCustom: true
            )
            XCTAssertEqual(entry.model.capabilities.supportedModalities, [.textInput, .audioOutput], modelId)
            XCTAssertTrue(VoiceDirection.output.isVoiceModel(entry.model), modelId)
            XCTAssertFalse(VoiceDirection.input.isVoiceModel(entry.model), modelId)
        }
    }

    func testDedicatedQwenASRRepairsAnEarlierBroadVisionInference() {
        let entry = ModelEntry(
            providerInstanceId: "provider",
            model: LLMModel(
                id: "qwen3-asr-flash", displayName: "Qwen3 ASR Flash", provider: "OpenAI",
                modalityOverride: .vision
            )
        )
        XCTAssertEqual(entry.model.modalityOverride, [.audioInput, .textOutput])
        XCTAssertEqual(entry.baseModel.modalityOverride, .vision)
    }

    func testExplicitUserModalityTakesPrecedenceOverNameInference() {
        let entry = ModelEntry(
            providerInstanceId: "provider",
            model: LLMModel(id: "qwen3-asr-flash", displayName: "Qwen3 ASR Flash", provider: "OpenAI"),
            overrides: ModelOverrides(displayName: "我的模型", modalityOverride: .textOnly)
        )
        XCTAssertEqual(entry.model.modalityOverride, .textOnly)
        XCTAssertEqual(entry.model.displayName, "我的模型")
    }

    func testDisplayNameInferenceIsCaseInsensitiveAndLeavesChatModelsAlone() {
        XCTAssertEqual(
            NanoMuseVoiceModels.inferredModality(id: "custom", displayName: "PARAFORMER Realtime"),
            [.audioInput, .textOutput]
        )
        XCTAssertEqual(
            NanoMuseVoiceModels.inferredModality(id: "custom", displayName: "CosyVoice V3"),
            [.textInput, .audioOutput]
        )
        XCTAssertNil(NanoMuseVoiceModels.inferredModality(id: "qwen3.8-27b", displayName: "Qwen3.8"))
        XCTAssertNil(NanoMuseVoiceModels.inferredModality(id: "sambert-zhijia", displayName: "Sambert"))
    }

    func testAUsableOverrideWinsAndAnInvalidOverrideFallsBackInGroupOrder() {
        let usableIds: Set<String> = ["chosen", "group-first", "group-second"]
        XCTAssertEqual(
            NanoMuseVoiceModels.preferredEntryId(
                overrideEntryId: "chosen", groupMemberEntryIds: ["group-first", "group-second"],
                canUse: { usableIds.contains($0) }
            ),
            "chosen"
        )
        for invalidId in ["deleted", "disabled-provider", "hidden-model", "wrong-direction"] {
            XCTAssertEqual(
                NanoMuseVoiceModels.preferredEntryId(
                    overrideEntryId: invalidId,
                    groupMemberEntryIds: ["disabled-provider", "group-first", "group-second"],
                    canUse: { usableIds.contains($0) }
                ),
                "group-first"
            )
        }
    }

    func testSystemGroupMemberAndFinalSystemFallbackKeepTheirOrder() {
        let system = "__builtin_system_speech__/system-tts"
        XCTAssertEqual(
            NanoMuseVoiceModels.preferredEntryId(
                overrideEntryId: system, groupMemberEntryIds: ["cloud"],
                canUse: { _ in true }
            ),
            system
        )
        XCTAssertEqual(
            NanoMuseVoiceModels.preferredEntryId(
                overrideEntryId: "deleted",
                groupMemberEntryIds: ["disabled", system, "cloud"],
                canUse: { $0 == system || $0 == "cloud" }
            ),
            system
        )
        XCTAssertNil(NanoMuseVoiceModels.preferredEntryId(
            overrideEntryId: "deleted", groupMemberEntryIds: ["disabled"], canUse: { _ in false }
        ))
        XCTAssertNil(NanoMuseVoiceModels.preferredEntryId(
            overrideEntryId: nil, groupMemberEntryIds: [], canUse: { _ in true }
        ))
    }

    @MainActor
    func testSystemSelectionsCannotCrossVoiceDirectionsOrAcceptUnknownSuffixes() {
        let system = VoiceProviderResolver.systemEntryId
        XCTAssertTrue(VoiceProviderResolver.isUsableSystemEntryId(system, direction: .input))
        XCTAssertTrue(VoiceProviderResolver.isUsableSystemEntryId(system, direction: .output))
        XCTAssertTrue(VoiceProviderResolver.isUsableSystemEntryId(system + "/system-asr-online", direction: .input))
        XCTAssertTrue(VoiceProviderResolver.isUsableSystemEntryId(system + "/system-asr-offline", direction: .input))
        XCTAssertFalse(VoiceProviderResolver.isUsableSystemEntryId(system + "/system-tts", direction: .input))
        XCTAssertFalse(VoiceProviderResolver.isUsableSystemEntryId(system + "/system-asr-online", direction: .output))
        XCTAssertFalse(VoiceProviderResolver.isUsableSystemEntryId(system + "/deleted", direction: .input))
        XCTAssertFalse(VoiceProviderResolver.isUsableSystemEntryId(system + "/deleted", direction: .output))
        XCTAssertTrue(VoiceProviderResolver.isUsableSystemEntryId(
            system + "/com.apple.voice.compact.zh-CN.Tingting", direction: .output
        ))
    }
}
