import Foundation

/// 通话正文分句与回声过滤，不读取模型的思考或工具输出。
enum NanoMuseCallText {
    /// 过滤极短噪声和扬声器回声，保留与当前回复不同的插话。
    static func cutsIn(_ heard: String, spoken: String) -> Bool {
        let said = heard.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        guard said.filter({ $0.isLetter || $0.isNumber }).count >= 2 else { return false }
        let reply = spoken.lowercased()
        guard !reply.isEmpty else { return true }
        let hasHan = said.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        let characters = Array(said.filter { !$0.isWhitespace })
        let pieces = hasHan
            ? zip(characters, characters.dropFirst()).map { String([$0.0, $0.1]) }
            : said.split(whereSeparator: \.isWhitespace).map(String.init)
        return pieces.isEmpty || pieces.filter { reply.contains($0) }.count * 2 < pieces.count
    }

    /// 从累积正文中取出可朗读的短句，保留尚未结束的尾部。
    static func takeChunks(from buffer: inout String, flush: Bool = false) -> [String] {
        var chunks: [String] = []
        while let end = cutPoint(buffer, flush: flush) {
            let raw = String(buffer[..<end])
            buffer.removeSubrange(..<end)
            let clean = VoiceTextSanitizer.sanitize(raw)
            if !clean.isEmpty { chunks.append(clean) }
        }
        return chunks
    }

    private static func cutPoint(_ text: String, flush: Bool) -> String.Index? {
        guard !text.isEmpty else { return nil }
        for index in text.indices {
            let character = text[index]
            let next = text.index(after: index)
            if "，。！？；：、!?;\n".contains(character) { return next }
            if ".,:".contains(character), next < text.endIndex, text[next].isWhitespace { return next }
        }
        if flush { return text.endIndex }
        return text.count >= 24 ? text.index(text.startIndex, offsetBy: 24) : nil
    }
}
