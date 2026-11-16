import AVFoundation
import Foundation

/// 双工通话音频入口；界面状态留在主线程，音频图与转换器留在独立串行队列。
@MainActor
final class NanoMuseCallAudio {
    /// 收到单声道16kHz、小端PCM16；回调来自音频工作队列。
    var onPCM: (@Sendable (Data) -> Void)? {
        didSet { gate.setPCMHandler(onPCM) }
    }

    /// 音频失效时先停止本次通话，再向上层报告可显示的原因。
    var onFailure: (@Sendable (String) -> Void)?

    /// 包括已排队但尚未交给播放器的音频，直到设备实际播放完成才清除。
    var isPlaybackPending: Bool { gate.isPlaybackPending }

    private let coordinator = AudioSessionCoordinator.shared
    private let gate = NanoMuseCallAudioGate()
    private let observers = NanoMuseCallAudioObservers()
    private var worker: NanoMuseCallAudioWorker?
    private var callOwner: UUID?
    private var lifecycleGeneration: UInt64 = 0
    private var isStarting = false
    private var isRunning = false
    private var routeSignature = ""

    deinit {
        // 释放对象同样使全部待执行回调失效，并在音频节点停止后释放租约。
        gate.endSession()
        let coordinator = coordinator
        let owner = callOwner
        let release: @Sendable () -> Void = {
            guard let owner else { return }
            Task { @MainActor in coordinator.endCall(owner: owner) }
        }
        if let worker { worker.stop(completion: release) } else { release() }
    }

    /// 请求麦克风权限，等待双工会话真正激活，再启动带回声消除的输入与输出。
    func start() async throws {
        if isRunning { return }
        guard !isStarting else { throw NanoMuseCallAudioFailure.startFailed }
        lifecycleGeneration &+= 1
        let attempt = lifecycleGeneration
        isStarting = true
        do {
            let hasPermission = await Self.requestMicrophonePermission()
            try checkAttempt(attempt)
            guard hasPermission else { throw NanoMuseCallAudioFailure.permissionDenied }
            let owner = UUID()
            callOwner = owner
            do { try await coordinator.beginCall(owner: owner) }
            catch { throw NanoMuseCallAudioFailure.sessionFailed }
            try checkAttempt(attempt)
            let generation = gate.beginSession()
            let audioWorker = NanoMuseCallAudioWorker(gate: gate) { [weak self] failure in
                Task { @MainActor [weak self] in self?.fail(failure, attempt: attempt) }
            }
            worker = audioWorker
            try await audioWorker.start(generation: generation)
            try checkAttempt(attempt)
            isRunning = true
            isStarting = false
            routeSignature = Self.currentRouteSignature()
            registerNotifications(attempt: attempt)
        } catch {
            let wasCancelled = attempt != lifecycleGeneration || Task.isCancelled || error is CancellationError
            if attempt == lifecycleGeneration { stop() }
            if wasCancelled { throw CancellationError() }
            throw (error as? NanoMuseCallAudioFailure) ?? NanoMuseCallAudioFailure.startFailed
        }
    }

    /// 追加单声道24kHz、小端PCM16网络分块，保留跨分块的半个样本。
    func play(_ data: Data) {
        guard isRunning, !data.isEmpty, let worker else { return }
        do {
            if let ticket = try gate.reservePlayback(byteCount: data.count) {
                worker.play(data, ticket: ticket)
            }
        } catch {
            fail(.playbackBacklog, attempt: lifecycleGeneration)
        }
    }

    /// 打断本轮播放，立即撤销旧缓冲、旧半样本和旧完成回调。
    func stopPlayback() {
        gate.clearPlayback()
        worker?.stopPlayback()
    }

    /// 等待已提交的尾音真正播放完；挂断、打断或任务取消都会结束等待。
    func drainPlayback() async {
        await gate.drainPlayback()
    }

    /// 停止输入、输出和系统观察，在节点清理完成后释放音频会话意图。
    func stop() {
        lifecycleGeneration &+= 1
        isStarting = false
        isRunning = false
        observers.removeAll()
        gate.endSession()
        let audioWorker = worker
        worker = nil
        let owner = callOwner
        callOwner = nil
        let coordinator = coordinator
        let release: @Sendable () -> Void = {
            guard let owner else { return }
            Task { @MainActor in coordinator.endCall(owner: owner) }
        }
        if let audioWorker { audioWorker.stop(completion: release) } else { release() }
    }

    /// 静音仅阻止麦克风数据送往ASR，播放和回声消除继续运行。
    func setMuted(_ isMuted: Bool) {
        gate.setMuted(isMuted)
    }

