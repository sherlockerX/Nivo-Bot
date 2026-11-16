import XCTest
@testable import Minis

/// 应用测试直接检查人工覆盖后的真实模型，尚需Apple测试目标执行。
final class NivoChatModelAvailabilityTests: XCTestCase {
    private func model(_ id: String, modalities: ModelModality?) -> LLMModel {
        LLMModel(id: id, displayName: id, provider: "OpenAI", modalityOverride: modalities)
    }

    func testMixedTextAndMediaRemainConversationModels() {
        for output in [ModelModality.imageOutput, .videoOutput, .audioOutput] {
            XCTAssertTrue(model("mixed-image-video", modalities: [.textInput, .textOutput, output]).nmSupportsConversation)
            XCTAssertFalse(model("pure-media", modalities: [.textInput, output]).nmSupportsConversation)
        }
    }

    func testTranscriptionIsNotConfusedWithConversation() {
        XCTAssertFalse(model("speech", modalities: [.audioInput, .textOutput]).nmSupportsConversation)
        XCTAssertTrue(model("omni", modalities: [.textInput, .audioInput, .textOutput, .audioOutput]).nmSupportsConversation)
    }

    @MainActor func testUserOverrideIsUsedInsteadOfBaseCapability() {
        let entry = ModelEntry(providerInstanceId: "test", model: model("mixed-image", modalities: [.textInput, .imageOutput]),
            overrides: ModelOverrides(modalityOverride: [.textInput, .textOutput, .imageOutput]))
        XCTAssertTrue(entry.model.nmSupportsConversation)
        XCTAssertFalse(entry.baseModel.nmSupportsConversation)
        XCTAssertTrue(AIChatViewModel.isTitleEligible(entry))
    }

    func testLegacyTextDefaultsAndNonConversationEndpoints() {
        XCTAssertTrue(model("custom-chat", modalities: nil).nmSupportsConversation)
        for identifier in ["text-embedding", "embed-local", "rerank-v2", "moderation"] {
            XCTAssertFalse(model(identifier, modalities: [.textInput, .textOutput]).nmSupportsConversation)
        }
    }

    func testDedicatedMediaRepairsLegacyTextUnionWithoutRejectingGeminiMixedOutput() {
        for identifier in ["qwen-image-3.0", "vendor/gpt-image-2", "wan2.7-t2v", "sora-2", "imagen-4"] {
            let entry = ModelEntry(providerInstanceId: "test", model: model(identifier, modalities: [.textInput, .textOutput, .imageOutput]))
            XCTAssertFalse(entry.model.nmSupportsConversation, identifier)
            var manuallyCorrected = entry
            manuallyCorrected.overrides.modalityOverride = [.textInput, .textOutput, .imageOutput]
            XCTAssertTrue(manuallyCorrected.model.nmSupportsConversation, identifier)
        }
        let mixed = ModelEntry(providerInstanceId: "test", model: model("gemini-flash-image", modalities: [.textInput, .textOutput, .imageOutput]))
        XCTAssertTrue(mixed.model.nmSupportsConversation)
    }
}
