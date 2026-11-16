import XCTest
@testable import Minis

/// 百炼协议的纯逻辑回归，不连接服务商，不读取Keychain或真实密钥。
@MainActor
final class NanoMuseBailianVoiceTests: XCTestCase {
    func testBuffersAllInputBeforeReadyAndFinishesLast() {
        var buffer = NanoMuseDashScopeBuffer()
        let first = Data([1, 2]), second = Data([3, 4])
        XCTAssertTrue(buffer.append(.audio(first)))
        XCTAssertTrue(buffer.append(.audio(second)))
        XCTAssertTrue(buffer.finish())
        XCTAssertNil(buffer.next())
        XCTAssertTrue(buffer.markReady())
        XCTAssertFalse(buffer.markReady())
        XCTAssertEqual(buffer.next(), .audio(first))
        XCTAssertEqual(buffer.next(), .audio(second))
        XCTAssertEqual(buffer.next(), .finish)
        XCTAssertNil(buffer.next())
        XCTAssertFalse(buffer.finish())
        XCTAssertTrue(buffer.append(.audio(Data([5, 6]))))
        XCTAssertNil(buffer.next())
    }

    func testBufferOverflowDoesNotEvictBeginningOfRecording() {
        var buffer = NanoMuseDashScopeBuffer(maximumBytes: 4, maximumMessages: 2)
        XCTAssertTrue(buffer.append(.audio(Data([1, 2]))))
        XCTAssertTrue(buffer.append(.audio(Data([3, 4]))))
        XCTAssertFalse(buffer.append(.audio(Data([5, 6]))))
        XCTAssertTrue(buffer.markReady())
        XCTAssertEqual(buffer.next(), .audio(Data([1, 2])))
        XCTAssertEqual(buffer.next(), .audio(Data([3, 4])))
        XCTAssertNil(buffer.next())
    }

    func testTextAndFinishRemainOrderedWhileBufferCompacts() {
        var buffer = NanoMuseDashScopeBuffer()
        XCTAssertTrue(buffer.markReady())
        for index in 0..<300 { XCTAssertTrue(buffer.append(.text(String(index)))) }
        for index in 0..<200 { XCTAssertEqual(buffer.next(), .text(String(index))) }
        for index in 300..<500 { XCTAssertTrue(buffer.append(.text(String(index)))) }
        XCTAssertTrue(buffer.finish())
        for index in 200..<500 { XCTAssertEqual(buffer.next(), .text(String(index))) }
        XCTAssertEqual(buffer.next(), .finish)
        buffer.close()
        XCTAssertNil(buffer.next())
        XCTAssertFalse(buffer.markReady())
        XCTAssertFalse(buffer.finish())
    }

    func testCancellationBeforeContinuationInstallationDoesNotHang() async {
        let completion = NanoMuseBailianCompletion("")
        XCTAssertTrue(completion.complete(failure: CancellationError()))
        do {
            let _: String = try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(completion.install(continuation))
            }
            XCTFail("提前取消必须返回CancellationError")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(completion.complete())
    }

