import Combine
import Foundation

/// 一次通话的生命周期；所有状态转移在主线程，过期回调不能重启播放。
@MainActor
final class NanoMuseCallSession: ObservableObject {
    enum Phase: String {
        case idle = "Ready to call"
        case connecting = "Connecting"
        case listening = "Listening"
        case hearing = "Hearing you"
        case thinking = "Thinking"
        case speaking = "Speaking"
        case ended = "Call ended"
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var heard = ""
    @Published private(set) var reply = ""
    @Published private(set) var problem: String?
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeaker = true
    @Published private(set) var isRunning = false
    @Published private(set) var isAudioReady = false
    private(set) weak var vm: AIChatViewModel?
    private static weak var active: NanoMuseCallSession?
    private let audio = NanoMuseCallAudio()
    private var recognizer: NanoMuseDashScopeRecognizer?
    private var synthesizer: NanoMuseDashScopeSynthesizer?
    private var answerTask: Task<Void, Never>?
    private var callGeneration = UUID()
    private var turnGeneration = UUID()
    private var earGeneration = UUID()
    private var endpoint: URL?
    private var apiKey = ""
    private var settings = NanoMuseCallSettings()
    private var isSynthesisDone = false
    private var isStarting = false
    private var finalReply = ""
    private var isModelSettled = true
    private var cleanupGeneration = UUID()
    private var earStartedAt = Date()
    private var shortEarRestarts = 0
    private var reconnectTask: Task<Void, Never>?

    /// 通话期间暂停普通朗读，避免两个播放器同时输出。
    static var isActive: Bool { active?.isRunning == true }

    /// 只有发起通话的聊天临时关闭思考；不修改持久化设置。
    static func contains(_ vm: AIChatViewModel) -> Bool {
        active?.isRunning == true && active?.vm === vm
    }

    /// 工具循环确认本轮最终答案后才交给通话，过程说明不会被朗读。
    static func acceptFinalAnswer(_ text: String, from vm: AIChatViewModel, generation: UUID?) {
        guard contains(vm), generation == active?.turnGeneration else { return }
        active?.finalReply = VoiceTextSanitizer.sanitize(text)
    }

    /// 请求开始时捕获代次，防止已取消的模型任务把旧答案送给下一轮。
    static func generation(for vm: AIChatViewModel) -> UUID? {
        contains(vm) ? active?.turnGeneration : nil
    }

    /// 通话提示只保存在内存中，应用退出后不会残留到普通聊天。
    static func prompt(for vm: AIChatViewModel) -> String? {
        guard contains(vm) else { return nil }
        return """
        Voice call in progress. Reply in the user's language in short, natural spoken sentences.
        The reply is read aloud. Avoid Markdown, code, tables, links and stage directions.
        Keep reasoning and tool details out of the spoken answer.
        """
    }

    /// 绑定现有聊天，识别结果走原有发送和持久化流程。
    init(vm: AIChatViewModel) { self.vm = vm }

    /// 校验配置后请求麦克风；挂断会使尚未完成的权限或音频启动失效。
    func start(settings: NanoMuseCallSettings) async {
        guard !isRunning, !isStarting, let vm else { return }
        let settings = settings.normalized
        guard Self.active?.isRunning != true || Self.active === self else {
            problem = AppLocalized("Another voice call is active.")
            return
        }
        guard !vm.isProcessing, vm.promptQueue.isEmpty, vm.remoteDeviceId == nil,
              vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              vm.attachments.isEmpty else {
            problem = AppLocalized("Finish the current reply and clear the draft before calling.")
            return
        }
        problem = nil
        let attempt = UUID()
        callGeneration = attempt
        isStarting = true
        defer {
            isStarting = false
            if !isRunning, Self.active === self { Self.active = nil }
        }
        do {
            let (resolvedEndpoint, credential) = try settings.connection()
            self.settings = settings
            endpoint = resolvedEndpoint
            apiKey = credential
            let generation = callGeneration
            Self.active = self
            isRunning = true
            shortEarRestarts = 0
            phase = .connecting
            vm.stopSpeech()
            VoiceOutputState.shared.stop()
            audio.onFailure = { [weak self] message in
                Task { @MainActor [weak self] in
                    guard self?.callGeneration == generation else { return }
                    self?.fail(message)
                }
            }
            try await audio.start()
            guard isRunning, callGeneration == generation else { audio.stop(); return }
            try audio.setSpeaker(isSpeaker)
            isAudioReady = true
            startRecognizer()
        } catch {
            guard callGeneration == attempt else { return }
            if error is CancellationError { hangUp(); return }
            fail(error.localizedDescription)
        }
    }

