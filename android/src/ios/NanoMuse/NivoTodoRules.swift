import Foundation

/// 所有待办入口复用的值规则，避免AI和界面对完成状态采用不同口径。
enum NivoTodoRules {
    /// 与安卓LocalDate支持的界面年份范围一致。
    static func validateDay(_ day: Int64) throws {
        guard (-719_162...2_932_896).contains(day) else {
            throw NivoLifeError.invalidField("date")
        }
    }

    /// 标签按首次出现顺序去重，长度以UTF16计数以匹配安卓。
    static func tags(_ input: [String]) throws -> [String] {
        guard input.count <= 50 else { throw NivoLifeError.invalidField("tags") }
        var seen: Set<String> = []
        return try input.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.utf16.count <= 80 else { throw NivoLifeError.invalidField("tags") }
            return !normalized.isEmpty && seen.insert(normalized).inserted ? normalized : nil
        }
    }

    /// 分类精确区分大小写，拒绝多行名称。
    static func categoryName(_ text: String, kind: NivoTodoCategory.Kind) throws -> String {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let maximum = kind == .group ? 200 : 80
        guard !name.isEmpty, name.utf16.count <= maximum,
              !name.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
            throw NivoLifeError.invalidField("categoryName")
        }
        return name
    }

    /// 进入完成状态时冻结完成标签，重开时移除有效完成记录。
    static func update(
        _ input: NivoTodoTask, previous: NivoTodoTask?, owner: String,
        id: String, now: Int64, today: Int64
    ) throws -> NivoTodoTask {
        guard input.ownerKey == owner else { throw NivoLifeError.accountChanged }
        guard !id.isEmpty, !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.title.utf16.count <= 500 else { throw NivoLifeError.invalidField("title") }
        guard input.notes.utf16.count <= 100_000, input.groupName.utf16.count <= 200 else {
            throw NivoLifeError.invalidField("text")
        }
        try [input.scheduledDay, input.dueDay].compactMap { $0 }.forEach(validateDay)
        var task = input
        task.id = id
        task.title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.groupName = input.groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        task.tags = try tags(input.tags)
        guard (previous?.revision ?? 0) < Int64.max else { throw NivoLifeError.invalidField("revision") }
        task.revision = (previous?.revision ?? 0) + 1
        task.createdAt = previous?.createdAt ?? now
        // 更新时间用于版本排序，系统校时回拨不能生成无法再次载入的档案。
        // 完成报告仍记录实际墙钟时间，不用这个排序时间冒充完成时刻。
        task.updatedAt = max(now, previous?.updatedAt ?? now)
        task.deletedAt = previous?.deletedAt
        guard input.status == .done else {
            task.completedDay = nil
            task.completedAt = nil
            task.completionTags = []
            return task
        }
        if let previous, previous.status == .done {
            task.completedDay = previous.completedDay
            task.completedAt = previous.completedAt
            task.completionTags = previous.completionTags
            return task
        }
        let completedDay = input.completedDay ?? today
        try validateDay(completedDay)
        guard completedDay <= today else { throw NivoLifeError.invalidField("completedDay") }
        task.completedDay = completedDay
        task.completedAt = now
        task.completionTags = task.tags
        return task
    }

    /// 明确更正日历日期不产生第二次完成，完成时刻和标签快照保持原证据。
    static func correctCompletionDay(_ previous: NivoTodoTask, day: Int64, owner: String,
                                     now: Int64, today: Int64) throws -> NivoTodoTask {
        guard previous.ownerKey == owner else { throw NivoLifeError.accountChanged }
        guard previous.status == .done, previous.deletedAt == nil else {
            throw NivoLifeError.invalidTransition("completion_day")
        }
        try validateDay(day)
        guard day <= today else { throw NivoLifeError.invalidField("completedDay") }
        guard day != previous.completedDay else { return previous }
        guard previous.revision < Int64.max else { throw NivoLifeError.invalidField("revision") }
        var corrected = previous
        corrected.completedDay = day
        corrected.revision += 1
        corrected.updatedAt = max(now, previous.updatedAt)
        return corrected
    }

    /// 写入前比较实际版本，不能把调用者提供的旧版本覆盖为最新版本。
    static func requireRevision(_ expected: Int64, actual: Int64) throws {
        guard expected == actual else {
            throw NivoLifeError.staleRevision(expected: expected, actual: actual)
        }
    }

    /// 幂等标识限定为可跨平台传输的短标识。
    static func validateOperationID(_ value: String) throws {
        guard value.range(of: "^[A-Za-z0-9_.:-]{1,160}$", options: .regularExpression) != nil else {
            throw NivoLifeError.invalidField("operationId")
        }
    }
}

/// 只接受当前用户原话中的明确完成报告，避免模型替用户宣布任务完成。
enum NivoTodoCompletionEvidence {
    private static let sentenceBoundary = try! NSRegularExpression(pattern: "[。.!！?？\\n;；]")
    private static let completed = try! NSRegularExpression(pattern: "(?:完成|做完|写完|读完|看完|交完|提交|处理完|结束|办完|搞定)(?:了|啦|咯)?|(?:已经|已)(?:经)?(?:完成|提交|做完|写完|读完|看完|处理完|结束|办完)|\\b(?:completed|finished|done)\\b", options: [.caseInsensitive])
    private static let uncertain = try! NSRegularExpression(pattern: "没|未|不(?:是|能|算|要|会|想|确定)|是否|(?:计划|打算|准备|希望|争取|假如|如果|等到|等).*(?:完成|做完|写完|结束|done|finish)|(?:明天|下周|以后|将来|待会).*(?:完成|做完|写完)|\\b(?:not|never|haven't|hasn't|didn't|isn't|aren't|wasn't|weren't|will|would|should|could|might|if|when|plan|planning|intend|hope)\\b", options: [.caseInsensitive])

    static func isExplicitReport(userText: String, quote: String) -> Bool {
        guard !quote.isEmpty, userText.contains(quote), !quote.contains("?") && !quote.contains("？"),
              completed.firstMatch(in: quote, range: NSRange(quote.startIndex..., in: quote)) != nil else { return false }
        var searchStart = userText.startIndex
        while let range = userText.range(of: quote, range: searchStart..<userText.endIndex) {
            let beforeText = String(userText[..<range.lowerBound])
            let sentenceStart = beforeText.lastIndex(where: { "。.!！?？\n;；".contains($0) }).map { beforeText.index(after: $0) } ?? userText.startIndex
            let after = userText.rangeOfCharacter(from: CharacterSet(charactersIn: "。.!！?？\n;；"), range: range.upperBound..<userText.endIndex)?.lowerBound ?? userText.endIndex
            let sentence = String(userText[sentenceStart..<after])
            let ns = NSRange(sentence.startIndex..., in: sentence)
            let uncertainMatch = uncertain.firstMatch(in: sentence, range: ns) != nil
            let question = sentence.hasSuffix("吗") || sentence.hasSuffix("么") || sentence.contains("?") || sentence.contains("？")
            if !uncertainMatch && !question { return true }
            searchStart = range.upperBound
        }
        return false
    }
}