    /// 通过唯一会话协调器切换扬声器；系统拒绝路由时结束通话。
    func setSpeaker(_ isSpeaker: Bool) throws {
        guard isRunning else { throw NanoMuseCallAudioFailure.sessionFailed }
        do { try coordinator.setCallSpeaker(isSpeaker) }
        catch {
            fail(.sessionFailed, attempt: lifecycleGeneration)
            throw NanoMuseCallAudioFailure.sessionFailed
        }
    }

    private func checkAttempt(_ attempt: UInt64) throws {
        try Task.checkCancellation()
        guard attempt == lifecycleGeneration, isStarting else { throw CancellationError() }
    }

    private func fail(_ failure: NanoMuseCallAudioFailure, attempt: UInt64) {
        guard attempt == lifecycleGeneration, isRunning || isStarting else { return }
        let callback = onFailure
        stop()
        callback?(failure.localizedDescription)
    }

    private static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        default: return false
        }
    }

    private func registerNotifications(attempt: UInt64) {
        let center = NotificationCenter.default
        observers.add(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                         object: nil, queue: nil) { [weak self] note in
            // 仅传递可发送的原因值，禁止把系统Notification或音频节点跨隔离域传递。
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.fail(.interrupted, attempt: attempt) }
        })
        observers.add(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                         object: nil, queue: nil) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor [weak self] in self?.handleRouteChange(reason, attempt: attempt) }
        })
        for name in [AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.add(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.fail(.audioServiceReset, attempt: attempt) }
            })
        }
        observers.add(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                         object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, attempt == self.lifecycleGeneration else { return }
                self.worker?.checkConfiguration()
            }
        })
    }

    private func handleRouteChange(_ rawReason: UInt, attempt: UInt64) {
        guard attempt == lifecycleGeneration, isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord, session.mode == .voiceChat,
              !session.currentRoute.inputs.isEmpty, !session.currentRoute.outputs.isEmpty else {
            fail(.routeChanged, attempt: attempt)
            return
        }
        let signature = Self.currentRouteSignature()
        let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable
            || reason == .noSuitableRouteForCategory {
            fail(.routeChanged, attempt: attempt)
            return
        }
        // 用户切换听筒和扬声器允许继续；耳机接入、断开及硬件格式改变须重新通话。
        let isOwnRouteChange = reason == .override || reason == .categoryChange
        if signature != routeSignature && !isOwnRouteChange {
            fail(.routeChanged, attempt: attempt)
            return
        }
        routeSignature = signature
        worker?.checkConfiguration()
    }

    private static func currentRouteSignature() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        return (route.inputs + route.outputs).map { "\($0.portType.rawValue):\($0.uid)" }.joined(separator: "|")
    }
}

/// 通话错误只包含固定文案，系统内部错误和服务商内容不进入界面。
enum NanoMuseCallAudioFailure: Error, LocalizedError, Sendable, Equatable {
    case permissionDenied, microphoneUnavailable, sessionFailed, startFailed
    case inputConversion, playbackFailed, playbackBacklog, routeChanged, interrupted, audioServiceReset

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return AppLocalized("Allow microphone access in Settings to start a call.")
        case .microphoneUnavailable:
            return AppLocalized("The microphone is unavailable. Please check your audio device and try again.")
        case .sessionFailed:
            return AppLocalized("Couldn't activate call audio. Please try again.")
        case .startFailed:
            return AppLocalized("Couldn't start call audio. Please try again.")
        case .inputConversion:
            return AppLocalized("Couldn't process microphone audio. Please start a new call.")
        case .playbackFailed:
            return AppLocalized("Couldn't play the call audio. Please start a new call.")
        case .playbackBacklog:
            return AppLocalized("Too much call audio is waiting to play. Please start a new call.")
        case .routeChanged:
            return AppLocalized("The audio device changed. Please start a new call.")
        case .interrupted:
            return AppLocalized("The call was interrupted by the system. Please start a new call.")
        case .audioServiceReset:
            return AppLocalized("The audio service restarted. Please start a new call.")
        }
    }
}

/// 跨线程仅共享受锁保护的标量、发送闭包与延续，不共享AVAudioEngine或主线程状态。
final class NanoMuseCallAudioGate: @unchecked Sendable {
    /// 一块待播放数据的会话、播放代次与唯一编号。
    struct PlaybackTicket: Sendable {
        let session: UInt64
        let playback: UInt64
        let identifier: UInt64
    }

    private let lock = NSLock()
    private let maximumPendingBytes: Int
    private var session: UInt64 = 0
    private var playback: UInt64 = 0
    private var nextIdentifier: UInt64 = 0
    private var isActive = false
    private var isMuted = false
    private var pending: [UInt64: Int] = [:]
    private var pendingBytes = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var pcmHandler: (@Sendable (Data) -> Void)?

