//
//  NanoMuseDashScope.swift
//  nanoMuse
//
//  百炼Inference WebSocket：每条连接只有一个任务，等待task-started后按顺序发送输入。
//

import Foundation

/// 百炼语音协议共用的地址、消息头和错误。
enum NanoMuseDashScope {
    static let defaultEndpoint = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"

    enum Failure: Error, Sendable {
        case refused(Int)
        case network(String)
        case task(String)
    }

    /// 使用配置地址的主机和端口，拒绝无效地址，避免把密钥误送到默认区域。
    static func endpoint(forBase base: String) throws -> URL {
        var components = try origin(forBase: base)
        components.scheme = "wss"
        components.path = "/api-ws/v1/inference"
        guard let endpoint = components.url else { throw invalidAddress() }
        return endpoint
    }

    /// 提取安全的服务商源地址，原有路径由具体API重新设置。
    static func origin(forBase base: String) throws -> URLComponents {
        guard var components = URLComponents(
            string: base.trimmingCharacters(in: .whitespacesAndNewlines)
        ), let scheme = components.scheme?.lowercased(),
              ["https", "wss"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw invalidAddress() }
        components.scheme = "https"
        components.path = ""
        guard components.url != nil else { throw invalidAddress() }
        return components
    }

    /// 创建同一任务共享的协议头。
    static func header(_ action: String, _ taskId: String) -> [String: Any] {
        ["action": action, "task_id": taskId, "streaming": "duplex"]
    }

    /// 序列化失败时明确终止，不能发送空对象继续等待。
    static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func invalidAddress() -> Failure {
        .task(AppLocalized("The provider's address is not a URL."))
    }
}

/// 只在同步临界区访问内容，回调和continuation均在解锁后调用。
final class NanoMuseVoiceLock<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation(&value)
    }
}

/// 独立于网络的发送状态机，保证输入和结束标记的FIFO顺序。
struct NanoMuseDashScopeBuffer: Sendable {
    enum Message: Equatable, Sendable {
        case text(String)
        case audio(Data)
        case finish

        var byteCount: Int {
            switch self {
            case .text(let text): return text.utf8.count
            case .audio(let data): return data.count
            case .finish: return 0
            }
        }
    }

    private let maximumBytes: Int
    private let maximumMessages: Int
    private var messages: [Message] = []
    private var readIndex = 0
    private var byteCount = 0
    private(set) var isReady = false
    private(set) var isFinishing = false
    private(set) var isClosed = false

    init(maximumBytes: Int = 16 * 1024 * 1024, maximumMessages: Int = 4096) {
        self.maximumBytes = maximumBytes
        self.maximumMessages = maximumMessages
    }

    /// 返回false表示缓冲已满，调用方必须失败，不能删掉最早的输入。
    mutating func append(_ message: Message) -> Bool {
        guard !isClosed, !isFinishing else { return true }
        guard message.byteCount <= maximumBytes - byteCount,
              messages.count - readIndex < maximumMessages else { return false }
        messages.append(message)
        byteCount += message.byteCount
        return true
    }

    /// 重复的task-started不会重复触发onReady或重发缓冲。
    mutating func markReady() -> Bool {
        guard !isClosed, !isReady else { return false }
        isReady = true
        return true
    }

    /// 结束标记和普通消息共用队列，不能越过尚未发送的输入。
    mutating func finish() -> Bool {
        guard !isClosed, !isFinishing else { return false }
        isFinishing = true
        messages.append(.finish)
        return true
    }

    mutating func next() -> Message? {
        guard isReady, !isClosed, readIndex < messages.count else { return nil }
        let message = messages[readIndex]
        readIndex += 1
        byteCount -= message.byteCount
        if readIndex == messages.count {
            messages.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex >= 128, readIndex >= messages.count / 2 {
            messages.removeFirst(readIndex)
            readIndex = 0
        }
        return message
    }

    mutating func close() {
        isClosed = true
        messages.removeAll()
        readIndex = 0
        byteCount = 0
    }
}

/// 单任务传输层，任务状态由串行队列保护，回调属性由同步锁保护。
class NanoMuseDashScopeTask: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private struct Callbacks {
        var ready: (@Sendable () -> Void)?
        var done: (@Sendable () -> Void)?
        var failure: (@Sendable (NanoMuseDashScope.Failure) -> Void)?
    }