    func testConcurrentTerminalCallbacksResumeExactlyOnce() async throws {
        let completion = NanoMuseBailianCompletion(42)
        let waiter = Task<Int, Error> {
            try await withCheckedThrowingContinuation { continuation in completion.install(continuation) }
        }
        let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<100 { group.addTask { completion.complete() } }
            var count = 0
            for await didComplete in group where didComplete { count += 1 }
            return count
        }
        let value = try await waiter.value
        XCTAssertEqual(value, 42)
        XCTAssertEqual(winners, 1)
        completion.update { $0 = 100 }
        XCTAssertFalse(completion.complete(failure: CancellationError()))
    }

    func testWorkspaceAndPublicHostDetectionUsesHostBoundaries() {
        XCTAssertTrue(NanoMuseBailianVoice.isModelStudio("https://dashscope.aliyuncs.com/compatible-mode/v1"))
        XCTAssertTrue(NanoMuseBailianVoice.isModelStudio("https://dashscope-intl.aliyuncs.com/compatible-mode"))
        XCTAssertTrue(NanoMuseBailianVoice.isModelStudio("https://fixture.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"))
        XCTAssertFalse(NanoMuseBailianVoice.isModelStudio("https://example.com/dashscope"))
        XCTAssertFalse(NanoMuseBailianVoice.isModelStudio("https://dashscope.aliyuncs.com.example.com"))
        XCTAssertFalse(NanoMuseBailianVoice.isModelStudio("https://examplemaas.aliyuncs.com"))
        XCTAssertFalse(NanoMuseBailianVoice.isModelStudio("dashscope.aliyuncs.com"))
    }

    func testEndpointsRetainRegionAndDoNotFallbackForInvalidBase() throws {
        let socket = try NanoMuseDashScope.endpoint(forBase: "https://fixture.ap-southeast-1.maas.aliyuncs.com:8443/compatible-mode/v1/")
        XCTAssertEqual(socket.absoluteString, "wss://fixture.ap-southeast-1.maas.aliyuncs.com:8443/api-ws/v1/inference")
        XCTAssertEqual(try NanoMuseBailianVoice.chatEndpoint(forBase: "https://dashscope.aliyuncs.com").path,
                       "/compatible-mode/v1/chat/completions")
        XCTAssertEqual(try NanoMuseBailianVoice.chatEndpoint(forBase: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/").path,
                       "/compatible-mode/v1/chat/completions")
        for base in ["", "not a URL", "http://dashscope.aliyuncs.com", "https://user@example.com", "https://example.com?key=fixture"] {
            XCTAssertThrowsError(try NanoMuseDashScope.endpoint(forBase: base))
        }
    }

    func testASRRequestUsesDataURLAndTopLevelOptions() throws {
        let body = NanoMuseBailianVoice.chatBody(wav: Data([1, 2]), model: "qwen3-asr-flash")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let audio = try XCTUnwrap(content.first?["input_audio"] as? [String: Any])
        XCTAssertEqual(audio["data"] as? String, "data:audio/wav;base64,AQI=")
        XCTAssertEqual(audio["format"] as? String, "wav")
        XCTAssertEqual((body["asr_options"] as? [String: Bool])?["enable_itn"], false)
        XCTAssertEqual(body["stream"] as? Bool, false)
        let omni = NanoMuseBailianVoice.chatBody(wav: Data([1, 2]), model: "qwen3-omni-flash")
        XCTAssertEqual(omni["stream"] as? Bool, true)
        XCTAssertEqual(omni["modalities"] as? [String], ["text"])
    }

    func testOmniStreamJoinsTextAndIgnoresReasoning() throws {
        let events = [
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"隐藏推理\"},\"finish_reason\":null}]}\r\n\r\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"},\"finish_reason\":null}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"世界\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: {\"choices\":[],\"usage\":{}}\n\ndata: [DONE]\n\n",
        ].joined()
        XCTAssertEqual(try NanoMuseBailianVoice.parseChatStream(Data(events.utf8)), "你好世界")
    }

    func testOmniStreamReportsServerErrorAndRejectsPartialOrTruncatedOutput() {
        let failure = "data: {\"error\":{\"code\":\"InvalidParameter\",\"message\":\"fixture failure\"}}\n\n"
        XCTAssertThrowsError(try NanoMuseBailianVoice.parseChatStream(Data(failure.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("fixture failure"))
        }
        let partial = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n"
        XCTAssertThrowsError(try NanoMuseBailianVoice.parseChatStream(Data(partial.utf8)))
        let truncated = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n"
        XCTAssertThrowsError(try NanoMuseBailianVoice.parseChatStream(Data(truncated.utf8)))
    }

    func testHTTP200NativeErrorIsNotSuccessfulEmptyAudio() {
        XCTAssertThrowsError(try NanoMuseBailianVoice.checkServerError([
            "status_code": 400, "code": "InvalidParameter", "message": "fixture failure",
        ]))
        XCTAssertNoThrow(try NanoMuseBailianVoice.checkServerError([
            "status_code": 200, "code": "", "message": "", "output": [:],
        ]))
    }

    func testSpeechTextPiecesRespectScalarLimitsAndPreserveText() {
        let text = String(repeating: "中👩🏽‍💻e\u{301}", count: 250)
        let pieces = NanoMuseBailianVoice.textPieces(text, maximumScalars: 600)
        XCTAssertEqual(pieces.joined(), text)
        XCTAssertTrue(pieces.allSatisfy { !$0.isEmpty && $0.unicodeScalars.count <= 600 })
        XCTAssertEqual(NanoMuseBailianVoice.defaultCosyVoice("cosyvoice-v2"), "longxiaochun_v2")
        XCTAssertEqual(NanoMuseBailianVoice.defaultCosyVoice("cosyvoice-v3-flash"), "longanyang")
    }

    func testCosyVoice35RequiresAnExplicitClonedOrDesignedVoice() throws {
        XCTAssertEqual(NanoMuseBailianVoice.defaultCosyVoice("cosyvoice-v3.5-plus"), "")
        XCTAssertThrowsError(try NanoMuseBailianVoice.resolvedCosyVoice("cosyvoice-v3.5-flash", requestedVoice: nil))
        XCTAssertEqual(try NanoMuseBailianVoice.resolvedCosyVoice("cosyvoice-v3.5-flash", requestedVoice: "fixture-custom-voice"),
                       "fixture-custom-voice")
        XCTAssertEqual(try NanoMuseBailianVoice.resolvedCosyVoice("cosyvoice-v2", requestedVoice: nil), "longxiaochun_v2")
    }

    func testPCM16WAVRoundTripAndLittleEndianSamples() throws {
        let pcm = samples([0, 32767, -32768, 1234])
        let wav = try NanoMuseBailianVoice.wav(pcm16: pcm, rate: 16000)
        let parsed = try XCTUnwrap(NanoMuseBailianVoice.parseWAV(wav))
        XCTAssertEqual(parsed.pcm, pcm)
        XCTAssertEqual(parsed.rate, 16000)
        XCTAssertEqual(parsed.channels, 1)
        XCTAssertEqual(try NanoMuseBailianVoice.pcm16Mono(fromWAV: wav, rate: 16000), pcm)
    }

    func testStereoIsDownmixedOnceAndResamplingPreservesTiming() throws {
        var stereo = try NanoMuseBailianVoice.wav(pcm16: samples([1000, 3000, -4000, 2000]), rate: 16000)
        set16(2, at: 22, in: &stereo)
        set32(64000, at: 28, in: &stereo)
        set16(4, at: 32, in: &stereo)
        XCTAssertEqual(NanoMuseBailianVoice.parseWAV(stereo)?.channels, 2)
        XCTAssertEqual(try NanoMuseBailianVoice.pcm16Mono(fromWAV: stereo, rate: 16000), samples([2000, -1000]))
        let lowRate = try NanoMuseBailianVoice.wav(pcm16: samples([0, 1000]), rate: 8000)
        XCTAssertEqual(try NanoMuseBailianVoice.pcm16Mono(fromWAV: lowRate, rate: 16000), samples([0, 500, 1000, 1000]))
    }

    func testRejectsFloatPCMAndInvalidBlockAlignmentOrByteRate() throws {
        let valid = try NanoMuseBailianVoice.wav(pcm16: samples([1, 2]), rate: 16000)
        var float = valid
        set16(3, at: 20, in: &float)
        XCTAssertNil(NanoMuseBailianVoice.parseWAV(float))
        var alignment = valid
        set16(4, at: 32, in: &alignment)
        XCTAssertNil(NanoMuseBailianVoice.parseWAV(alignment))
        var byteRate = valid
        set32(1, at: 28, in: &byteRate)
        XCTAssertNil(NanoMuseBailianVoice.parseWAV(byteRate))
        var bits = valid
        set16(8, at: 34, in: &bits)
        XCTAssertNil(NanoMuseBailianVoice.parseWAV(bits))
    }

    func testRejectsTruncatedChunksAndUnlabelledAudio() throws {
        let valid = try NanoMuseBailianVoice.wav(pcm16: samples([1, 2]), rate: 16000)
        XCTAssertNil(NanoMuseBailianVoice.parseWAV(valid.dropLast()))
        var oversized = valid
        set32(1024, at: 40, in: &oversized)
        XCTAssertNil(NanoMuseBailianVoice.parseWAV(oversized))
        XCTAssertThrowsError(try NanoMuseBailianVoice.pcm16Mono(fromWAV: Data([1, 2, 3, 4]), rate: 16000))
        XCTAssertThrowsError(try NanoMuseBailianVoice.wav(pcm16: Data([1]), rate: 16000))
        XCTAssertThrowsError(try NanoMuseBailianVoice.wav(pcm16: Data([1, 2]), rate: 0))
    }

    private func samples(_ values: [Int16]) -> Data {
        var data = Data()
        for value in values {
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(truncatingIfNeeded: bits))
            data.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return data
    }

    private func set16(_ value: UInt16, at offset: Int, in data: inout Data) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func set32(_ value: UInt32, at offset: Int, in data: inout Data) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}