    /// 默认最多缓冲60秒24kHzPCM16，限制网络快于播放设备时的内存占用。
    init(maximumPendingBytes: Int = 24000 * 2 * 60) {
        self.maximumPendingBytes = maximumPendingBytes
    }

    /// 创建新的会话代次；旧播放和旧输入在返回前失效。
    func beginSession() -> UInt64 {
        let result = lock.withLock {
            session &+= 1
            isActive = true
            return (session, clearPlaybackLocked())
        }
        result.1.forEach { $0.resume() }
        return result.0
    }

    /// 撤销会话，并唤醒所有尾音等待者。
    func endSession() {
        let continuations = lock.withLock {
            session &+= 1
            isActive = false
            isMuted = false
            return clearPlaybackLocked()
        }
        continuations.forEach { $0.resume() }
    }

    /// 更新发送闭包，不要求音频回调访问主线程属性。
    func setPCMHandler(_ handler: (@Sendable (Data) -> Void)?) {
        lock.withLock { pcmHandler = handler }
    }

    /// 更新静音标记，排队中的旧输入在发送前再次检查此标记。
    func setMuted(_ isMuted: Bool) {
        lock.withLock { self.isMuted = isMuted }
    }

    /// 判断输入是否仍属于当前、未静音的会话。
    func acceptsInput(generation: UInt64) -> Bool {
        lock.withLock { isActive && !isMuted && session == generation }
    }

    /// 判断一项硬件操作是否仍属于当前会话。
    func isCurrentSession(_ generation: UInt64) -> Bool {
        lock.withLock { isActive && session == generation }
    }

    /// 发送转换后的PCM；调用闭包时不持锁，允许上层安全发起停止操作。
    func deliverPCM(_ data: Data, generation: UInt64) {
        let handler = lock.withLock {
            isActive && !isMuted && session == generation ? pcmHandler : nil
        }
        handler?(data)
    }

    /// 入队前登记待播放数据，以覆盖尚未交给硬件的排队时间。
    func reservePlayback(byteCount: Int, generation: UInt64? = nil) throws -> PlaybackTicket? {
        try lock.withLock {
            guard isActive, byteCount > 0, generation == nil || generation == session else { return nil }
            guard byteCount <= maximumPendingBytes - pendingBytes else {
                throw NanoMuseCallAudioFailure.playbackBacklog
            }
            nextIdentifier &+= 1
            pending[nextIdentifier] = byteCount
            pendingBytes += byteCount
            return PlaybackTicket(session: session, playback: playback, identifier: nextIdentifier)
        }
    }

    /// 判断播放器完成回调是否仍属于当前未撤销的缓冲。
    func isCurrent(_ ticket: PlaybackTicket) -> Bool {
        lock.withLock {
            isActive && ticket.session == session && ticket.playback == playback
                && pending[ticket.identifier] != nil
        }
    }

    /// 仅当前代次可以减少计数；重复及过期完成回调不影响新缓冲。
    func completePlayback(_ ticket: PlaybackTicket) {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard ticket.session == session, ticket.playback == playback,
                  let byteCount = pending.removeValue(forKey: ticket.identifier) else { return [] }
            pendingBytes -= byteCount
            guard pending.isEmpty else { return [] }
            let values = Array(waiters.values)
            waiters.removeAll()
            return values
        }
        continuations.forEach { $0.resume() }
    }

    /// 撤销本轮播放；新数据与旧完成回调具有不同的播放代次。
    func clearPlayback() {
        let continuations = lock.withLock { clearPlaybackLocked() }
        continuations.forEach { $0.resume() }
    }

    /// 当前是否仍有排队或正在硬件中播放的数据。
    var isPlaybackPending: Bool { lock.withLock { !pending.isEmpty } }

    /// 等待播放队列耗尽；取消任务不应阻止父级通话退出。
    func drainPlayback() async {
        let identifier = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let shouldResume = lock.withLock {
                    guard !Task.isCancelled, !pending.isEmpty else { return true }
                    waiters[identifier] = continuation
                    return false
                }
                if shouldResume { continuation.resume() }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.waiters.removeValue(forKey: identifier) }
            continuation?.resume()
        }
    }

    private func clearPlaybackLocked() -> [CheckedContinuation<Void, Never>] {
        playback &+= 1
        pending.removeAll()
        pendingBytes = 0
        let values = Array(waiters.values)
        waiters.removeAll()
        return values
    }
}

