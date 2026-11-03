//
//  NanoMuseFeed.swift
//  nanoMuse
//
//  The Coach tab (it began as Muse's feed, hence the names): training cards the agent writes for
//  the person, one ability at a time (NanoMuseGrowth.swift). One built-in routine sends "Write
//  today's training cards." into the coach's own conversation; the model answers with
//  ```nanomuse-feed``` blocks, which become `nanomuse/feed/YYYY-MM-DD/NN.md` files and cards.
//  Plain files on purpose: the agent can read them back and a backup carries them. The page
//  shows today; earlier days are in the training calendar (NanoMuseCoach.swift).
//  Android: feed/FeedPost.kt, feed/FeedStore.kt, feed/FeedFlow.kt, ui/feed/FeedTab.kt.
//

import Foundation
import SwiftUI

// MARK: - Post (pure parse/serialize, tested)

struct NanoMusePost: Identifiable, Equatable {
    var day: String
    var index: Int
    var title: String
    var type: String
    var emoji: String
    var body: String
    var source: [String]
    var createdAt: Date
    /// Kept in the files an older feed wrote; a training card is answered, not liked.
    var liked: Bool
    var file: URL
    /// A training card names the ability it trains, its level, the question to answer and the
    /// unit of the ability's course it belongs to, as the skill numbers it ("1.2 …").
    var track: String? = nil
    var level: Int = 0
    var prompt: String = ""
    var unit: String = ""

    var id: String { "\(day)/" + String(format: "%02d", index) }

    /// Every kind a block may name; the page shows the coach's kinds only (`coachTypes`).
    static let types: Set<String> = ["brief", "reminder", "idea", "goal", "memory", "note", "theory", "practice", "challenge", "review", "action", "weekly"]
    /// Training cards and the weekly report.
    static let coachTypes: Set<String> = ["theory", "practice", "challenge", "review", "action", "weekly"]

    /// The coach page shows training cards and the weekly report; posts an older feed wrote stay on disk, unshown.
    var onCoachPage: Bool { Self.coachTypes.contains(type) && (track != nil || type == "weekly") }

    static func typeLabel(_ type: String) -> String {
        switch type {
        case "theory": return AppLocalized("Theory")
        case "challenge": return AppLocalized("Level check")
        case "review": return AppLocalized("Review card")
        case "action": return AppLocalized("In real life")
        case "weekly": return AppLocalized("Weekly report")
        default: return AppLocalized("Scenario")
        }
    }