    let taskId = UUID().uuidString
    private let request: URLRequest
    private let completionTimeout: TimeInterval
    private let completionTimeoutMessage: String
    private let allowsServerCompletion: Bool
    private let stateQueue = DispatchQueue(label: "nanomuse.dashscope")
    private let callbacks = NanoMuseVoiceLock(Callbacks())
    private var buffer = NanoMuseDashScopeBuffer()
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var hasOpened = false
    private var isSending = false
    private var hasSentFinish = false
    private var startTimer: DispatchSourceTimer?
    private var finishTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?

    /// 所有业务回调在内部串行队列执行，界面调用方需要自行切回MainActor。
    var onReady: (@Sendable () -> Void)? {
        get { callbacks.withValue { $0.ready } }
        set { callbacks.withValue { $0.ready = newValue } }
    }

    var onDone: (@Sendable () -> Void)? {
        get { callbacks.withValue { $0.done } }
        set { callbacks.withValue { $0.done = newValue } }
    }

    var onFailure: (@Sendable (NanoMuseDashScope.Failure) -> Void)? {
        get { callbacks.withValue { $0.failure } }
        set { callbacks.withValue { $0.failure = newValue } }
    }

    init(
        endpoint: URL, apiKey: String, completionTimeout: TimeInterval,
        completionTimeoutMessage: String, allowsServerCompletion: Bool = false
    ) {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Nicholasx-iOS", forHTTPHeaderField: "user-agent")
        request.timeoutInterval = 15
        self.request = request
        self.completionTimeout = completionTimeout
        self.completionTimeoutMessage = completionTimeoutMessage
        self.allowsServerCompletion = allowsServerCompletion
        super.init()
    }

    /// 幂等地打开连接，取消之后不能重新启动同一个任务。
    func start() {
        stateQueue.async {
            guard self.session == nil, !self.buffer.isClosed else { return }
            guard self.request.url?.scheme?.lowercased() == "wss" else {
                self.fail(.task(AppLocalized("The provider's address is not a URL.")))
                return
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let socket = session.webSocketTask(with: self.request)
            self.session = session
            self.socket = socket
            self.startTimer = self.deadline(after: 15) { [weak self] in
                self?.fail(.task(AppLocalized("Model Studio did not start the voice task within 15 seconds.")))
            }
            socket.resume()
            self.receive()
        }
    }

    /// 子类提供run-task业务参数，只在内部串行队列调用。
    func runPayload() -> [String: Any] { [:] }

    /// 子类处理已通过任务ID校验的业务事件。
    func handleEvent(_ event: String, _ object: [String: Any]) {}

    /// 子类处理服务端返回的二进制PCM。
    func handleAudio(_ data: Data) {}

    /// 排队等待服务端就绪，发送失败和缓冲耗尽都会结束任务。
    func post(_ message: NanoMuseDashScopeBuffer.Message) {
        stateQueue.async {
            guard self.buffer.append(message) else {
                self.fail(.task(AppLocalized("Model Studio voice input exceeded the pending buffer limit.")))
                return
            }
            self.sendNext()
        }
    }

    /// 所有输入排完后请求结束，服务端必须在限定时间内返回task-finished。
    func finish() {
        stateQueue.async {
            guard self.buffer.finish() else { return }
            self.finishTimer = self.deadline(after: self.completionTimeout) { [weak self] in
                guard let self else { return }
                self.fail(.task(self.completionTimeoutMessage))
            }
            self.sendNext()
        }
    }

    /// 取消不产生业务回调，一次性调用的取消处理器负责唤醒等待者。
    func cancel() { stateQueue.async { self.close() } }

    private func deadline(after seconds: TimeInterval, action: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: action)
        timer.resume()
        return timer
    }

    private func close() {
        guard !buffer.isClosed else { return }
        buffer.close()
        startTimer?.cancel()
        finishTimer?.cancel()
        pingTimer?.cancel()
        startTimer = nil
        finishTimer = nil
        pingTimer = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
    }

    private func fail(_ failure: NanoMuseDashScope.Failure) {
        guard !buffer.isClosed else { return }
        close()
        onFailure?(failure)
    }

    private func transportFailed(_ error: Error) {
        if let code = (socket?.response as? HTTPURLResponse)?.statusCode, code == 401 || code == 403 {
            fail(.refused(code))
        } else {
            fail(.network(error.localizedDescription))
        }
    }