    /// 静音时关闭识别连接，丢弃缓存句子，取消静音后重新建立识别。
    func toggleMute() {
        guard isRunning, isAudioReady else { return }
        isMuted.toggle()
        audio.setMuted(isMuted)
        earGeneration = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        recognizer?.cancel()
        recognizer = nil
        if !isMuted { startRecognizer() }
    }

    /// 切换听筒与免提，路由失败时保持可见错误。
    func toggleSpeaker() {
        guard isRunning, isAudioReady else { return }
        do {
            try audio.setSpeaker(!isSpeaker)
            isSpeaker.toggle()
        } catch { problem = error.localizedDescription }
    }

    /// 同步清空播放队列，再取消当前模型回复。
    func interrupt() {
        guard isRunning else { return }
        cancelAnswer()
        phase = .listening
    }

    /// 先使所有回调失效，再释放网络、麦克风与临时通话状态。
    func hangUp() {
        guard isRunning else { return }
        isRunning = false
        isAudioReady = false
        callGeneration = UUID()
        earGeneration = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelAnswer()
        recognizer?.cancel()
        recognizer = nil
        audio.onPCM = nil
        audio.stop()
        apiKey = ""
        endpoint = nil
        isMuted = false
        phase = .ended
        if !isStarting, Self.active === self { Self.active = nil }
    }