/// 将网络小端PCM16转换为播放器使用的Float32，保留一个跨分块字节。
struct NanoMuseCallPCM16Stream {
    private var trailingByte: UInt8?

    /// 只输出完整样本，不要求每个网络分块具有偶数字节。
    mutating func append(_ data: Data) -> [Float] {
        var bytes = Data()
        if let trailingByte { bytes.append(trailingByte) }
        bytes.append(data)
        trailingByte = bytes.count.isMultiple(of: 2) ? nil : bytes.last
        var samples: [Float] = []
        samples.reserveCapacity(bytes.count / 2)
        for offset in stride(from: 0, to: bytes.count - bytes.count % 2, by: 2) {
            let value = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            samples.append(Float(Int16(bitPattern: value)) / 32768)
        }
        return samples
    }

    /// 打断后丢弃半个旧样本。
    mutating func reset() { trailingByte = nil }
}

/// 音频图、播放器、重采样器及PCM半样本全部只在本对象的串行队列访问。
private final class NanoMuseCallAudioWorker: @unchecked Sendable {
    // 各通话实例共用硬件队列，快速重拨必须排在旧引擎清理之后。
    private static let AUDIO_QUEUE = DispatchQueue(label: "nanomuse.call.audio", qos: .userInitiated)
    private let queue = NanoMuseCallAudioWorker.AUDIO_QUEUE
    private let gate: NanoMuseCallAudioGate
    private let onFailure: @Sendable (NanoMuseCallAudioFailure) -> Void
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var inputNode: AVAudioInputNode?
    private var hasTap = false
    private var inputFormat: AVAudioFormat?
    private var playbackFormat: AVAudioFormat?
    private var converter = NanoMuseCallInputConverter()
    private var pcmStream = NanoMuseCallPCM16Stream()

    /// 闭包只向主线程传递可发送的失败枚举，不传递AVFoundation对象。
    init(gate: NanoMuseCallAudioGate,
         onFailure: @escaping @Sendable (NanoMuseCallAudioFailure) -> Void) {
        self.gate = gate
        self.onFailure = onFailure
    }

    /// 在后台音频队列创建并启动图，等待结果时不阻塞主线程。
    func start(generation: UInt64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.gate.isCurrentSession(generation) else { throw CancellationError() }
                    try self.configure(generation: generation)
                    guard self.gate.isCurrentSession(generation) else { throw CancellationError() }
                    continuation.resume()
                } catch {
                    self.tearDown()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 音频回调只持有独立工作对象，不能直接访问任何主线程属性。
    private func capture(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        guard buffer.frameLength > 0, gate.acceptsInput(generation: generation) else { return }
        guard let owned = NanoMuseCallOwnedInput(buffer) else {
            onFailure(.inputConversion)
            return
        }
        queue.async {
            guard self.gate.acceptsInput(generation: generation) else { return }
            do {
                let data = try self.converter.convert(owned.buffer)
                if !data.isEmpty { self.gate.deliverPCM(data, generation: generation) }
            } catch { self.onFailure(.inputConversion) }
        }
    }

    /// 将连续PCM分块追加到同一播放器，完成类型包含设备实际播放延迟。
    func play(_ data: Data, ticket: NanoMuseCallAudioGate.PlaybackTicket) {
        queue.async {
            guard self.gate.isCurrent(ticket) else { return }
            guard let player = self.player, let format = self.playbackFormat,
                  self.engine?.isRunning == true else {
                self.gate.completePlayback(ticket)
                self.onFailure(.playbackFailed)
                return
            }
            let samples = self.pcmStream.append(data)
            guard !samples.isEmpty else { self.gate.completePlayback(ticket); return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else {
                self.gate.completePlayback(ticket)
                self.onFailure(.playbackFailed)
                return
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                if let baseAddress = source.baseAddress {
                    channel.update(from: baseAddress, count: source.count)
                }
            }
            let gate = self.gate
            let scheduled = noff_try_objc {
                player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                    gate.completePlayback(ticket)
                }
                if !player.isPlaying { player.play() }
            }
            if !scheduled {
                gate.completePlayback(ticket)
                self.onFailure(.playbackFailed)
            }
        }
    }

    /// 停止节点时的旧完成回调已经被门闩撤销，不能清除后续播放计数。
    func stopPlayback() {
        queue.async {
            _ = noff_try_objc { self.player?.stop() }
            self.pcmStream.reset()
        }
    }

    /// 检查系统重配是否停止引擎或改变输入格式，失效时由上层退出通话。
    func checkConfiguration() {
        queue.async {
            guard let engine = self.engine, let input = self.inputNode else { return }
            var isValid = false
            let checked = noff_try_objc {
                isValid = engine.isRunning && input.outputFormat(forBus: 0) == self.inputFormat
                    && input.isVoiceProcessingEnabled
            }
            if !checked || !isValid {
                self.onFailure(.routeChanged)
            }
        }
    }

    /// 串行清理完成后再通知协调器释放会话，避免运行中的引擎阻止停用。
    func stop(completion: @escaping @Sendable () -> Void = {}) {
        queue.async {
            self.tearDown()
            completion()
        }
    }

    private func configure(generation: UInt64) throws {
        var error: (any Error)?
        let configured = noff_try_objc {
            do { try self.configureGraph(generation: generation) }
            catch let caught { error = caught }
        }
        guard configured else { throw NanoMuseCallAudioFailure.startFailed }
        if let error { throw error }
    }

    private func configureGraph(generation: UInt64) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        inputNode = input
        try input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0,
              input.isVoiceProcessingEnabled else { throw NanoMuseCallAudioFailure.microphoneUnavailable }
        self.inputFormat = inputFormat
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1) else {
            throw NanoMuseCallAudioFailure.startFailed
        }
        playbackFormat = format
        let player = AVAudioPlayerNode()
        self.player = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.capture(buffer, generation: generation)
        }
        hasTap = true
        engine.prepare()
        try engine.start()
        guard engine.isRunning else { throw NanoMuseCallAudioFailure.startFailed }
    }

    private func tearDown() {
        _ = noff_try_objc { self.player?.stop() }
        _ = noff_try_objc { self.engine?.stop() }
        if hasTap {
            _ = noff_try_objc { self.inputNode?.removeTap(onBus: 0) }
        }
        if let player {
            _ = noff_try_objc {
                self.engine?.disconnectNodeOutput(player)
                self.engine?.detach(player)
            }
        }
        hasTap = false
        inputNode = nil
        player = nil
        engine = nil
        inputFormat = nil
        playbackFormat = nil
        converter = NanoMuseCallInputConverter()
        pcmStream.reset()
    }
}