    private func sendNext() {
        guard !isSending, !buffer.isClosed, let message = buffer.next() else { return }
        do {
            let frame: URLSessionWebSocketTask.Message
            switch message {
            case .audio(let data): frame = .data(data)
            case .text(let text):
                frame = .string(try NanoMuseDashScope.json([
                    "header": NanoMuseDashScope.header("continue-task", taskId),
                    "payload": ["input": ["text": text]],
                ]))
            case .finish:
                hasSentFinish = true
                frame = .string(try NanoMuseDashScope.json([
                    "header": NanoMuseDashScope.header("finish-task", taskId),
                    "payload": ["input": [String: Any]()],
                ]))
            }
            send(frame)
        } catch { fail(.task(error.localizedDescription)) }
    }

    private func send(_ message: URLSessionWebSocketTask.Message) {
        guard let socket, !buffer.isClosed else { return }
        isSending = true
        socket.send(message) { [weak self] error in
            guard let self else { return }
            self.stateQueue.async {
                guard !self.buffer.isClosed else { return }
                self.isSending = false
                if let error { self.transportFailed(error) } else { self.sendNext() }
            }
        }
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            self.stateQueue.async {
                guard !self.buffer.isClosed else { return }
                switch result {
                case .failure(let error): self.transportFailed(error)
                case .success(let message):
                    switch message {
                    case .data(let data):
                        guard self.buffer.isReady else {
                            self.fail(.task(AppLocalized("Model Studio sent an invalid voice response.")))
                            return
                        }
                        self.handleAudio(data)
                    case .string(let text): self.handleText(text)
                    @unknown default:
                        self.fail(.task(AppLocalized("Model Studio sent an invalid voice response.")))
                    }
                    if !self.buffer.isClosed { self.receive() }
                }
            }
        }
    }

    private func handleText(_ text: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let header = object["header"] as? [String: Any],
              let event = header["event"] as? String,
              let receivedTaskId = header["task_id"] as? String, receivedTaskId == taskId else {
            fail(.task(AppLocalized("Model Studio sent an invalid voice response.")))
            return
        }
        switch event {
        case "task-started":
            guard hasOpened, buffer.markReady() else { return }
            startTimer?.cancel()
            startTimer = nil
            beginPinging()
            onReady?()
            sendNext()
        case "task-finished":
            guard buffer.isReady, hasSentFinish || allowsServerCompletion else {
                fail(.task(AppLocalized("Model Studio sent an invalid voice response.")))
                return
            }
            handleEvent(event, object)
            close()
            onDone?()
        case "task-failed":
            let code = header["error_code"] as? String ?? ""
            let message = header["error_message"] as? String ?? ""
            let detail = [code, message].filter { !$0.isEmpty }.joined(separator: ": ")
            fail(.task(detail.isEmpty ? AppLocalized("Model Studio sent an invalid voice response.") : detail))
        default:
            guard buffer.isReady else {
                fail(.task(AppLocalized("Model Studio sent an invalid voice response.")))
                return
            }
            handleEvent(event, object)
        }
    }

    private func beginPinging() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, !self.buffer.isClosed else { return }
            self.socket?.sendPing { [weak self] error in
                guard let self, let error else { return }
                self.stateQueue.async { self.transportFailed(error) }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    /// 建立连接后只发送一次run-task，输入仍等待task-started。
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        stateQueue.async {
            guard !self.buffer.isClosed, !self.hasOpened else { return }
            self.hasOpened = true
            do {
                let run = try NanoMuseDashScope.json([
                    "header": NanoMuseDashScope.header("run-task", self.taskId),
                    "payload": self.runPayload(),
                ])
                self.send(.string(run))
            } catch { self.fail(.task(error.localizedDescription)) }
        }
    }

    /// 未收到task-finished就断连属于失败，包括客户端已发出finish-task的情况。
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        stateQueue.async {
            let detail = reason.flatMap { String(data: $0, encoding: .utf8) }
                ?? "WebSocket closed (\(closeCode.rawValue))"
            self.fail(.network(detail))
        }
    }

    /// 握手失败可能只有task delegate回调，也要保留HTTP鉴权状态。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        stateQueue.async { self.transportFailed(error) }
    }
}

