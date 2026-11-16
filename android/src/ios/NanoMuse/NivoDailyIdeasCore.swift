import Foundation

/// 展示分类与目标分类分别建模，顺序沿用安卓每日点子。
enum NivoDailyIdeaCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case ideas, work, life, learn, family, media, more
    var id: String { rawValue }
}

/// 热点保留发布和核验时间，普通轮换素材不产生热点证明。
struct NivoDailyIdeaSource: Codable, Equatable, Sendable {
    var publisher: String
    var url: String
    var publishedAt: Date
    var verifiedAt: Date
}

/// 点子只提供待用户发送的文本，不自动执行任务。
struct NivoDailyIdea: Identifiable, Equatable, Sendable {
    var id: String
    var category: NivoDailyIdeaCategory
    var emoji: String
    var title: String
    var body: String
    var prompt: String
    var isHotTopic = false
    var source: NivoDailyIdeaSource?

    /// 只有完整且不超过48小时的HTTPS来源可以作为已核实热点。
    func hasVerifiedHotTopic(now: Date = Date()) -> Bool {
        guard isHotTopic, let source, !source.publisher.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: source.url), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil,
              source.verifiedAt >= source.publishedAt, source.verifiedAt <= now else { return false }
        let age = now.timeIntervalSince(source.publishedAt)
        return age >= 0 && age <= 48 * 60 * 60
    }
}

/// 相同分类既可表示完整素材池，也可表示某天选出的两条。
struct NivoDailyIdeaSection: Identifiable, Equatable, Sendable {
    var category: NivoDailyIdeaCategory
    var ideas: [NivoDailyIdea]
    var id: String { category.rawValue }
}

/// 每日版本以设备当地午夜标识，主聊天与完整页面共用结果。
struct NivoDailyIdeaEdition: Equatable, Sendable {
    var localDate: Date
    var sections: [NivoDailyIdeaSection]
}

/// 与界面和模型服务无关的素材解析、选取和日期规则。
enum NivoDailyIdeas {
    static let ideasPerDay = 2

    /// 应用和便携测试都读取自身Bundle内的正式资源，不依赖开发电脑的源码路径。
    static func resourceData(_ name: String) throws -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// 调用方传入真实目录，测试和应用使用同一条解析路径。
    static func parse(_ data: Data) throws -> [NivoDailyIdeaSection] {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = document["sections"] as? [[String: Any]] else {
            throw NivoDailyIdeaError.invalidCatalogue
        }
        var seen = Set<String>()
        var pools: [NivoDailyIdeaCategory: [NivoDailyIdea]] = [:]
        for section in sections {
            guard let identifier = section["id"] as? String,
                  let category = NivoDailyIdeaCategory(rawValue: identifier),
                  let values = section["ideas"] as? [Any] else { continue }
            let ideas = values.compactMap { parseIdea($0, category: category) }.filter { seen.insert($0.id).inserted }
            pools[category, default: []] += ideas
        }
        return NivoDailyIdeaCategory.allCases.compactMap { category in
            pools[category].map { NivoDailyIdeaSection(category: category, ideas: $0) }
        }
    }

    /// 同一日期与素材池产生固定版本，重启不会重新抽签。
    static func edition(sections: [NivoDailyIdeaSection], for date: Date, calendar: Calendar) -> NivoDailyIdeaEdition {
        let day = calendar.startOfDay(for: date)
        let selected = sections.sorted { $0.category.order < $1.category.order }.map { section in
            return NivoDailyIdeaSection(category: section.category,
                ideas: select(section.ideas, day: day, category: section.category, calendar: calendar))
        }
        return NivoDailyIdeaEdition(localDate: day, sections: selected)
    }