/// 输入tap持有的缓存只在回调期间有效，先复制后跨队列传递，之后仅工作队列访问。
private final class NanoMuseCallOwnedInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    /// 拷贝所有声道的原生字节，保留硬件提供的格式与帧长度。
    init?(_ source: AVAudioPCMBuffer) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return nil }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            guard let from = sourceBuffers[index].mData, let to = destinationBuffers[index].mData else { return nil }
            let count = destinationBuffers[index].mDataByteSize
            guard sourceBuffers[index].mDataByteSize >= count else { return nil }
            memcpy(to, from, Int(count))
        }
        buffer = copy
    }
}

/// 保留跨缓冲重采样状态，把硬件PCM转换成单声道16kHzPCM16。
final class NanoMuseCallInputConverter {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    /// 实例只在调用方串行队列访问；连续缓冲共用转换器以保留滤波尾部。
    func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        guard input.frameLength > 0 else { return Data() }
        guard input.format.sampleRate > 0, input.format.channelCount > 0,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                               channels: 1, interleaved: true) else {
            throw NanoMuseCallAudioFailure.inputConversion
        }
        if converter == nil || sourceFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
            converter?.downmix = true
            sourceFormat = input.format
        }
        guard let converter else { throw NanoMuseCallAudioFailure.inputConversion }
        let frames = ceil(Double(input.frameLength) * 16000 / input.format.sampleRate) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames)) else {
            throw NanoMuseCallAudioFailure.inputConversion
        }
        let feeder = NanoMuseCallConverterInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            feeder.take(status: inputStatus)
        }
        guard status != .error, error == nil, let samples = output.int16ChannelData?[0] else {
            throw NanoMuseCallAudioFailure.inputConversion
        }
        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

/// 转换器输入闭包只领取一次不可变缓存，避免并发闭包捕获可变局部变量。
private final class NanoMuseCallConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    /// 输入缓存将在同步转换结束前由本对象持有。
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    /// 暂无更多实时数据时使用noDataNow，不能把每个tap误报为整个流结束。
    func take(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            guard let buffer else { status.pointee = .noDataNow; return nil }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }
}

/// 观察令牌只在锁内增删，对象释放时允许在任意线程撤销系统观察。
private final class NanoMuseCallAudioObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    deinit { removeAll() }

    /// 保存系统观察令牌以便统一清理。
    func add(_ token: NSObjectProtocol) { lock.withLock { tokens.append(token) } }

    /// 先清空持有的令牌，再在锁外移除观察，避免通知中心重入锁。
    func removeAll() {
        let removed = lock.withLock {
            let removed = tokens
            tokens.removeAll()
            return removed
        }
        removed.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