    static func defaultEmoji(_ type: String) -> String {
        switch type {
        case "theory": return "📖"
        case "challenge": return "🏆"
        case "review": return "🔁"
        case "action": return "🚶"
        case "weekly": return "📊"
        default: return "🏋️"
        }
    }

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: ";", with: "，").trimmingCharacters(in: .whitespaces)
    }

    private static func unescape(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") { t = String(t.dropFirst().dropLast()) }
        return t
    }

    func serialize() -> String {
        var s = "---\n"
        s += "title: \(Self.escape(title))\n"
        s += "type: \(type)\n"
        if !emoji.trimmingCharacters(in: .whitespaces).isEmpty { s += "emoji: \(emoji)\n" }
        if !source.isEmpty { s += "source: \(source.map(Self.escape).joined(separator: "; "))\n" }
        s += "created: \(Self.iso.string(from: createdAt))\n"
        if liked { s += "liked: true\n" }
        if let track { s += "track: \(track)\n" }
        if level > 0 { s += "level: \(level)\n" }
        if !prompt.trimmingCharacters(in: .whitespaces).isEmpty { s += "prompt: \(Self.escape(prompt))\n" }
        if !unit.trimmingCharacters(in: .whitespaces).isEmpty { s += "unit: \(Self.escape(unit))\n" }
        s += "---\n\n"
        s += body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        return s
    }

    /// Front matter + body → a post; nil when the name or the text are not a post.
    static func parse(text: String, day: String, index: Int, file: URL, modified: Date) -> NanoMusePost? {
        let (meta, body) = splitFrontMatter(text)
        let created = meta["created"].flatMap { iso.date(from: $0) } ?? modified
        var title = meta["title"].map(unescape) ?? ""
        if title.isEmpty {
            title = body.split(separator: "\n", omittingEmptySubsequences: true).first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? ""
        }
        let source = (meta["source"] ?? "").split(separator: ";").map { unescape(String($0)) }.filter { !$0.isEmpty }
        let type = (meta["type"] ?? "").isEmpty ? "note" : meta["type"]!
        let track = meta["track"].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let level = Int(meta["level"]?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        return NanoMusePost(day: day, index: index, title: title, type: type, emoji: meta["emoji"] ?? "", body: body.trimmingCharacters(in: .whitespacesAndNewlines), source: source, createdAt: created, liked: meta["liked"] == "true", file: file,
                            track: track, level: level, prompt: meta["prompt"].map(unescape) ?? "", unit: meta["unit"].map(unescape) ?? "")
    }

    static func splitFrontMatter(_ text: String) -> ([String: String], String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ([:], text) }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ([:], text) }
        var meta: [String: String] = [:]
        for line in lines[1..<end] {
            guard let i = line.firstIndex(of: ":"), i > line.startIndex else { continue }
            meta[String(line[..<i]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        }
        let body = lines.dropFirst(end + 1).joined(separator: "\n")
        return (meta, body)
    }

    /// What the model's `nanomuse-feed` block becomes before it is written. The parse keeps any
    /// kind; whether the block is a training card, and its ability, is the flow's call
    /// (`NanoMuseFeedFlow.coachDraft`).
    struct Draft: Equatable {
        var title: String
        var type: String
        var emoji: String
        var body: String
        var source: [String]
        var track: String? = nil
        var level: Int = 0
        var prompt: String = ""
        var unit: String = ""

        init?(block o: [String: Any]) {
            let title = (o["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (o["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !body.isEmpty else { return nil }
            let rawType = (o["type"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            var source: [String] = []
            if let arr = o["source"] as? [Any] {
                source = arr.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if let s = o["source"] as? String {
                source = s.split(whereSeparator: { $0 == ";" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            self.title = title
            self.body = body
            self.type = NanoMusePost.types.contains(rawType) ? rawType : "note"
            self.emoji = String((o["emoji"] as? String ?? "").trimmingCharacters(in: .whitespaces).prefix(4))
            self.source = Array(source.prefix(4))
        }
    }
}

// MARK: - Store

@MainActor
final class NanoMuseFeedStore: ObservableObject {
    static let shared = NanoMuseFeedStore()
    static let maxPostsPerDay = 12
    /// The calendar is the training record, so days are kept longer than the feed kept them (30).
    static let keepDays = 90
    /// File names are two digits, and a number is never handed out twice in a day (see `append`).
    static let maxIndex = 99

    /// The coach's cards only; newest day first, then by index.
    @Published private(set) var posts: [NanoMusePost] = []
    @Published private(set) var preferences: String = ""

    var root: URL { NanoMuseDirs.root.appendingPathComponent("feed", isDirectory: true) }
    var preferencesFile: URL { NanoMuseDirs.root.appendingPathComponent("feed-preferences.md") }

    private init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    /// The page coaches; the default sentence steers the training, not a news feed.
    static var defaultPreferences: String {
        AppLocalized("Train me from the ground up: basics first, classic books as the backbone, and plenty of things I can go and do in real life. Blunt reviews, with the next step.")
    }

    private static let dayName = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")
    private static let fileName = try! NSRegularExpression(pattern: "^(\\d{2})\\.md$")

    private static func isDay(_ name: String) -> Bool {
        dayName.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil
    }

    private static func index(of name: String) -> Int? {
        let ns = name as NSString
        guard let m = fileName.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    func reload() {
        let fm = FileManager.default
        let days = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter(Self.isDay).sorted(by: >)
        var all: [NanoMusePost] = []
        for day in days {
            let dir = root.appendingPathComponent(day, isDirectory: true)
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            var ofDay: [NanoMusePost] = []
            for name in files {
                guard let index = Self.index(of: name) else { continue }
                let url = dir.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
                if let post = NanoMusePost.parse(text: text, day: day, index: index, file: url, modified: modified), post.onCoachPage { ofDay.append(post) }
            }
            // A batch is written in one go and shares a `created` time: the newest batch first,
            // and inside a batch the model's order, most important first (#555).
            all.append(contentsOf: ofDay.sorted { a, b in
                a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.index < b.index
            })
        }
        posts = all
        let saved = ((try? String(contentsOf: preferencesFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        preferences = saved.isEmpty ? Self.defaultPreferences : saved
    }

    func savePreferences(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try? (t + "\n").write(to: preferencesFile, atomically: true, encoding: .utf8)
        preferences = t.isEmpty ? Self.defaultPreferences : t
    }

    func delete(_ post: NanoMusePost) {
        try? FileManager.default.removeItem(at: post.file)
        posts.removeAll { $0.file == post.file }
    }

    /// Writes a batch for today, continuing today's numbering. Returns what was written. A post's
    /// number is its id and answers are kept by id, so a number a deleted card used (still named
    /// in the growth record) is not handed out again; the day's limit counts the cards that are
    /// there, not the numbers used.
    @discardableResult
    func append(_ drafts: [NanoMusePost.Draft], now: Date = Date()) -> [NanoMusePost] {
        guard !drafts.isEmpty else { return [] }
        let day = NanoMuseDay.key(now)
        let dir = root.appendingPathComponent(day, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let present = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap(Self.index(of:))
        let answered = NanoMuseGrowthStore.shared.responses.keys.compactMap { id -> Int? in
            id.hasPrefix(day + "/") ? Int(id.dropFirst(day.count + 1)) : nil
        }
        var next = ((present + answered).max() ?? 0) + 1
        var room = Self.maxPostsPerDay - present.count
        var written: [NanoMusePost] = []
        for d in drafts {
            if room <= 0 || next > Self.maxIndex { break }
            let file = dir.appendingPathComponent(String(format: "%02d.md", next))
            let post = NanoMusePost(day: day, index: next, title: String(d.title.prefix(80)), type: d.type, emoji: d.emoji, body: d.body, source: d.source, createdAt: now, liked: false, file: file,
                                    track: d.track, level: d.level, prompt: d.prompt, unit: d.unit)
            do {
                try post.serialize().write(to: file, atomically: true, encoding: .utf8)
                written.append(post)
                next += 1
                room -= 1
            } catch {
                continue
            }
        }
        if !written.isEmpty {
            prune()
            reload()
        }
        return written
    }

    private func prune() {
        let fm = FileManager.default
        let days = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter(Self.isDay).sorted(by: >)
        for day in days.dropFirst(Self.keepDays) {
            try? fm.removeItem(at: root.appendingPathComponent(day))
        }
    }

    var latestDay: String? { posts.first?.day }
}

/// What the page shows about writing: a "Write them now" in progress, and why the last one wrote no card.
@MainActor
final class NanoMuseFeedStatus: ObservableObject {
    static let shared = NanoMuseFeedStatus()
    @Published var writing = false
    /// In the user's words; nil once a run wrote cards.
    @Published var failure: String?
    /// When the coach's conversation last wrote cards.
    var lastWrittenAt: Date?
}

// MARK: - Flow

@MainActor
enum NanoMuseFeedFlow {
    static let block = "feed"
    static let defaultHour = 8
    static let defaultMinute = 0

    private enum Keys {
        static let routine = "nanomuse.feed.routine"
        static let session = "nanomuse.feed.session"
        static let firstDay = "nanomuse.feed.first_day_written"
    }

    static var routineId: String? { UserDefaults.standard.string(forKey: Keys.routine) }
    static var sessionId: String? { UserDefaults.standard.string(forKey: Keys.session) }
    static var routine: NanoMuseRoutine? { routineId.flatMap { NanoMuseScheduler.shared.routine(id: $0) } }
    static func isFeedSession(_ id: String) -> Bool { !id.isEmpty && id == sessionId }

    static var hasModel: Bool {
        ProviderConfigStore.shared.defaultPrimaryGroupId != nil || !ProviderConfigStore.shared.modelEntries.isEmpty
    }

    /// The routine and its conversation exist. Needs a configured model for the conversation;
    /// until then it quietly does nothing and is retried whenever the Coach tab shows. A routine
    /// made by an older build asks for training cards from now on, its time and switch kept.
    @discardableResult
    static func ensureRoutine() async -> NanoMuseRoutine? {
        guard hasModel else { return nil }
        var sid = sessionId
        if let s = sid, !(await ChatStore.shared.sessionExists(id: s)) { sid = nil }
        if sid == nil {
            let vm = ViewModelCache.shared.createDraft()
            vm.sessionSource = "nanomuse-feed"
            let created = await vm.ensureSessionReturningId()
            await ChatStore.shared.updateSessionTitle(created, title: AppLocalized("Coach"))
            ViewModelCache.shared.cacheDraft(vm, sessionId: created)
            UserDefaults.standard.set(created, forKey: Keys.session)
            sid = created
        }
        let scheduler = NanoMuseScheduler.shared
        let prompt = AppLocalized("Write today's training cards.")
        let label = AppLocalized("Write the training cards")
        if var existing = routine {
            if existing.sessionId != sid || existing.prompt != prompt || existing.label != label {
                existing.sessionId = sid
                existing.prompt = prompt
                existing.label = label
                scheduler.update(existing)
            }
            return existing
        }
        var r = NanoMuseRoutine(label: label, prompt: prompt, hour: defaultHour, minute: defaultMinute)
        r.sessionId = sid
        r.hidden = true
        scheduler.create(r)
        UserDefaults.standard.set(r.id, forKey: Keys.routine)
        return r
    }

    /// The routine runs, or "Write them now" is getting it ready.
    static var generating: Bool {
        NanoMuseFeedStatus.shared.writing || NanoMuseScheduler.shared.running.contains(routineId ?? "")
    }

    /// "Write them now".
    static func generateNow() { writeNow(trigger: "feed-now") {} }

    /// C5: the first day's cards, written on their own right after the first conversation ends
    /// (the agent has its name) when a model is there and an ability is in training. Once per
    /// phone, counted when the run is dispatched; a background run in the coach's own
    /// conversation, so it is never counted as a task.
    static func writeFirstDayIfNeeded() {
        guard hasModel, !UserDefaults.standard.bool(forKey: Keys.firstDay), NanoMuseFeedStore.shared.posts.isEmpty, !generating,
              !NanoMuseGrowthFlow.plan(NanoMuseFeedStore.shared.posts).isEmpty else { return }
        writeNow(trigger: "feed-first-day") { UserDefaults.standard.set(true, forKey: Keys.firstDay) }
    }

    /// One run of the routine; a run that writes no card says why on the page instead of ending in silence.
    private static func writeNow(trigger: String, onDispatch: @escaping () -> Void) {
        guard !generating else { return }
        let status = NanoMuseFeedStatus.shared
        status.writing = true
        status.failure = nil
        Task { @MainActor in
            defer { status.writing = false }
            @MainActor func fail(_ why: String) { status.failure = String(format: AppLocalized("No cards were written: %@"), why) }
            guard !NanoMuseGrowthFlow.plan(NanoMuseFeedStore.shared.posts).isEmpty else { return fail(AppLocalized("nothing is in training.")) }
            guard let r = await ensureRoutine() else { return fail(AppLocalized("add a model first.")) }
            guard NanoMuseGrowthFlow.grading.isEmpty else { return fail(AppLocalized("the coach is still reviewing an answer. Try again in a moment.")) }
            onDispatch()
            let started = Date()
            let ok = await NanoMuseScheduler.shared.run(r.id, trigger: trigger)
            if let at = status.lastWrittenAt, at >= started { return }
            if ok {
                fail(AppLocalized("the reply held no training cards. Try again."))
            } else {
                // The model's own error says the most; the run record keeps it.
                let note = (routine?.runs.first?.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                fail(String(format: AppLocalized("the model request failed (%@)."), note.isEmpty ? "-" : String(note.prefix(120))))
            }
        }
    }

    static func setEnabled(_ on: Bool) {
        guard let id = routineId else { return }
        NanoMuseScheduler.shared.setEnabled(id, on)
    }

    static func setTime(hour: Int, minute: Int) {
        guard var r = routine else { return }
        r.hour = hour
        r.minute = minute
        NanoMuseScheduler.shared.update(r)
        NanoMuseScheduler.shared.refreshNotifications()
    }

    /// After every finished turn: reviews and the growth memory from the coach's own conversation,
    /// then `nanomuse-feed` blocks that are training cards become posts.
    static func afterTurn(session: String, assistantText: String?) {
        guard let text = assistantText, !text.isEmpty else { return }
        if isFeedSession(session) { NanoMuseGrowthFlow.afterTurn(text) }
        guard NanoMuseFences.contains(text, kind: block) else { return }
        let store = NanoMuseFeedStore.shared
        let today = store.posts.filter { $0.day == NanoMuseDay.key() }
        let drafts = NanoMuseFences.objects(block, in: text)
            .compactMap(coachDraft)
            .filter { d in !today.contains { $0.title.lowercased() == String(d.title.prefix(80)).lowercased() } }
        guard !drafts.isEmpty else { return }
        let written = store.append(drafts)
        NanoMuseGrowthStore.shared.cardsWritten(written) // the ability's review clock restarts
        if !written.isEmpty, isFeedSession(session) {
            NanoMuseFeedStatus.shared.lastWrittenAt = Date()
            NanoMuseFeedStatus.shared.failure = nil
        }
    }

    private static func trackOf(_ o: [String: Any]) -> NanoMuseGrowthTrack? {
        let id = (o["track"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return NanoMuseGrowthStore.shared.state.tracks.first { $0.id == id }
    }

    private static func typeOf(_ o: [String: Any]) -> String {
        let t = (o["type"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return NanoMusePost.coachTypes.contains(t) ? t : "practice"
    }

    /// Whether a `nanomuse-feed` block becomes a card. A card counts only for an ability the growth
    /// record knows; apart from the weekly report, a post without one (news, a paper digest, any
    /// general post) is dropped. The chat shows "Added to Coach" only for what passes.
    static func isCoachCard(_ o: [String: Any]) -> Bool { trackOf(o) != nil || typeOf(o) == "weekly" }

    /// A block as a training card: its kind, ability, level, question and unit; nil when it is not one.
    static func coachDraft(_ o: [String: Any]) -> NanoMusePost.Draft? {
        guard var d = NanoMusePost.Draft(block: o), isCoachCard(o) else { return nil }
        d.type = typeOf(o)
        if let track = trackOf(o) {
            let level = (o["level"] as? NSNumber)?.intValue ?? Int(o["level"] as? String ?? "") ?? track.level
            d.track = track.id
            d.level = min(max(level, 1), 5)
            d.prompt = String((o["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            d.unit = String((o["unit"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        }
        return d
    }

    /// Appended to the system prompt of the coach's conversation (nil elsewhere).
    static func systemAddendum(session: String) -> String? {
        guard isFeedSession(session) else { return nil }
        let store = NanoMuseFeedStore.shared
        let recent = store.posts.prefix(24).map(\.title)
        var s = "## This conversation writes the user's training cards (Nicholasx)\n"
        s += "The Coach tab shows the training cards you write: today's on the page, earlier days in its calendar. The user's standing instruction for it (it steers what the cards draw on and stress, never what kind of card you write):\n"
        s += "> " + store.preferences.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n"
        s += "What you know about them right now (from GLOBAL.md, the diary of the last seven days, USER.md and their goals):\n"
        let d = digest()
        s += (d.isEmpty ? "(nothing recorded yet: start at the lowest level and ask about their life in the first cards)" : d) + "\n\n"
        // The page trains abilities; the plan, the skills, the answers and the formats come from the growth record.
        s += NanoMuseGrowthFlow.section(store.posts) + "\n"
        s += "Write in the user's language; be concrete; no clickbait, no filler, nothing you already posted. "
        s += "Use tools only when a card needs a live fact or one of the user's notes, at most three quick calls.\n"
        if !recent.isEmpty { s += "Recent titles (do not repeat): \(recent.joined(separator: " · "))\n" }
        s += "In ordinary conversation here, answer normally; add a `nanomuse-feed` block only when the user asks for a training card."
        return s
    }

    /// Bounded digest of the agent's memory and the person's goals.
    private static func digest() -> String {
        var sb = ""
        func add(_ label: String, _ url: URL, limit: Int) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            sb += "### \(label)\n" + (t.count > limit ? String(t.prefix(limit)) + " …" : t) + "\n"
        }
        let memory = NanoMuseDirs.memory
        add("USER.md", memory.appendingPathComponent("USER.md"), limit: 1500)
        add("GLOBAL.md", memory.appendingPathComponent("GLOBAL.md"), limit: 2500)
        for i in 0..<7 {
            guard let date = Calendar.current.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let name = NanoMuseDay.key(date) + ".md"
            add("Diary \(name)", memory.appendingPathComponent(name), limit: i == 0 ? 1500 : 600)
        }
        let goals = NanoMuseGoalStore.shared.goals
        if !goals.isEmpty {
            sb += "### Goals\n"
            for g in goals {
                sb += "- \(g.title): \(g.status.rawValue), \(g.progress)%" + (g.lastNote.map { "; last: \($0)" } ?? "") + "\n"
            }
        }
        return String(sb.prefix(7000))
    }

    /// What Discuss sends: on a training card the ability, the question, the answer and its
    /// review (NanoMuseGrowthFlow); on the weekly report the post itself.
    static func discussOpener(_ post: NanoMusePost) -> String {
        if post.track != nil { return NanoMuseGrowthFlow.discussOpener(post) }
        return String(format: AppLocalized("Let's talk about this one from my Coach page:\n\n**%@**\n\n%@"), post.title, String(post.body.prefix(1200)))
    }
}

// MARK: - Coach room

/// The Coach tab. A grey canvas, the ability in training, today's recall, then today's training
/// cards under a "Today · Monday · 2 Nov 2026" heading: white cards with an icon tile, a title, a
/// few lines, the question with its answer and review, and a footer of discuss · info. Earlier
/// days are in the training calendar; when no card was written today, one card says when they
/// come and writes them on a tap, and a run that wrote none says why.
struct NanoMuseFeedRoom: View {
    var chrome: NanoMuseRoomChrome
    var onDiscuss: (NanoMusePost) -> Void
    /// A chat of its own with this first message (building an ability's course).
    var onChat: (_ title: String, _ opener: String) -> Void

    @ObservedObject private var store = NanoMuseFeedStore.shared
    @ObservedObject private var scheduler = NanoMuseScheduler.shared
    @ObservedObject private var growth = NanoMuseGrowthStore.shared
    @ObservedObject private var status = NanoMuseFeedStatus.shared
    @State private var sheet: Sheet?
    @State private var calendarDay: String?
    @State private var detail: NanoMusePost?

    private enum Sheet: String, Identifiable {
        case settings, calendar, growth
        var id: String { rawValue }
    }

    var body: some View {
        let today = NanoMuseDay.key()
        let todayPosts = store.posts.filter { $0.day == today }
        let earlierOpen = store.posts.filter { $0.day != today && $0.track != nil && !$0.prompt.isEmpty && growth.responses[$0.id] == nil }
        let nothingPlanned = NanoMuseGrowthFlow.plan(store.posts).isEmpty
        VStack(spacing: 0) {
            // Android: the calendar left of the sliders where the other rooms have •••.
            NanoMuseRoomHeader(chrome: chrome) {
                HStack(spacing: 8) {
                    NanoMuseRoundButton(symbol: "calendar", label: AppLocalized("Training calendar")) {
                        calendarDay = nil
                        sheet = .calendar
                    }
                    NanoMuseRoundButton(symbol: "slider.horizontal.3", label: AppLocalized("Training settings")) { sheet = .settings }
                }
            }
            ScrollView {
                // A plain stack: a day holds a dozen cards at most, and an answer being typed keeps its text.
                VStack(alignment: .leading, spacing: 12) {
                    NanoMuseGrowthCard(today: todayPosts) { sheet = .growth }
                    NanoMuseRecallCard()
                    NanoMuseCoachDayTitle(day: today)
                    if let first = earlierOpen.first {
                        Button {
                            calendarDay = first.day
                            sheet = .calendar
                        } label: {
                            Text(String(format: earlierOpen.count == 1 ? AppLocalized("%d card from an earlier day still waits for your answer. Open the calendar") : AppLocalized("%d cards from earlier days still wait for your answer. Open the calendar"), earlierOpen.count))
                                .font(.footnote)
                                .foregroundStyle(NanoMuseTones.action)
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    if NanoMuseFeedFlow.generating {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small).tint(NanoMuseTones.action)
                            Text(AppLocalized("Writing today's cards…")).font(.subheadline)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else if todayPosts.isEmpty || (status.failure != nil && !nothingPlanned) {
                        writeCard(empty: todayPosts.isEmpty, nothingPlanned: nothingPlanned)
                    }
                    // The model leads with what matters most.
                    ForEach(todayPosts) { post in
                        NanoMusePostCard(post: post, onDiscuss: { onDiscuss(post) }, onInfo: { detail = post })
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .refreshable {
                store.reload()
                growth.reload()
            }
        }
        .background(NanoMuseTones.canvas.ignoresSafeArea())
        .onAppear {
            store.reload()
            Task { @MainActor in await NanoMuseFeedFlow.ensureRoutine() }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .settings: NanoMuseFeedSettingsSheet()
            case .calendar: NanoMuseCoachCalendarSheet(initialDay: calendarDay ?? today, onDiscuss: onDiscuss)
            case .growth: NanoMuseGrowthSheet(onChat: onChat)
            }
        }
        .sheet(item: $detail) { post in NanoMusePostDetail(post: post) }
    }

    /// With no card today, when they come and a button to write them now (or, with nothing in
    /// training, where to pick an ability); after a run that wrote no card, why, with the button.
    private func writeCard(empty: Bool, nothingPlanned: Bool) -> some View {
        let time = NanoMuseDay.clock(hour: NanoMuseFeedFlow.routine?.hour ?? NanoMuseFeedFlow.defaultHour, minute: NanoMuseFeedFlow.routine?.minute ?? NanoMuseFeedFlow.defaultMinute)
        return VStack(alignment: .leading, spacing: 0) {
            if empty {
                Text(AppLocalized("No training cards today yet")).font(.body.weight(.semibold))
                Text(nothingPlanned ? AppLocalized("Nothing is in training, so there are no cards to write. Tap the card above and pick an ability.") : String(format: AppLocalized("They are written every day at %@. You can also write them now."), time))
                    .font(.subheadline)
                    .foregroundStyle(Color.primary.opacity(0.86))
                    .padding(.top, 4)
            }
            if let failure = status.failure, !nothingPlanned {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.top, empty ? 8 : 0)
            }
            if !nothingPlanned {
                Button { NanoMuseFeedFlow.generateNow() } label: {
                    Text(AppLocalized("Write them now"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(NanoMuseTones.action, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// One card on the page and in the calendar: an icon tile, the ability it trains, the title and
/// the body, then the question with the answer box or the answer and its review, then discuss · info.
struct NanoMusePostCard: View {
    var post: NanoMusePost
    var onDiscuss: () -> Void
    var onInfo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(post.emoji.isEmpty ? NanoMusePost.defaultEmoji(post.type) : post.emoji)
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
                    .background(NanoMuseTones.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    NanoMuseGrowthTag(post: post)
                    Text(post.title).font(.body.weight(.semibold))
                    NanoMuseInlineMarkdown(text: post.body)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.86))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            NanoMuseGrowthAnswer(post: post)
            // No heart: a training card is answered, not liked.
            HStack(spacing: 0) {
                Button(action: onDiscuss) {
                    Label(AppLocalized("Discuss"), systemImage: "bubble.left")
                        .font(.subheadline)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                Spacer(minLength: 0)
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(AppLocalized("Post details")))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .padding(.top, 6)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Bold, italics, links and bullets in a card's body; the Markdown of a card is small on purpose.
struct NanoMuseInlineMarkdown: View {
    var text: String
    var body: some View {
        let shown = text.components(separatedBy: "\n").map(Self.line).joined(separator: "\n")
        if let attributed = try? AttributedString(markdown: shown, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
        } else {
            Text(text)
        }
    }

    /// A list item gets a bullet and a heading turns bold; inline syntax leaves both as typed.
    private static func line(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- ") || t.hasPrefix("* ") { return "• " + t.dropFirst(2) }
        if t.hasPrefix("#") {
            let heading = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return heading.isEmpty ? "" : "**\(heading)**"
        }
        return s
    }
}

/// The ⓘ of a card: its kind, when it was written, where it came from, its file, and removing it.
struct NanoMusePostDetail: View {
    var post: NanoMusePost
    @Environment(\.dismiss) private var dismiss

    private static let written: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(post.title).font(.title3.weight(.semibold))
                    // A grid sizes the label column to the longest label instead of a fixed width.
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                        row(AppLocalized("Type"), NanoMusePost.typeLabel(post.type))
                        // A 24-hour time, not "3:05 PM".
                        row(AppLocalized("Written"), Self.written.string(from: post.createdAt))
                        if !post.source.isEmpty { row(AppLocalized("From"), post.source.joined(separator: "\n")) }
                        row(AppLocalized("File"), "nanomuse/feed/\(post.id).md")
                    }
                    .font(.footnote)
                    Button(role: .destructive) {
                        NanoMuseFeedStore.shared.delete(post)
                        dismiss()
                    } label: {
                        Label(AppLocalized("Remove this post"), systemImage: "trash")
                    }
                    .padding(.top, 4)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The training settings behind the header's sliders: the skill each ability is trained with,
/// the knowledge the cards are made from, then the steering sentence, the routine's switch and
/// time, and "Write them now".
struct NanoMuseFeedSettingsSheet: View {
    @ObservedObject private var store = NanoMuseFeedStore.shared
    @ObservedObject private var scheduler = NanoMuseScheduler.shared
    @ObservedObject private var growth = NanoMuseGrowthStore.shared
    @ObservedObject private var skills = SkillStore.shared
    @ObservedObject private var status = NanoMuseFeedStatus.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var time = Date()
    @State private var knowledge: NanoMuseGrowthSources.Snapshot?

    private var routine: NanoMuseRoutine? { NanoMuseFeedFlow.routine }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(AppLocalized("How the cards are made: the skill behind each ability and the knowledge the agent reads. The steering sentence and the daily time come last."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                skillsSection
                knowledgeSection
                Section {
                    TextEditor(text: $text).frame(minHeight: 120)
                } header: {
                    Text(AppLocalized("Steering sentence"))
                } footer: {
                    Text(AppLocalized("Steers what the training cards draw on and stress. This page writes training cards only; papers, news and anything else you want each day go in a scheduled task."))
                }
                routineSection
            }
            .navigationTitle(AppLocalized("Training settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Save")) {
                        store.savePreferences(text)
                        dismiss()
                    }
                }
            }
            .onAppear {
                text = store.preferences
                var c = DateComponents()
                c.hour = routine?.hour ?? NanoMuseFeedFlow.defaultHour
                c.minute = routine?.minute ?? NanoMuseFeedFlow.defaultMinute
                time = Calendar.current.date(from: c) ?? Date()
                knowledge = NanoMuseGrowthSources.snapshot()
            }
        }
    }

    /// Each ability with the skill that trains it; a tap opens the skill.
    private var skillsSection: some View {
        Section {
            ForEach(growth.state.tracks) { t in
                if let skill = skills.skills.first(where: { $0.id == t.skill }) {
                    NavigationLink { NanoMuseSkillDetailLink(skillId: skill.id) } label: { skillRow(t, description: skill.description, installed: true) }
                } else {
                    skillRow(t, description: "", installed: false)
                }
            }
            NavigationLink { SkillsManagementView() } label: {
                Text(String(format: AppLocalized("All skills, %d installed"), skills.skills.count)).foregroundStyle(NanoMuseTones.action)
            }
        } header: {
            Text(AppLocalized("Abilities and their skills"))
        } footer: {
            Text(AppLocalized("Each ability is trained by a skill: its books, its units level by level, how its cards are made and its rubric. Tap one to read or edit it; a change counts from the next card."))
        }
    }

    private func skillRow(_ t: NanoMuseGrowthTrack, description: String, installed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(t.displayTitle)
                Spacer(minLength: 8)
                Text(NanoMuseCoachText.status(t))
                    .font(.caption)
                    .foregroundStyle(t.status == NanoMuseGrowthStore.focus ? NanoMuseTones.action : Color.secondary)
            }
            Text(installed ? [t.skill, description].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " · ")
                 : String(format: AppLocalized("Skill %@ is missing, so this ability is trained with general practice"), t.skill))
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(installed ? Color.secondary : Color.red)
            // How far the course behind the ability has come.
            Text(String(format: AppLocalized("%d book cards · framework %d characters"), growth.bookCards(t.skill).count, growth.framework(t.skill).count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// What the cards are made from, counted.
    private var knowledgeSection: some View {
        Section {
            if let k = knowledge {
                let empty = AppLocalized("empty")
                LabeledContent(AppLocalized("About you (USER.md)"), value: k.userChars > 0 ? String(format: AppLocalized("%d characters"), k.userChars) : empty)
                LabeledContent(AppLocalized("Long-term memory (GLOBAL.md)"), value: k.globalChars > 0 ? String(format: AppLocalized("%d characters"), k.globalChars) : empty)
                LabeledContent(AppLocalized("Daily memory, last 7 days"), value: String(format: AppLocalized("%d of 7 days"), k.diaryDays))
                LabeledContent(AppLocalized("Active goals"), value: "\(k.activeGoals)")
                LabeledContent(AppLocalized("Growth record"), value: String(format: AppLocalized("%d answers, %d reviewed · %d to recall, %d due today · %d principles · %d observations"),
                                                                             k.answers, k.graded, k.recall, k.recallDue, k.principles, k.observations))
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalized("Mounted folders"))
                    if k.folders.isEmpty {
                        Text(AppLocalized("None yet. Mount a notes folder, an Obsidian vault for example, and the cards can draw on your notes."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(k.folders, id: \.linuxPath) { f in
                            Text("\(f.name) · \(f.linuxPath)" + (f.available ? "" : " · " + AppLocalized("not reachable")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink { MountedFoldersSettingsView() } label: {
                    Text(AppLocalized("Mount a folder")).foregroundStyle(NanoMuseTones.action)
                }
            }
        } header: {
            Text(AppLocalized("Knowledge the cards draw on"))
        } footer: {
            Text(AppLocalized("Read when the cards are written. Mounted folders are named to the agent, and it opens a note there when a card needs one."))
        }
    }

    private var routineSection: some View {
        Section {
            if let r = routine {
                Toggle(AppLocalized("Write it every day"), isOn: Binding(get: { r.enabled }, set: { NanoMuseFeedFlow.setEnabled($0) }))
                    .tint(NanoMuseTones.action)
                DatePicker(AppLocalized("Time"), selection: $time, displayedComponents: .hourAndMinute)
                    .nmOnChange(of: time) { t in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: t)
                        NanoMuseFeedFlow.setTime(hour: c.hour ?? NanoMuseFeedFlow.defaultHour, minute: c.minute ?? 0)
                    }
                if let last = r.runs.first {
                    Text(String(format: last.ok ? AppLocalized("last run %@") : AppLocalized("last run %@, failed"), NanoMuseDay.relative(last.at)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text(AppLocalized("Add a model first.")).font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                NanoMuseFeedFlow.generateNow()
                dismiss()
            } label: {
                if NanoMuseFeedFlow.generating {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(AppLocalized("Writing today's cards…")) }
                } else {
                    Text(AppLocalized("Write them now"))
                }
            }
            .disabled(NanoMuseFeedFlow.generating)
        } header: {
            Text(AppLocalized("Routine"))
        } footer: {
            Text(AppLocalized("On the iPhone the cards are written when the app is open; at the set time the phone reminds you to open it. Nothing runs while the app is asleep."))
        }
    }
}

/// A persisted `nanomuse-feed` fence in the chat: "Added to Coach", for a block that became a card.
struct NanoMuseFeedFenceCard: View {
    var object: [String: Any]
    var body: some View {
        if NanoMuseFeedFlow.isCoachCard(object) {
            let title = object["title"] as? String ?? ""
            let emoji = (object["emoji"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NanoMusePost.defaultEmoji(object["type"] as? String ?? "practice")
            HStack(spacing: 10) {
                Text(emoji)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalized("Added to Coach")).font(.caption).foregroundStyle(.secondary)
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(AppLocalized("Open")) { NotificationCenter.default.post(name: .nanoMuseOpenRoom, object: "feed") }
                    .font(.footnote.weight(.medium))
                    .tint(NanoMuseTones.action)
            }
            .padding(12)
            .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

extension Notification.Name {
    /// Switch the Muse shell to a room: object is "feed" | "goals" | "ideas" | "library".
    static let nanoMuseOpenRoom = Notification.Name("nanoMuse.openRoom")
}
