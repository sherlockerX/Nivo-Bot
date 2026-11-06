//
//  NanoMuseBailianVoice.swift
//  nanoMuse
//
//  百炼语音的一次性入口，按模型选择Inference WebSocket或原生HTTP接口。
//

import Foundation

/// 将回调结果与Swift任务取消合并为一次完成，允许取消早于continuation安装。
final class NanoMuseBailianCompletion<Value: Sendable>: @unchecked Sendable {
    private struct State {
        var value: Value
        var continuation: CheckedContinuation<Value, Error>?
        var result: Result<Value, Error>?
    }

    private let state: NanoMuseVoiceLock<State>

    init(_ value: Value) { state = NanoMuseVoiceLock(State(value: value)) }

    /// 返回false时已经取消或完成，调用方不能再启动网络任务。
    @discardableResult
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let existing = state.withValue { state -> Result<Value, Error>? in
            if let result = state.result { return result }
            if state.continuation != nil {
                return .failure(NanoMuseBailianVoice.Failure(
                    message: AppLocalized("Model Studio sent an invalid voice response.")
                ))
            }
            state.continuation = continuation
            return nil
        }
        if let existing { continuation.resume(with: existing) }
        return existing == nil
    }

    func update(_ operation: (inout Value) -> Void) {
        state.withValue { state in
            guard state.result == nil else { return }
            operation(&state.value)
        }
    }

    /// 锁内只取出continuation，恢复动作放在锁外，避免回调重入死锁。
    @discardableResult
    func complete(failure: Error? = nil) -> Bool {
        let completed = state.withValue { state -> (CheckedContinuation<Value, Error>?, Result<Value, Error>)? in
            guard state.result == nil else { return nil }
            let result: Result<Value, Error> = failure.map { .failure($0) } ?? .success(state.value)
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return (continuation, result)
        }
        guard let completed else { return false }
        completed.0?.resume(with: completed.1)
        return true
    }
}

/// 百炼一次性识别和朗读，不使用OpenAI的audio/transcriptions或audio/speech端点。
enum NanoMuseBailianVoice {
    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    private static let socketRate = 16000
    private static let speechRate = 24000
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    /// 按主机边界识别官方百炼域名，路径和相似域名不能触发密钥转发。
    static func isModelStudio(_ baseURL: String) -> Bool {
        guard let host = URLComponents(
            string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )?.host?.lowercased() else { return false }
        if host.hasSuffix(".maas.aliyuncs.com") { return true }
        return ["dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com", "dashscope-us.aliyuncs.com"].contains(host)
    }

    /// CosyVoice各代系统音色不同，3.5没有系统音色，返回空串表示必须明确指定。
    static func defaultCosyVoice(_ model: String) -> String {
        let id = model.lowercased()
        if id.contains("v3.5") { return "" }
        if id.contains("v3") { return "longanyang" }
        if id.contains("v2") { return "longxiaochun_v2" }
        return "longxiaochun"
    }

    /// 3.5只接受复刻或设计音色，不能静默套用上一代系统音色。
    static func resolvedCosyVoice(_ model: String, requestedVoice: String?) throws -> String {
        if let requestedVoice { return requestedVoice }
        let fallback = defaultCosyVoice(model)
        guard !fallback.isEmpty else {
            throw Failure(message: AppLocalized("CosyVoice 3.5 requires a cloned or designed voice. Enter its voice ID."))
        }
        return fallback
    }

    /// 识别录音，Fun-ASR和Paraformer发送PCM，Qwen发送带MIME类型的WAV数据URL。
    static func transcribe(audio: Data, model: String, baseURL: String, apiKey: String) async throws -> String {
        try Task.checkCancellation()
        let key = try requiredKey(apiKey)
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = id.lowercased()
        if lower.contains("realtime") && (lower.contains("paraformer") || lower.contains("fun-asr")) {
            let rate = lower.contains("8k") ? 8000 : socketRate
            let pcm = try pcm16Mono(fromWAV: audio, rate: rate)
            guard !pcm.isEmpty else { throw invalidAudio() }
            return try await recognize(pcm: pcm, model: id, rate: rate, baseURL: baseURL, apiKey: key)
        }
        if !lower.contains("realtime"), !lower.contains("filetrans"), !lower.contains("tts"),
           lower.contains("omni") || (lower.contains("qwen") && (lower.contains("asr") || lower.contains("audio"))) {
            guard let wav = parseWAV(audio), !wav.pcm.isEmpty else { throw invalidAudio() }
            return try await chatTranscribe(wav: audio, model: id, baseURL: baseURL, apiKey: key)
        }
        throw Failure(message: String(format: AppLocalized("Model Studio serves %@ neither as real-time recognition nor through chat. Use fun-asr-realtime, paraformer-realtime-v2 or qwen3-asr-flash for speech to text."), id))
    }

