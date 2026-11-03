//
//  NanoMuseGrowth.swift
//  nanoMuse
//
//  The growth record behind the Coach tab: which abilities are trained in what order, how far
//  each has come, every answer with its review, the points to recall, and two files the coach
//  keeps about the person (MEMORY.md, how they learn; PRINCIPLES.md, the principles they took
//  up). Plain files under nanomuse/growth/, in the same shape as on Android, so a backup and
//  the agent's shell read them the same way.
//
//  Levels follow mastery learning: six reviewed answers to scenario and real-life cards at the
//  current level (theory cards are reviewed and recalled but do not count), averaging 3 of 4 or
//  better over at least four days, unlock a level check; 3 or more on it raises the level, less
//  sends the ability back for a few more answers. An ability kept up after its goal drops one
//  level when its last three reviews average under 1.5.
//  Android: growth/GrowthStore.kt.
//

import Foundation

struct NanoMuseGrowthTrack: Equatable, Identifiable {
    var id: String
    /// Nil for a built-in ability, whose title is localized.
    var title: String?
    /// What a user-added ability is for, in their words.
    var about: String?
    /// The skill that holds the course: books, units by level, card kinds, rubric.
    var skill: String
    var status: String
    var level: Int
    /// Reviewed answers of the current level, oldest first, and the day of each.
    var scores: [Int]
    var scoreDays: [String]
    var lastCardAt: Date?
    var reachedAt: Date?
    /// The practice record qualifies: a level check decides the next level.
    var challenge: Bool = false

    /// The English titles; the shown ones are under the keys "growth.track.<id>", since "English"
    /// alone is the language's name elsewhere in the app.
    static let builtIn: [(id: String, title: String)] = [
        ("principles", "Principles and judgement"),
        ("lenses", "Seeing from several angles"),
        ("english", "English"),
        ("expression", "Expression"),
        ("leadership", "Leadership"),
        ("habits", "Habits and execution"),
    ]

    var displayTitle: String {
        if let title { return title }
        return Self.builtIn.contains { $0.id == id } ? AppLocalized("growth.track.\(id)") : id
    }
}

struct NanoMuseGrowthResponse: Equatable {
    var post: String
    var track: String
    var level: Int
    var prompt: String
    var answer: String
    var answeredAt: Date
    var score: Int?
    var feedback: String?
    var gradedAt: Date?
    /// theory, practice, challenge, review or action.
    var kind: String = "practice"
    /// too_easy, ok or too_hard.
    var difficulty: String?
    /// The course unit, as the skill numbers it.
    var unit: String = ""
}

struct NanoMuseRecallItem: Equatable, Identifiable {
    var id: String
    var track: String
    var question: String
    var answer: String
    var due: Date
    var intervalDays: Int
    var reps: Int
    var lapses: Int
}

struct NanoMuseGrowthState: Equatable {
    var target: Int
    var tracks: [NanoMuseGrowthTrack]
    var offered: Set<String>

    var focus: NanoMuseGrowthTrack? { tracks.first { $0.status == NanoMuseGrowthStore.focus } }

    /// The ability in training reached the goal and the person has not been asked at this level yet.
    var promotion: NanoMuseGrowthTrack? {
        guard let f = focus, f.level >= target, !offered.contains("\(f.id):\(f.level)") else { return nil }
        return f
    }

    func next() -> NanoMuseGrowthTrack? { tracks.first { $0.status == NanoMuseGrowthStore.queued } }
}

@MainActor
final class NanoMuseGrowthStore: ObservableObject {
    static let shared = NanoMuseGrowthStore()

    static let focus = "focus"
    static let queued = "queued"
    static let maintain = "maintain"
    static let paused = "paused"
    static let maxLevel = 5
    static let window = 6
    static let recallPerDay = 5
    static let generalSkill = "growth-general"
    private static let passMean = 3.0
    private static let minDays = 4
    private static let dropWindow = 3
    private static let dropMean = 1.5
    private static let keepResponses = 500
    private static let keepObservations = 40
    private static let keepRecall = 300
    private static let maxFramework = 6000
    private static let day: TimeInterval = 24 * 60 * 60