    private func startRecognizer() {
        guard isRunning, isAudioReady, !isMuted, let endpoint else { return }
        earGeneration = UUID()
        recognizer?.cancel()
        let generation = earGeneration
        earStartedAt = Date()
        let ear = NanoMuseDashScopeRecognizer(
            endpoint: endpoint, apiKey: apiKey, model: settings.asrModel,
            silenceMs: settings.silenceMs
        )
        recognizer = ear
        audio.onPCM = { [weak ear] data in ear?.send(data) }
        ear.onReady = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.earGeneration == generation, self.isRunning else { return }
                if self.phase == .connecting { self.phase = .listening }
            }
        }
        ear.onPartial = { [weak self] text in
            DispatchQueue.main.async { [weak self] in self?.receive(text, isFinal: false, generation: generation) }
        }
        ear.onSentence = { [weak self] text in
            DispatchQueue.main.async { [weak self] in self?.receive(text, isFinal: true, generation: generation) }
        }
        ear.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                guard self?.earGeneration == generation else { return }
                self?.fail(Self.describe(error))
            }
        }
        ear.onDone = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, self.earGeneration == generation else { return }
                self.reconnectRecognizer(generation: generation)
            }
        }
        ear.start()
    }

    private func reconnectRecognizer(generation: UUID) {
        shortEarRestarts = Date().timeIntervalSince(earStartedAt) < 30 ? shortEarRestarts + 1 : 0
        guard shortEarRestarts < 3 else {
            fail(AppLocalized("Model Studio sent an invalid voice response."))
            return
        }
        let delay = UInt64(max(1, shortEarRestarts)) * 1_000_000_000
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.earGeneration == generation, self.isRunning, !self.isMuted else { return }
            self.startRecognizer()
        }
    }

    private func receive(_ text: String, isFinal: Bool, generation: UUID) {
        guard isRunning, !isMuted, earGeneration == generation else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if phase == .thinking || phase == .speaking {
            guard NanoMuseCallText.cutsIn(text, spoken: reply) else { return }
            interrupt()
        }
        heard = text
        phase = .hearing
        if isFinal { beginAnswer(text) }
    }

    private func beginAnswer(_ text: String) {
        cancelAnswer()
        let generation = turnGeneration
        phase = .thinking
        reply = ""
        finalReply = ""
        answerTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.answer(text, generation: generation) }
            catch is CancellationError { }
            catch { if self.turnGeneration == generation { self.fail(error.localizedDescription) } }
        }
    }

    private func answer(_ text: String, generation: UUID) async throws {
        guard let vm, let endpoint else { return }
        let readyDeadline = Date().addingTimeInterval(5)
        while (vm.isProcessing || !vm.promptQueue.isEmpty || !isModelSettled), Date() < readyDeadline { try await pause() }
        try Task.checkCancellation()
        guard !vm.isProcessing, vm.promptQueue.isEmpty, isModelSettled, isRunning, turnGeneration == generation else {
            throw NanoMuseCallSettings.Failure(message: AppLocalized("The previous reply has not stopped yet. Try calling again."))
        }
        let tts = makeSynthesizer(endpoint: endpoint, generation: generation)
        synthesizer = tts
        isSynthesisDone = false
        var written = ""
        var buffer = ""
        var hasStartedSpeech = false
        vm.inputText = text
        vm.send()
        let deadline = Date().addingTimeInterval(120)
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else {
                throw NanoMuseCallSettings.Failure(message: AppLocalized("The voice reply timed out. Try calling again."))
            }
            let current = finalReply
            if current.hasPrefix(written) {
                buffer += String(current.dropFirst(written.count))
                written = current
                reply = current
                for piece in NanoMuseCallText.takeChunks(from: &buffer, flush: !vm.isProcessing) {
                    if !hasStartedSpeech { hasStartedSpeech = true; tts.start() }
                    tts.push(piece)
                }
            }
            if !vm.isProcessing { break }
            try await pause()
        }
        guard hasStartedSpeech else {
            throw NanoMuseCallSettings.Failure(message: AppLocalized("No spoken reply came back. Check the chat model."))
        }
        tts.finish()
        while !isSynthesisDone || audio.isPlaybackPending {
            try Task.checkCancellation()
            guard Date() < deadline else {
                throw NanoMuseCallSettings.Failure(message: AppLocalized("The voice reply timed out. Try calling again."))
            }
            try await pause()
        }
        guard turnGeneration == generation, isRunning else { return }
        synthesizer = nil
        answerTask = nil
        phase = .listening
    }

    private func makeSynthesizer(endpoint: URL, generation: UUID) -> NanoMuseDashScopeSynthesizer {
        let tts = NanoMuseDashScopeSynthesizer(
            endpoint: endpoint, apiKey: apiKey, model: settings.ttsModel, voice: settings.voice
        )
        tts.onAudio = { [weak self] data in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, self.turnGeneration == generation else { return }
                self.phase = .speaking
                self.audio.play(data)
            }
        }
        tts.onDone = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard self?.turnGeneration == generation else { return }
                self?.isSynthesisDone = true
            }
        }
        tts.onFailure = { [weak self] failure in
            Task { @MainActor [weak self] in
                guard self?.turnGeneration == generation else { return }
                self?.fail(Self.describe(failure))
            }
        }
        return tts
    }

    private func cancelAnswer() {
        turnGeneration = UUID()
        let hadAnswer = answerTask != nil
        answerTask?.cancel()
        answerTask = nil
        synthesizer?.cancel()
        synthesizer = nil
        audio.stopPlayback()
        if hadAnswer, vm?.isProcessing == true {
            // cancel会立即清除isProcessing，仍须等待旧任务结束后才能发送下一轮。
            let previousTask = vm?.currentTask
            let cleanup = UUID()
            cleanupGeneration = cleanup
            isModelSettled = previousTask == nil
            vm?.cancel()
            Task { [weak self] in
                await previousTask?.value
                guard self?.cleanupGeneration == cleanup else { return }
                self?.isModelSettled = true
            }
        }
    }

    private func fail(_ message: String) {
        problem = message
        hangUp()
    }

    private func pause() async throws { try await Task.sleep(nanoseconds: 100_000_000) }

    private static func describe(_ failure: NanoMuseDashScope.Failure) -> String {
        switch failure {
        case .refused(let code):
            return String(format: AppLocalized("Model Studio refused the key (HTTP %d)."), code)
        case .network(let message), .task(let message): return message
        }
    }
}