    private static func recognize(pcm: Data, model: String, rate: Int, baseURL: String, apiKey: String) async throws -> String {
        let recognizer = NanoMuseDashScopeRecognizer(
            endpoint: try NanoMuseDashScope.endpoint(forBase: baseURL), apiKey: apiKey,
            model: model, sampleRate: rate, silenceMs: 800, allowsServerCompletion: false
        )
        let completion = NanoMuseBailianCompletion("")
        defer { recognizer.cancel() }
        let result: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard completion.install(continuation) else { return }
                recognizer.onSentence = { sentence in completion.update { $0 += sentence } }
                recognizer.onDone = { completion.complete() }
                recognizer.onFailure = { failure in completion.complete(failure: describe(failure)) }
                recognizer.start()
                let step = rate * 2 * 4 / 10
                for offset in stride(from: 0, to: pcm.count, by: step) {
                    guard !Task.isCancelled else {
                        completion.complete(failure: CancellationError())
                        recognizer.cancel()
                        return
                    }
                    recognizer.send(pcm.subdata(in: offset..<min(offset + step, pcm.count)))
                }
                recognizer.finish()
            }
        } onCancel: {
            completion.complete(failure: CancellationError())
            recognizer.cancel()
        }
        try Task.checkCancellation()
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 保留配置的兼容模式路径，裸服务商域名自动补上官方路径。
    static func chatEndpoint(forBase baseURL: String) throws -> URL {
        var components = try NanoMuseDashScope.origin(forBase: baseURL)
        let configured = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.path ?? ""
        var path = configured.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty || path == "v1" { path = "compatible-mode/v1" }
        if !path.hasSuffix("/v1") { path += "/v1" }
        components.path = "/" + path + "/chat/completions"
        guard let url = components.url else { throw invalidResponse() }
        return url
    }

    /// Omni是对话模型，需要转写指令；Qwen-ASR直接转写，不额外添加对话指令。
    static func chatBody(wav: Data, model: String) -> [String: Any] {
        let audio: [String: Any] = [
            "type": "input_audio",
            "input_audio": ["data": "data:audio/wav;base64," + wav.base64EncodedString(), "format": "wav"],
        ]
        if model.lowercased().contains("omni") {
            return [
                "model": model,
                "messages": [
                    ["role": "system", "content": "You are a speech-to-text engine. Output only the exact words spoken in the audio, in the language spoken, with nothing else."],
                    ["role": "user", "content": [audio, ["type": "text", "text": "Transcribe this audio."]]],
                ],
                "stream": true, "modalities": ["text"],
            ]
        }
        return [
            "model": model, "messages": [["role": "user", "content": [audio]]],
            "stream": false, "asr_options": ["enable_itn": false],
        ]
    }

    private static func chatTranscribe(wav: Data, model: String, baseURL: String, apiKey: String) async throws -> String {
        let request = try jsonRequest(
            url: chatEndpoint(forBase: baseURL), apiKey: apiKey,
            body: chatBody(wav: wav, model: model)
        )
        let (data, response) = try await execute(request)
        try Task.checkCancellation()
        try check(response, data)
        if model.lowercased().contains("omni") { return try parseChatStream(data) }
        let object = try decodeObject(from: data)
        try checkServerError(object)
        guard let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String else { throw invalidResponse() }
        if let reason = choice["finish_reason"] as? String, reason != "stop" { throw invalidResponse() }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 读取完整SSE事件，既保留错误事件，也拒绝断线留下的部分转写。
    static func parseChatStream(_ data: Data) throws -> String {
        if let object = try? decodeObject(from: data) { try checkServerError(object) }
        var text = ""
        var payloadLines: [String] = []
        var hasFinished = false
        var hasDone = false

        func consume(_ payload: String) throws {
            guard !payload.isEmpty, !hasDone else { return }
            if payload == "[DONE]" { hasDone = true; return }
            let object = try decodeObject(from: Data(payload.utf8))
            try checkServerError(object)
            guard let choices = object["choices"] as? [[String: Any]] else { throw invalidResponse() }
            guard let choice = choices.first else { return }
            if let reason = choice["finish_reason"] as? String {
                guard reason == "stop" else { throw invalidResponse() }
                hasFinished = true
            }
            if let delta = choice["delta"] as? [String: Any], let part = delta["content"] as? String {
                text += part
            }
        }

        for rawLine in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                try consume(payloadLines.joined(separator: "\n"))
                payloadLines.removeAll(keepingCapacity: true)
            } else if line.hasPrefix("data:") {
                payloadLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        try consume(payloadLines.joined(separator: "\n"))
        guard hasDone || hasFinished else { throw invalidResponse() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 合成结果统一为可播放的PCM16单声道WAV，音色字段重复模型名时使用默认音色。
    static func synthesize(text: String, model: String, voice: String?, baseURL: String, apiKey: String) async throws -> Data {
        try Task.checkCancellation()
        let key = try requiredKey(apiKey)
        let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = id.lowercased()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: AppLocalized("Enter text for Model Studio to speak."))
        }
        let requested = voice?.trimmingCharacters(in: .whitespacesAndNewlines)
        let asked = requested.flatMap { $0.isEmpty || $0.lowercased() == lower ? nil : $0 }
        if lower.hasPrefix("cosyvoice") {
            return try await cosyVoice(text: text, model: id, voice: resolvedCosyVoice(id, requestedVoice: asked), baseURL: baseURL, apiKey: key)
        }
        if !lower.contains("realtime"), lower.contains("qwen"), lower.contains("tts") {
            return try await qwenTTS(text: text, model: id, voice: asked ?? "Cherry", baseURL: baseURL, apiKey: key)
        }
        throw Failure(message: String(format: AppLocalized("Model Studio does not synthesise speech with %@ here. Use cosyvoice-v3-flash or qwen3-tts-flash for text to speech."), id))
    }

    private static func cosyVoice(text: String, model: String, voice: String, baseURL: String, apiKey: String) async throws -> Data {
        let synth = NanoMuseDashScopeSynthesizer(
            endpoint: try NanoMuseDashScope.endpoint(forBase: baseURL),
            apiKey: apiKey, model: model, voice: voice, sampleRate: speechRate
        )
        let completion = NanoMuseBailianCompletion(Data())
        defer { synth.cancel() }
        let pcm: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard completion.install(continuation) else { return }
                synth.onAudio = { chunk in completion.update { $0.append(chunk) } }
                synth.onDone = { completion.complete() }
                synth.onFailure = { failure in completion.complete(failure: describe(failure)) }
                synth.start()
                synth.push(text)
                synth.finish()
            }
        } onCancel: {
            completion.complete(failure: CancellationError())
            synth.cancel()
        }
        try Task.checkCancellation()
        guard !pcm.isEmpty else { throw Failure(message: AppLocalized("Model Studio sent no audio.")) }
        return try wav(pcm16: pcm, rate: speechRate)
    }

    private static func qwenTTS(text: String, model: String, voice: String, baseURL: String, apiKey: String) async throws -> Data {
        var endpoint = try NanoMuseDashScope.origin(forBase: baseURL)
        endpoint.path = "/api/v1/services/aigc/multimodal-generation/generation"
        guard let url = endpoint.url else { throw invalidResponse() }
        var joined = Data()
        for piece in textPieces(text, maximumScalars: 600) {
            try Task.checkCancellation()
            let request = try jsonRequest(url: url, apiKey: apiKey, body: [
                "model": model, "input": ["text": piece, "voice": voice, "language_type": "Auto"],
            ])
            let (data, response) = try await execute(request)
            try check(response, data)
            let body = try decodeObject(from: data)
            try checkServerError(body)
            guard let audio = (body["output"] as? [String: Any])?["audio"] as? [String: Any] else {
                throw Failure(message: AppLocalized("Model Studio sent no audio."))
            }
            joined.append(try await qwenAudio(audio))
        }
        try Task.checkCancellation()
        guard !joined.isEmpty else { throw Failure(message: AppLocalized("Model Studio sent no audio.")) }
        return try wav(pcm16: joined, rate: speechRate)
    }

    private static func qwenAudio(_ audio: [String: Any]) async throws -> Data {
        if let link = audio["url"] as? String, !link.isEmpty {
            guard var components = URLComponents(string: link),
                  let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil else { throw invalidResponse() }
            // 官方示例可能返回HTTP存储链接，升级HTTPS以兼容iOS传输策略。
            components.scheme = "https"
            guard let url = components.url else { throw invalidResponse() }
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            // 下载地址不附带服务商Authorization，签名参数已包含在URL中。
            let (data, response) = try await execute(request)
            try check(response, data)
            return try pcm16Mono(fromWAV: data, rate: speechRate)
        }
        guard let encoded = audio["data"] as? String,
              let data = Data(base64Encoded: encoded), !data.isEmpty else {
            throw Failure(message: AppLocalized("Model Studio sent no audio."))
        }
        if data.starts(with: Array("RIFF".utf8)) { return try pcm16Mono(fromWAV: data, rate: speechRate) }
        // 原生API内联音频的协议格式为24kHz、16位小端单声道PCM。
        guard data.count.isMultiple(of: 2) else { throw invalidAudio() }
        return data
    }

    /// 按Unicode标量计数，避免表情和组合字符让请求越过服务端字符限制。
    static func textPieces(_ text: String, maximumScalars: Int) -> [String] {
        guard maximumScalars > 0 else { return [] }
        var pieces: [String] = []
        var piece = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            piece.append(scalar)
            if piece.count == maximumScalars { pieces.append(String(piece)); piece = .init() }
        }
        if !piece.isEmpty { pieces.append(String(piece)) }
        return pieces
    }

    private static func requiredKey(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure(message: AppLocalized("Add the Model Studio API key first.")) }
        return trimmed
    }

    private static func jsonRequest(url: URL, apiKey: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// URLSession可能以URLError.cancelled结束，统一还原为Swift任务取消。
    private static func execute(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        do {
            let result = try await session.data(for: request)
            try Task.checkCancellation()
            return result
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func decodeObject(from data: Data) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw invalidResponse()
        }
        return object
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw invalidResponse() }
        if http.statusCode == 401 || http.statusCode == 403 { throw describe(.refused(http.statusCode)) }
        guard (200..<300).contains(http.statusCode) else {
            if let body = try? decodeObject(from: data) { try checkServerError(body) }
            throw Failure(message: String(format: AppLocalized("Model Studio: %@"), "HTTP \(http.statusCode)"))
        }
    }

    /// 某些失败仍以HTTP200或SSE事件返回，不能把它们当作空的成功结果。
    static func checkServerError(_ body: [String: Any]) throws {
        let error = body["error"] as? [String: Any]
        let code = error?["code"] ?? body["code"]
        let message = error?["message"] as? String ?? body["message"] as? String
            ?? body["error"] as? String
        let status = body["status_code"] as? Int
        let codeText = code.map { String(describing: $0) } ?? ""
        let hasCode = !codeText.isEmpty && codeText != "0" && codeText != "200"
        guard error != nil || body["error"] is String || hasCode || status.map({ !(200..<300).contains($0) }) == true else { return }
        if status == 401 || status == 403 { throw describe(.refused(status ?? 401)) }
        let detail = [codeText, message ?? ""].filter { !$0.isEmpty }.joined(separator: ": ")
        throw Failure(message: String(format: AppLocalized("Model Studio: %@"), detail.isEmpty ? "HTTP \(status ?? 500)" : detail))
    }

    static func describe(_ failure: NanoMuseDashScope.Failure) -> Failure {
        switch failure {
        case .refused(let code):
            return Failure(message: String(format: AppLocalized("Model Studio refused the key (HTTP %d). Check the key, and that speech recognition and synthesis are turned on for it."), code))
        case .network(let reason):
            return Failure(message: String(format: AppLocalized("Could not reach Model Studio: %@"), reason))
        case .task(let message):
            return Failure(message: String(format: AppLocalized("Model Studio: %@"), message))
        }
    }

    private static func invalidResponse() -> Failure {
        Failure(message: AppLocalized("Model Studio sent an invalid voice response."))
    }

    private static func invalidAudio() -> Failure {
        Failure(message: AppLocalized("Model Studio needs a valid PCM16 WAV recording."))
    }

    /// 为完整的PCM16小端单声道采样添加WAV头，拒绝无效采样率或半个采样。
    static func wav(pcm16 pcm: Data, rate: Int) throws -> Data {
        guard (1...384000).contains(rate), pcm.count.isMultiple(of: 2),
              pcm.count <= Int(UInt32.max) - 36 else { throw invalidAudio() }
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16); append16(1); append16(1)
        append32(UInt32(rate)); append32(UInt32(rate * 2)); append16(2); append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    private struct PCMFormat {
        let rate: Int
        let channels: Int
        let alignment: Int
    }

    /// 将字节边界检查集中在读取器中，任何截断块都不能参与采样解码。
    private struct WAVReader {
        struct Chunk {
            let id: String
            let range: Range<Int>
            let nextOffset: Int
        }

        let bytes: [UInt8]
        let end: Int

        init?(_ data: Data) {
            let bytes = [UInt8](data)
            guard bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8),
                  Array(bytes[8..<12]) == Array("WAVE".utf8) else { return nil }
            let declared = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
            let isOpen = declared == 0 || declared == Int(UInt32.max)
            guard isOpen || (declared >= 4 && declared <= bytes.count - 8) else { return nil }
            self.bytes = bytes
            end = isOpen ? bytes.count : declared + 8
        }

        func read16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func read32(_ offset: Int) -> Int { read16(offset) | read16(offset + 2) << 16 }

        func chunk(at offset: Int) -> Chunk? {
            guard offset <= end - 8 else { return nil }
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let declared = read32(offset + 4), start = offset + 8
            let size = id == "data" && declared == Int(UInt32.max) ? end - start : declared
            let padding = size % 2
            guard size + padding <= end - start else { return nil }
            return Chunk(id: id, range: start..<start + size, nextOffset: start + size + padding)
        }

        func pcmFormat(in range: Range<Int>) -> PCMFormat? {
            let start = range.lowerBound
            guard range.count >= 16, read16(start) == 1, read16(start + 14) == 16 else { return nil }
            let channels = read16(start + 2), rate = read32(start + 4), alignment = read16(start + 12)
            guard (1...8).contains(channels), (1...384000).contains(rate),
                  alignment == channels * 2, read32(start + 8) == rate * alignment else { return nil }
            return PCMFormat(rate: rate, channels: channels, alignment: alignment)
        }
    }

    /// 严格校验PCM格式、块长度、字节率和帧对齐，保留原始声道交错顺序。
    static func parseWAV(_ data: Data) -> (pcm: Data, rate: Int, channels: Int)? {
        guard let reader = WAVReader(data) else { return nil }
        var offset = 12
        var format: PCMFormat?
        while let chunk = reader.chunk(at: offset) {
            switch chunk.id {
            case "fmt ":
                guard format == nil, let parsed = reader.pcmFormat(in: chunk.range) else { return nil }
                format = parsed
            case "data":
                guard let format, chunk.range.count.isMultiple(of: format.alignment) else { return nil }
                return (Data(reader.bytes[chunk.range]), format.rate, format.channels)
            default: break
            }
            offset = chunk.nextOffset
        }
        return nil
    }

    /// 把PCM16 WAV的所有声道取均值后线性重采样，未知容器不能当作裸PCM通过。
    static func pcm16Mono(fromWAV data: Data, rate: Int) throws -> Data {
        guard let parsed = parseWAV(data), (1...384000).contains(rate) else { throw invalidAudio() }
        let bytes = [UInt8](parsed.pcm)
        let frameCount = bytes.count / (parsed.channels * 2)
        guard frameCount > 0 else { return Data() }
        var mono = [Int16](repeating: 0, count: frameCount)
        for frame in 0..<frameCount {
            var sum = 0
            for channel in 0..<parsed.channels {
                let offset = (frame * parsed.channels + channel) * 2
                sum += Int(Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8))
            }
            mono[frame] = Int16(sum / parsed.channels)
        }
        let outputCount = frameCount * rate / parsed.rate
        guard outputCount <= 64 * 1024 * 1024 else { throw invalidAudio() }
        var output = Data(capacity: outputCount * 2)
        for index in 0..<outputCount {
            let position = Double(index) * Double(parsed.rate) / Double(rate)
            let left = min(Int(position), frameCount - 1), right = min(Int(position) + 1, frameCount - 1)
            let fraction = position - Double(Int(position))
            let sample = Int16(Double(mono[left]) * (1 - fraction) + Double(mono[right]) * fraction)
            let bits = UInt16(bitPattern: sample)
            output.append(UInt8(truncatingIfNeeded: bits))
            output.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return output
    }
}