/// Fun-ASR和Paraformer实时识别：PCM16单声道输入，分开回传中间结果和最终句子。
final class NanoMuseDashScopeRecognizer: NanoMuseDashScopeTask, @unchecked Sendable {
    private struct Callbacks {
        var partial: (@Sendable (String) -> Void)?
        var sentence: (@Sendable (String) -> Void)?
    }

    private let model: String
    private let sampleRate: Int
    private let silenceMs: Int
    private let callbacks = NanoMuseVoiceLock(Callbacks())
    private var finalSentenceIds: Set<String> = []

    var onPartial: (@Sendable (String) -> Void)? {
        get { callbacks.withValue { $0.partial } }
        set { callbacks.withValue { $0.partial = newValue } }
    }

    var onSentence: (@Sendable (String) -> Void)? {
        get { callbacks.withValue { $0.sentence } }
        set { callbacks.withValue { $0.sentence = newValue } }
    }

    /// 默认允许服务端正常结束长通话任务，一次性转写应明确传入false。
    init(
        endpoint: URL, apiKey: String, model: String, sampleRate: Int = 16000,
        silenceMs: Int, allowsServerCompletion: Bool = true
    ) {
        self.model = model
        self.sampleRate = sampleRate
        self.silenceMs = min(6000, max(200, silenceMs))
        super.init(
            endpoint: endpoint, apiKey: apiKey, completionTimeout: 30,
            completionTimeoutMessage: AppLocalized("Model Studio did not finish the recognition within 30 seconds."),
            allowsServerCompletion: allowsServerCompletion
        )
    }

    /// 创建官方Inference识别请求，心跳结果不会当成识别文字。
    override func runPayload() -> [String: Any] {
        [
            "task_group": "audio", "task": "asr", "function": "recognition", "model": model,
            "parameters": [
                "format": "pcm", "sample_rate": sampleRate,
                "max_sentence_silence": silenceMs, "heartbeat": true,
            ] as [String: Any],
            "input": [String: Any](),
        ]
    }

    /// 发送完整的PCM16采样，调用方不能把WAV头作为音频输入。
    func send(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        post(.audio(pcm))
    }

    /// 同一句的最终结果只交付一次，相同文字但不同句子仍保留。
    override func handleEvent(_ event: String, _ object: [String: Any]) {
        guard event == "result-generated",
              let output = (object["payload"] as? [String: Any])?["output"] as? [String: Any],
              let sentence = output["sentence"] as? [String: Any],
              sentence["heartbeat"] as? Bool != true else { return }
        let text = (sentence["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if sentence["sentence_end"] as? Bool == true {
            if let identity = sentence["sentence_id"] ?? sentence["begin_time"] {
                guard finalSentenceIds.insert(String(describing: identity)).inserted else { return }
            }
            onSentence?(text)
        } else { onPartial?(text) }
    }
}

/// CosyVoice流式合成：按序接收文字，回传指定采样率的PCM16单声道音频。
final class NanoMuseDashScopeSynthesizer: NanoMuseDashScopeTask, @unchecked Sendable {
    private let model: String
    private let voice: String
    private let sampleRate: Int
    private let audioCallback = NanoMuseVoiceLock<(@Sendable (Data) -> Void)?>(nil)

    var onAudio: (@Sendable (Data) -> Void)? {
        get { audioCallback.withValue { $0 } }
        set { audioCallback.withValue { $0 = newValue } }
    }

    init(endpoint: URL, apiKey: String, model: String, voice: String, sampleRate: Int = 24000) {
        self.model = model
        self.voice = voice
        self.sampleRate = sampleRate
        super.init(
            endpoint: endpoint, apiKey: apiKey, completionTimeout: 120,
            completionTimeoutMessage: AppLocalized("Model Studio did not finish the speech within two minutes.")
        )
    }

    /// 不固定language_hints，让所选音色处理多语言输入。
    override func runPayload() -> [String: Any] {
        [
            "task_group": "audio", "task": "tts", "function": "SpeechSynthesizer", "model": model,
            "parameters": [
                "text_type": "PlainText", "voice": voice, "format": "pcm", "sample_rate": sampleRate,
            ] as [String: Any],
            "input": [String: Any](),
        ]
    }

    /// 空白片段不发出，长片段按Unicode标量分块，避免超过服务端字符上限。
    func push(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        for piece in NanoMuseBailianVoice.textPieces(text, maximumScalars: 1000) { post(.text(piece)) }
    }

    override func handleAudio(_ data: Data) { onAudio?(data) }
}