    @Published private(set) var state = NanoMuseGrowthState(target: 3, tracks: [], offered: [])
    /// Latest record per card id.
    @Published private(set) var responses: [String: NanoMuseGrowthResponse] = [:]
    @Published private(set) var recall: [NanoMuseRecallItem] = []

    var dir: URL { NanoMuseDirs.root.appendingPathComponent("growth", isDirectory: true) }
    var memoryFile: URL { dir.appendingPathComponent("MEMORY.md") }
    var principlesFile: URL { dir.appendingPathComponent("PRINCIPLES.md") }
    private var observationsFile: URL { dir.appendingPathComponent("observations.md") }
    private var stateFile: URL { dir.appendingPathComponent("state.json") }
    private var responsesFile: URL { dir.appendingPathComponent("responses.jsonl") }
    private var recallFile: URL { dir.appendingPathComponent("recall.json") }

    private init() { reload() }

    func reload() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: stateFile), let parsed = Self.parseState(data) {
            state = parsed
        } else {
            state = Self.defaults()
            writeState(state)
        }
        responses = readResponses()
        recall = readRecall()
    }

    func read(_ url: URL) -> String {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Answers and reviews

    func recordAnswer(_ post: NanoMusePost, answer: String) {
        guard let track = post.track else { return }
        save(NanoMuseGrowthResponse(post: post.id, track: track, level: post.level, prompt: post.prompt, answer: answer,
                                    answeredAt: Date(), kind: post.type, unit: post.unit))
    }

    /// Applies a review; false when there is no answer to the card.
    @discardableResult
    func recordGrade(post: String, score: Int, feedback: String) -> Bool {
        guard let response = responses[post] else { return false }
        let now = Date()
        let value = min(max(score, 0), 4)
        var graded = response
        graded.score = value
        graded.feedback = feedback
        graded.gradedAt = now
        save(graded)
        if response.score != nil { return true } // a second review replaces the text, not the count
        guard let track = state.tracks.first(where: { $0.id == response.track }) else { return true }
        if response.level != track.level { return true } // a card from another level does not move this one
        if response.kind == "theory" { return true } // understanding is reviewed and recalled; the level moves on what the person can do
        updateTrack(track.id) { response.kind == "challenge" ? Self.checkLevel($0, score: value, now: now) : Self.applyScore($0, score: value, now: now) }
        return true
    }

    private static func applyScore(_ t: NanoMuseGrowthTrack, score: Int, now: Date) -> NanoMuseGrowthTrack {
        var t = t
        let scores = Array((t.scores + [score]).suffix(window * 2))
        let days = Array((t.scoreDays + [NanoMuseDay.key(now)]).suffix(window * 2))
        let recent = Array(scores.suffix(window))
        let mean = recent.isEmpty ? 0 : Double(recent.reduce(0, +)) / Double(recent.count)
        if t.level < maxLevel, recent.count >= window, mean >= passMean, Set(days.suffix(window)).count >= minDays {
            t.scores = scores; t.scoreDays = days; t.challenge = true
        } else if t.status == maintain, t.level > 1, scores.count >= dropWindow,
                  Double(scores.suffix(dropWindow).reduce(0, +)) / Double(dropWindow) < dropMean {
            t.level -= 1; t.scores = []; t.scoreDays = []; t.reachedAt = now; t.challenge = false
        } else {
            t.scores = scores; t.scoreDays = days
        }
        return t
    }

    /// The level check: 3 or more raises the level; less keeps three answers, so three more good ones reopen it.
    private static func checkLevel(_ t: NanoMuseGrowthTrack, score: Int, now: Date) -> NanoMuseGrowthTrack {
        var t = t
        if score >= 3 && t.level < maxLevel {
            t.level += 1; t.scores = []; t.scoreDays = []; t.reachedAt = now
        } else {
            t.scores = Array(t.scores.suffix(dropWindow)); t.scoreDays = Array(t.scoreDays.suffix(dropWindow))
        }
        t.challenge = false
        return t
    }

    func setDifficulty(post: String, _ difficulty: String) {
        guard var response = responses[post], response.difficulty != difficulty else { return }
        response.difficulty = difficulty
        save(response)
    }

    /// Cards were written for these abilities: their review clock starts again.
    func cardsWritten(_ posts: [NanoMusePost]) {
        let now = Date()
        for id in Set(posts.compactMap(\.track)) { updateTrack(id) { var t = $0; t.lastCardAt = now; return t } }
    }

    func ungraded() -> [NanoMuseGrowthResponse] {
        responses.values.filter { $0.score == nil }.sorted { $0.answeredAt < $1.answeredAt }
    }

    func recentGraded(_ limit: Int) -> [NanoMuseGrowthResponse] {
        Array(responses.values.filter { $0.score != nil }.sorted { ($0.gradedAt ?? .distantPast) > ($1.gradedAt ?? .distantPast) }.prefix(limit))
    }

    /// Cards of this ability from the last `days` days still waiting for an answer: the real-life tasks when `action`, the rest otherwise.
    func unanswered(_ track: String, posts: [NanoMusePost], days: Int, action: Bool) -> [NanoMusePost] {
        let since = Date().addingTimeInterval(-Double(days) * Self.day)
        return posts.filter { $0.track == track && !$0.prompt.isEmpty && $0.createdAt >= since && responses[$0.id] == nil && ($0.type == "action") == action }
    }

    /// Days in a row, up to today or yesterday, with at least one answer.
    func streak(now: Date = Date()) -> Int {
        let days = Set(responses.values.map { NanoMuseDay.key($0.answeredAt) })
        var day = now
        if !days.contains(NanoMuseDay.key(day)) { day = day.addingTimeInterval(-Self.day) }
        var count = 0
        while days.contains(NanoMuseDay.key(day)) { count += 1; day = day.addingTimeInterval(-Self.day) }
        return count
    }

    // MARK: Recall

    func addRecall(track: String, question: String, answer: String) {
        let q = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let a = String(answer.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
        guard !q.isEmpty, !a.isEmpty, !recall.contains(where: { $0.question == q }) else { return }
        let now = Date()
        let item = NanoMuseRecallItem(id: String(Int(now.timeIntervalSince1970 * 1000), radix: 36), track: track, question: q, answer: a,
                                      due: Calendar.current.startOfDay(for: now).addingTimeInterval(Self.day), intervalDays: 1, reps: 0, lapses: 0)
        writeRecall(Array((recall + [item]).suffix(Self.keepRecall)))
    }

    /// Items due today, oldest due first, at most `recallPerDay`.
    func dueRecall(now: Date = Date()) -> [NanoMuseRecallItem] {
        Array(recall.filter { $0.due <= now }.sorted { $0.due < $1.due }.prefix(Self.recallPerDay))
    }

    /// Remembered stretches the interval about 2.5 times, vague about 1.3 times, forgot brings it back tomorrow.
    func rateRecall(id: String, rating: String) {
        let now = Date()
        writeRecall(recall.map { item in
            guard item.id == id else { return item }
            var next = item
            var days: Int
            switch rating {
            case "good": days = max(Int(Double(item.intervalDays) * 2.5), item.intervalDays + 1)
            case "hard": days = max(Int(Double(item.intervalDays) * 1.3), 1)
            default: days = 1
            }
            days = min(days, 180)
            next.due = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(days) * Self.day)
            next.intervalDays = days
            next.reps += 1
            if rating == "again" { next.lapses += 1 }
            return next
        })
    }

    /// Points forgotten more than once, for the cards to work back in.
    func weakRecall(_ limit: Int) -> [NanoMuseRecallItem] {
        Array(recall.filter { $0.lapses >= 2 }.sorted { $0.lapses > $1.lapses }.prefix(limit))
    }

    // MARK: The person's choices

    func setFocus(_ id: String) {
        mutate { s in
            var s = s
            s.tracks = s.tracks.map { t in
                var t = t
                if t.id == id { t.status = Self.focus; t.level = max(t.level, 1) }
                else if t.status == Self.focus { t.status = t.level >= s.target ? Self.maintain : Self.queued }
                return t
            }
            return s
        }
    }

    /// "Move on": the ability in training is kept up from now on, the next in the queue starts.
    func advance() {
        mutate { s in
            guard let focus = s.focus else { return s }
            let next = s.next()
            var s = s
            s.tracks = s.tracks.map { t in
                var t = t
                if t.id == focus.id { t.status = Self.maintain } else if t.id == next?.id { t.status = Self.focus }
                return t
            }
            s.offered.insert("\(focus.id):\(focus.level)")
            return s
        }
    }

    /// "Keep going": no more asking until this ability reaches the next level.
    func keepGoing() {
        mutate { s in
            guard let f = s.focus else { return s }
            var s = s
            s.offered.insert("\(f.id):\(f.level)")
            return s
        }
    }

    func setTarget(_ level: Int) { mutate { var s = $0; s.target = min(max(level, 2), Self.maxLevel); return s } }

    func setPaused(_ id: String, _ paused: Bool) {
        mutate { s in
            var s = s
            s.tracks = s.tracks.map { t in
                guard t.id == id else { return t }
                var t = t
                t.status = paused ? Self.paused : (t.level >= s.target ? Self.maintain : Self.queued)
                return t
            }
            return s
        }
    }

    /// One place up; the queue order is the training order.
    func moveUp(_ id: String) {
        mutate { s in
            guard let i = s.tracks.firstIndex(where: { $0.id == id }), i > 0 else { return s }
            var s = s
            s.tracks.swapAt(i, i - 1)
            return s
        }
    }

    /// An ability the person named; returns its id.
    @discardableResult
    func add(title: String, about: String, skill: String? = nil) -> String {
        let id = "custom-" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        mutate { s in
            var s = s
            s.tracks.append(NanoMuseGrowthTrack(id: id, title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)),
                                                about: String(about.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
                                                skill: skill ?? Self.generalSkill, status: s.focus == nil ? Self.focus : Self.queued,
                                                level: 1, scores: [], scoreDays: [], lastCardAt: nil, reachedAt: nil))
            return s
        }
        return id
    }

    /// The ability is trained by `skill` from the next card on.
    func setSkill(_ id: String, _ skill: String) { updateTrack(id) { var t = $0; t.skill = skill; return t } }

    /// Only abilities the person added can be removed; the built-in ones can be paused.
    func remove(_ id: String) { mutate { var s = $0; s.tracks.removeAll { $0.id == id && $0.title != nil }; return s } }

    // MARK: The coach's files

    /// The reviewer's notes since the last summary, one line each.
    func observations() -> [String] {
        read(observationsFile).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("- ") }
    }

    func observe(track: String, _ line: String) {
        let text = String(line.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces).prefix(200))
        guard !text.isEmpty else { return }
        let all = Array((observations() + ["- \(NanoMuseDay.key()) \(track): \(text)"]).suffix(Self.keepObservations))
        write(observationsFile, all.joined(separator: "\n") + "\n")
    }

    /// The weekly rewrite: MEMORY.md becomes the new summary, which folds the observations in.
    func replaceMemory(_ summary: String) {
        write(memoryFile, String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)) + "\n")
        write(observationsFile, "")
    }

    func addPrinciple(_ text: String, category: String?, from: String?) {
        let line = String(text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces).prefix(200))
        guard !line.isEmpty else { return }
        let existing = read(principlesFile)
        guard !existing.contains(line) else { return }
        let tag = category.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : "[\($0)] " } ?? ""
        let origin = [from?.trimmingCharacters(in: .whitespaces), NanoMuseDay.key()].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        let entry = "- \(tag)\(line) (\(origin))\n"
        write(principlesFile, existing.isEmpty ? "# \(AppLocalized("My principles"))\n\n\(entry)" : "\(existing)\n\(entry)")
    }

    // MARK: The courses

    /// An ability's course is its skill's folder (/var/minis/skills/<skill>/): SKILL.md, books/, FRAMEWORK.md, ADJUSTMENTS.md.
    func courseDir(_ skill: String) -> URL? {
        guard !skill.isEmpty, !skill.contains("/"), !skill.contains("\\"), !skill.contains("..") else { return nil }
        return AIChatViewModel.minisSkillsPersistentDir.appendingPathComponent(skill, isDirectory: true)
    }

    /// The course's book cards, B01 first: file name and text.
    func bookCards(_ skill: String) -> [(name: String, text: String)] {
        guard let books = courseDir(skill)?.appendingPathComponent("books", isDirectory: true),
              let names = try? FileManager.default.contentsOfDirectory(atPath: books.path) else { return [] }
        return names.filter { $0.hasSuffix(".md") }.sorted().compactMap { name in
            let text = read(books.appendingPathComponent(name))
            return text.isEmpty ? nil : (name, text)
        }
    }

    func framework(_ skill: String) -> String { courseDir(skill).map { read($0.appendingPathComponent("FRAMEWORK.md")) } ?? "" }

    func writeFramework(_ skill: String, _ text: String) {
        guard let folder = courseDir(skill) else { return }
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxFramework))
        guard !body.isEmpty else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        write(folder.appendingPathComponent("FRAMEWORK.md"), body + "\n")
    }

    /// The course changes in force, one line each, oldest first.
    func adjustments(_ skill: String) -> [String] {
        guard let folder = courseDir(skill) else { return [] }
        return read(folder.appendingPathComponent("ADJUSTMENTS.md")).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("- ") }
    }

    func addAdjustment(_ skill: String, _ change: String) {
        guard let folder = courseDir(skill) else { return }
        let line = String(change.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces).prefix(300))
        guard !line.isEmpty else { return }
        let file = folder.appendingPathComponent("ADJUSTMENTS.md")
        let existing = read(file)
        guard !existing.contains(line) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let head = existing.isEmpty ? "# \(AppLocalized("Course adjustments"))\n\n" : "\(existing)\n"
        write(file, head + "- \(NanoMuseDay.key()) \(line)\n")
    }

    // MARK: Storage

    private static func defaults() -> NanoMuseGrowthState {
        NanoMuseGrowthState(target: 3, tracks: builtInTracks(), offered: [])
    }

    private static func builtInTracks() -> [NanoMuseGrowthTrack] {
        NanoMuseGrowthTrack.builtIn.enumerated().map { i, b in
            NanoMuseGrowthTrack(id: b.id, title: nil, about: nil, skill: "growth-\(b.id)", status: i == 0 ? focus : queued,
                                level: 1, scores: [], scoreDays: [], lastCardAt: nil, reachedAt: nil)
        }
    }

    private func mutate(_ change: (NanoMuseGrowthState) -> NanoMuseGrowthState) {
        let next = change(state)
        guard next != state else { return }
        state = next
        writeState(next)
    }

    private func updateTrack(_ id: String, _ change: (NanoMuseGrowthTrack) -> NanoMuseGrowthTrack) {
        mutate { s in
            var s = s
            s.tracks = s.tracks.map { $0.id == id ? change($0) : $0 }
            return s
        }
    }

    private func write(_ url: URL, _ text: String) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func save(_ response: NanoMuseGrowthResponse) {
        responses[response.post] = response
        let line = Self.json(response) + "\n"
        if let handle = try? FileHandle(forWritingTo: responsesFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            write(responsesFile, line)
        }
        let count = read(responsesFile).components(separatedBy: "\n").count
        if count > Self.keepResponses * 2 {
            let keep = responses.values.sorted { $0.answeredAt < $1.answeredAt }.suffix(Self.keepResponses)
            write(responsesFile, keep.map { Self.json($0) + "\n" }.joined())
        }
    }

    private static func millis(_ date: Date?) -> Any { date.map { Int64($0.timeIntervalSince1970 * 1000) } ?? NSNull() }
    private static func date(_ value: Any?) -> Date? { (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }

    private static func json(_ r: NanoMuseGrowthResponse) -> String {
        let o: [String: Any] = [
            "post": r.post, "track": r.track, "level": r.level, "prompt": r.prompt, "answer": r.answer,
            "answered_at": millis(r.answeredAt), "score": r.score.map { $0 as Any } ?? NSNull(), "feedback": r.feedback.map { $0 as Any } ?? NSNull(),
            "graded_at": millis(r.gradedAt), "kind": r.kind, "difficulty": r.difficulty.map { $0 as Any } ?? NSNull(), "unit": r.unit,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func readResponses() -> [String: NanoMuseGrowthResponse] {
        var out: [String: NanoMuseGrowthResponse] = [:]
        for line in read(responsesFile).components(separatedBy: "\n") where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let post = o["post"] as? String, !post.isEmpty else { continue }
            out[post] = NanoMuseGrowthResponse(
                post: post, track: o["track"] as? String ?? "", level: (o["level"] as? NSNumber)?.intValue ?? 1,
                prompt: o["prompt"] as? String ?? "", answer: o["answer"] as? String ?? "",
                answeredAt: Self.date(o["answered_at"]) ?? Date(), score: (o["score"] as? NSNumber)?.intValue,
                feedback: o["feedback"] as? String, gradedAt: Self.date(o["graded_at"]),
                kind: o["kind"] as? String ?? "practice", difficulty: o["difficulty"] as? String, unit: o["unit"] as? String ?? "")
        }
        return out
    }

    private func readRecall() -> [NanoMuseRecallItem] {
        guard let data = try? Data(contentsOf: recallFile),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return items.compactMap { o in
            guard let id = o["id"] as? String, let q = o["q"] as? String, let a = o["a"] as? String else { return nil }
            return NanoMuseRecallItem(id: id, track: o["track"] as? String ?? "", question: q, answer: a,
                                      due: Self.date(o["due"]) ?? Date(), intervalDays: (o["interval"] as? NSNumber)?.intValue ?? 1,
                                      reps: (o["reps"] as? NSNumber)?.intValue ?? 0, lapses: (o["lapses"] as? NSNumber)?.intValue ?? 0)
        }
    }

    private func writeRecall(_ items: [NanoMuseRecallItem]) {
        recall = items
        let list: [[String: Any]] = items.map {
            ["id": $0.id, "track": $0.track, "q": $0.question, "a": $0.answer, "due": Self.millis($0.due),
             "interval": $0.intervalDays, "reps": $0.reps, "lapses": $0.lapses]
        }
        if let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: recallFile, options: .atomic)
        }
    }

    private func writeState(_ s: NanoMuseGrowthState) {
        let tracks: [[String: Any]] = s.tracks.map { t in
            ["id": t.id, "title": t.title.map { $0 as Any } ?? NSNull(), "about": t.about.map { $0 as Any } ?? NSNull(),
             "skill": t.skill, "status": t.status, "level": t.level, "scores": t.scores, "score_days": t.scoreDays,
             "last_card_at": Self.millis(t.lastCardAt), "reached_at": Self.millis(t.reachedAt), "challenge": t.challenge]
        }
        let o: [String: Any] = ["version": 1, "target": s.target, "offered": Array(s.offered).sorted(), "tracks": tracks]
        if let data = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }

    private static func parseState(_ data: Data) -> NanoMuseGrowthState? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = o["tracks"] as? [[String: Any]] else { return nil }
        let statuses: Set<String> = [focus, queued, maintain, paused]
        let tracks: [NanoMuseGrowthTrack] = list.compactMap { t in
            guard let id = t["id"] as? String else { return nil }
            let title = (t["title"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let about = (t["about"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let skill = (t["skill"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? generalSkill
            let status = (t["status"] as? String).flatMap { statuses.contains($0) ? $0 : nil } ?? queued
            let level = min(max((t["level"] as? NSNumber)?.intValue ?? 1, 1), maxLevel)
            return NanoMuseGrowthTrack(id: id, title: title, about: about, skill: skill, status: status, level: level,
                                       scores: (t["scores"] as? [NSNumber])?.map(\.intValue) ?? [],
                                       scoreDays: t["score_days"] as? [String] ?? [],
                                       lastCardAt: date(t["last_card_at"]), reachedAt: date(t["reached_at"]),
                                       challenge: t["challenge"] as? Bool ?? false)
        }
        let target = min(max((o["target"] as? NSNumber)?.intValue ?? 3, 2), maxLevel)
        return NanoMuseGrowthState(target: target, tracks: tracks, offered: Set(o["offered"] as? [String] ?? []))
    }
}