    /// 保持日内稳定的两条选取规则。
    static func select(_ pool: [NivoDailyIdea], day: Date, category: NivoDailyIdeaCategory,
                       calendar: Calendar = .current) -> [NivoDailyIdea] {
        guard !pool.isEmpty else { return [] }
        var seen = Set<String>()
        let unique = pool.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
        // 安卓LocalDate.toEpochDay以当地公历日期计数，不能拿1970年的当地时刻作日历差。
        let localSeconds = day.timeIntervalSince1970 + Double(calendar.timeZone.secondsFromGMT(for: day))
        let epoch = Int64(floor(localSeconds / 86_400))
        let count = Int64(unique.count)
        let offset = (epoch * Int64(ideasPerDay)) % count
        let start = Int((offset + count) % count)
        return (0..<min(ideasPerDay, unique.count)).map { unique[(start + $0) % unique.count] }
    }

    /// 前台最多一分钟重查设备日期，临近午夜缩短等待，夏令时使用实际日历边界。
    static func refreshDelay(now: Date, calendar: Calendar) -> TimeInterval {
        guard let next = calendar.dateInterval(of: .day, for: now)?.end else { return 60 }
        return min(60, max(0.001, next.timeIntervalSince(now)))
    }

    /// 从安卓同源模板生成待发送的核实请求，点击入口不进行联网或发布。
    static func hotTopicPrompt(for date: Date, language: String, calendar: Calendar) throws -> String {
        let templates = try JSONDecoder().decode([String: String].self, from: resourceData("daily-hot-topic"))
        guard let template = templates[catalogueLanguage(language)] else { throw NivoDailyIdeaError.invalidCatalogue }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return template.replacingOccurrences(of: "$date", with: formatter.string(from: date))
    }

    /// 素材保留安卓现有中英文策略，其他界面语言使用英文内容。
    static func catalogueLanguage(_ language: String) -> String {
        language.lowercased().hasPrefix("zh") ? "zh" : "en"
    }

    private static func parseIdea(_ value: Any, category: NivoDailyIdeaCategory) -> NivoDailyIdea? {
        guard let fields = value as? [String: Any], let identifier = fields["id"] as? String,
              let title = fields["title"] as? String, let body = fields["body"] as? String,
              let prompt = fields["prompt"] as? String else { return nil }
        return NivoDailyIdea(id: identifier, category: category, emoji: fields["emoji"] as? String ?? "💡",
            title: title, body: body, prompt: prompt, isHotTopic: fields["hot"] as? Bool ?? false,
            source: parseSource(fields["source"]))
    }

    private static func parseSource(_ value: Any?) -> NivoDailyIdeaSource? {
        guard let fields = value as? [String: Any], let publisher = fields["publisher"] as? String,
              let url = fields["url"] as? String, let published = fields["publishedAt"] as? String,
              let verified = fields["verifiedAt"] as? String,
              let publishedAt = instant(published), let verifiedAt = instant(verified) else { return nil }
        return NivoDailyIdeaSource(publisher: publisher, url: url, publishedAt: publishedAt, verifiedAt: verifiedAt)
    }

    private static func instant(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

/// 解码失败保留可重试错误，不用重复的占位点子冒充每日内容。
enum NivoDailyIdeaError: Error { case invalidCatalogue }

private extension NivoDailyIdeaCategory {
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// 成功目录按素材语言缓存，读取在actor上执行，失败不缓存以便重新加载。
actor NivoDailyIdeaCatalogue {
    static let shared = NivoDailyIdeaCatalogue()
    private var cached: [String: [NivoDailyIdeaSection]] = [:]

    /// 主聊天和完整页面共用同一份正式目录。
    func load(language: String) throws -> [NivoDailyIdeaSection] {
        let language = NivoDailyIdeas.catalogueLanguage(language)
        if let value = cached[language] { return value }
        let value = try NivoDailyIdeas.parse(NivoDailyIdeas.resourceData("daily-ideas." + language))
        guard value.contains(where: { !$0.ideas.isEmpty }) else { throw NivoDailyIdeaError.invalidCatalogue }
        cached[language] = value
        return value
    }
}
