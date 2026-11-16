import AVFoundation
import XCTest
@testable import Minis

/// 通话音频的PCM边界、代次失效与尾音等待回归测试，不访问真实麦克风。
final class NanoMuseCallAudioTests: XCTestCase {
    /// 小端PCM16允许网络分块落在一个样本中间。
    func testPCM16ReassemblesOddChunksWithoutLosingSamples() {
        var stream = NanoMuseCallPCM16Stream()
        XCTAssertEqual(stream.append(Data([0x00])), [])
        XCTAssertEqual(stream.append(Data([0x80, 0x00, 0x00, 0xFF])), [-1, 0])
        XCTAssertEqual(stream.append(Data([0x7F])), [Float(32767) / 32768])
    }

    /// 打断播放必须清除未完成样本，避免下一句拼接到上一句尾部。
    func testPCM16ResetDiscardsThePreviousTrailingByte() {
        var stream = NanoMuseCallPCM16Stream()
        XCTAssertEqual(stream.append(Data([0xFF])), [])
        stream.reset()
        XCTAssertEqual(stream.append(Data([0x00, 0x80])), [-1])
    }

    /// 静音只抑制当前会话输入，取消静音不能恢复旧会话回调。
    func testMuteAndStopRejectObsoleteInput() {
        let state = NanoMuseCallAudioGate()
        let first = state.beginSession()
        XCTAssertTrue(state.acceptsInput(generation: first))
        state.setMuted(true)
        XCTAssertFalse(state.acceptsInput(generation: first))
        state.setMuted(false)
        XCTAssertTrue(state.acceptsInput(generation: first))
        state.endSession()
        let second = state.beginSession()
        XCTAssertFalse(state.acceptsInput(generation: first))
        XCTAssertTrue(state.acceptsInput(generation: second))
    }

    /// 挂断后重新通话默认启用麦克风，不能沿用上次通话的静音门闩。
    func testEndingAMutedSessionUnmutesTheNextCall() {
        let state = NanoMuseCallAudioGate()
        _ = state.beginSession()
        state.setMuted(true)
        state.endSession()
        let generation = state.beginSession()
        XCTAssertTrue(state.acceptsInput(generation: generation))
    }

    /// 旧播放器完成回调不能扣减新一轮播放的等待计数。
    func testOldCompletionCannotDrainTheNewPlaybackGeneration() throws {
        let state = NanoMuseCallAudioGate()
        let generation = state.beginSession()
        let oldTicket = try XCTUnwrap(state.reservePlayback(byteCount: 480, generation: generation))
        state.clearPlayback()
        let newTicket = try XCTUnwrap(state.reservePlayback(byteCount: 960, generation: generation))
        state.completePlayback(oldTicket)
        XCTAssertTrue(state.isPlaybackPending)
        XCTAssertFalse(state.isCurrent(oldTicket))
        XCTAssertTrue(state.isCurrent(newTicket))
        state.completePlayback(newTicket)
        XCTAssertFalse(state.isPlaybackPending)
    }

    /// 已入队但尚未播放的音频也必须计入尾音等待。
    func testPlaybackIsPendingUntilEveryBufferFinishes() throws {
        let state = NanoMuseCallAudioGate()
        let generation = state.beginSession()
        let first = try XCTUnwrap(state.reservePlayback(byteCount: 480, generation: generation))
        let second = try XCTUnwrap(state.reservePlayback(byteCount: 480, generation: generation))
        state.completePlayback(first)
        XCTAssertTrue(state.isPlaybackPending)
        state.completePlayback(second)
        XCTAssertFalse(state.isPlaybackPending)
    }

    /// 缓冲上限避免持续比扬声器更快的网络音频无限占用内存。
    func testPlaybackRejectsAnUnboundedBacklog() throws {
        let state = NanoMuseCallAudioGate(maximumPendingBytes: 8)
        let generation = state.beginSession()
        _ = try state.reservePlayback(byteCount: 6, generation: generation)
        XCTAssertThrowsError(try state.reservePlayback(byteCount: 4, generation: generation)) {
            XCTAssertEqual($0 as? NanoMuseCallAudioFailure, .playbackBacklog)
        }
    }

    /// 停止播放会唤醒尾音等待者，避免挂断时遗留悬挂任务。
    func testStoppingPlaybackReleasesDrainWaiters() async throws {
        let state = NanoMuseCallAudioGate()
        let generation = state.beginSession()
        _ = try state.reservePlayback(byteCount: 480, generation: generation)
        let didDrain = expectation(description: "停止播放后结束等待")
        let waiter = Task {
            await state.drainPlayback()
            didDrain.fulfill()
        }
        await Task.yield()
        state.clearPlayback()
        await fulfillment(of: [didDrain], timeout: 1)
        await waiter.value
    }

    /// 父级取消尾音等待时，无需等待所有硬件回调完成即可退出。
    func testCancellingDrainReleasesOnlyTheWaiter() async throws {
        let state = NanoMuseCallAudioGate()
        let generation = state.beginSession()
        let ticket = try XCTUnwrap(state.reservePlayback(byteCount: 480, generation: generation))
        let didCancel = expectation(description: "取消后结束尾音等待")
        let waiter = Task {
            await state.drainPlayback()
            didCancel.fulfill()
        }
        waiter.cancel()
        await fulfillment(of: [didCancel], timeout: 1)
        await waiter.value
        XCTAssertTrue(state.isPlaybackPending)
        state.completePlayback(ticket)
        XCTAssertFalse(state.isPlaybackPending)
    }

    /// 挂断后排队中的PCM不能被重新接纳。
    func testStoppedSessionRejectsQueuedPlayback() throws {
        let state = NanoMuseCallAudioGate()
        let generation = state.beginSession()
        let ticket = try XCTUnwrap(state.reservePlayback(byteCount: 480, generation: generation))
        state.endSession()
        XCTAssertFalse(state.isCurrent(ticket))
        XCTAssertNil(try state.reservePlayback(byteCount: 480, generation: generation))
        XCTAssertFalse(state.isPlaybackPending)
    }

    /// 重采样必须把硬件采样率转换为ASR要求的单声道16kHzPCM16。
    func testInputConversionProducesMono16kPCM16() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<4800 {
            let sample = Float(sin(Double(frame) * 2 * .pi * 440 / 48000)) * 0.25
            channels[0][frame] = sample
            channels[1][frame] = sample
        }
        let converter = NanoMuseCallInputConverter()
        let data = try converter.convert(buffer)
        XCTAssertEqual(data.count % 2, 0)
        // 首包允许转换器保留有限的滤波尾部，不能误把双声道字节数当作单声道。
        XCTAssertGreaterThanOrEqual(data.count, 2688)
        XCTAssertLessThanOrEqual(data.count, 3200)
        XCTAssertTrue(data.contains { $0 != 0 })
    }
}
