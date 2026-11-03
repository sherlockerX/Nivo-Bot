//
//  NanoMuseGrowthFlow.swift
//  nanoMuse
//
//  How the coach trains: which cards today brings (the plan), what the coach's conversation is
//  told (the abilities, the course units so far, the skills of today's abilities, the answers
//  waiting for review, the growth memory and the principles), and the review of an answer, which
//  runs as one turn in that conversation as soon as the answer is sent. The model only scores;
//  levels move in NanoMuseGrowthStore by fixed rules. The prompt text is the Android app's,
//  word for word, so both phones coach the same way.
//  Android: growth/GrowthFlow.kt.
//

import Foundation

@MainActor
enum NanoMuseGrowthFlow {
    static let gradeBlock = "grade"
    static let memoryBlock = "memory"
    static let courseBlock = "course"
    static let frameworkBlock = "framework"
    private static let skillChars = 6000
    private static let bookChars = 12000
    private static let day: TimeInterval = 24 * 60 * 60

    /// Beginner, Foundation, Proficient, Advanced, Expert; keys of their own, since "Advanced" is taken elsewhere in the app.
    static func levelName(_ level: Int) -> String {
        level >= 1 && level <= NanoMuseGrowthStore.maxLevel ? AppLocalized("growth.level.\(level)") : ""
    }

    static func levelLabel(_ level: Int) -> String { "Lv\(level) " + levelName(level) }

    /// Answers being reviewed right now, by card id.
    static var grading: Set<String> {
        get { NanoMuseGrowthReviews.shared.grading }
        set { NanoMuseGrowthReviews.shared.grading = newValue }
    }

    struct Slot { var track: NanoMuseGrowthTrack; var kind: String; var count: Int }

    /// Today's cards for the ability in training: a theory card, a scenario drill (the level check
    /// instead once it is unlocked; none while three recent cards wait for an answer), and a task
    /// for real life while none from the last week waits for its report. Then a review for the
    /// kept-up ability most overdue; with nothing in training, reviews for the two most overdue.
    static func plan(_ posts: [NanoMusePost], now: Date = Date()) -> [Slot] {
        let store = NanoMuseGrowthStore.shared
        let s = store.state
        var slots: [Slot] = []
        if let f = s.focus {
            let backlog = store.unanswered(f.id, posts: posts, days: 3, action: false).count >= 3
            slots.append(Slot(track: f, kind: "theory", count: 1))
            if f.challenge { slots.append(Slot(track: f, kind: "challenge", count: 1)) }
            else if !backlog { slots.append(Slot(track: f, kind: "practice", count: 1)) }
            if store.unanswered(f.id, posts: posts, days: 7, action: true).isEmpty { slots.append(Slot(track: f, kind: "action", count: 1)) }
        }
        let due = s.tracks.filter { $0.status == NanoMuseGrowthStore.maintain && now.timeIntervalSince($0.lastCardAt ?? .distantPast) >= reviewEvery($0.level) }
            .sorted { ($0.lastCardAt ?? .distantPast) < ($1.lastCardAt ?? .distantPast) }
            .prefix(s.focus == nil ? 2 : 1)
        for t in due { slots.append(Slot(track: t, kind: t.challenge ? "challenge" : "review", count: 1)) }
        return slots
    }

    /// Sunday's report is written once a week.
    private static func weeklyDue(_ posts: [NanoMusePost], now: Date) -> Bool {
        Calendar.current.component(.weekday, from: now) == 1 && !posts.contains { $0.type == "weekly" && now.timeIntervalSince($0.createdAt) < 6 * day }
    }

    private static func reviewEvery(_ level: Int) -> TimeInterval {
        day * (level <= 2 ? 2 : level == 3 ? 3 : level == 4 ? 7 : 14)
    }

    /// The units an ability went through at its current level, with the scores per card kind.
    private static func unitLines(_ t: NanoMuseGrowthTrack, posts: [NanoMusePost]) -> [String] {
        let answered = NanoMuseGrowthStore.shared.responses
        let done = answered.values.filter { $0.track == t.id && $0.level == t.level && !$0.unit.isEmpty }.sorted { $0.answeredAt < $1.answeredAt }
        let open = posts.filter { $0.track == t.id && $0.level == t.level && !$0.unit.isEmpty && answered[$0.id] == nil }.sorted { $0.createdAt < $1.createdAt }
        var units: [String] = []
        for u in done.map(\.unit) + open.map(\.unit) where !units.contains(u) { units.append(u) }
        return units.map { unit in
            let kinds: [String] = ["theory", "practice", "action", "challenge"].compactMap { kind in
                let marks = done.filter { $0.unit == unit && $0.kind == kind }.map { $0.score.map(String.init) ?? "?" } +
                    open.filter { $0.unit == unit && $0.type == kind }.map { _ in "open" }
                return marks.isEmpty ? nil : "\(kind) \(marks.joined(separator: ","))"
            }
            return "- \(unit): \(kinds.joined(separator: "; "))"
        }
    }

    /// The growth part of the coach conversation's system prompt.
    static func section(_ posts: [NanoMusePost]) -> String {
        let store = NanoMuseGrowthStore.shared
        let s = store.state
        let slots = plan(posts)
        let pending = Array(store.ungraded().prefix(6))
        var needed: [NanoMuseGrowthTrack] = []
        for t in slots.map(\.track) + pending.compactMap({ r in s.tracks.first { $0.id == r.track } }) where !needed.contains(where: { $0.id == t.id }) {
            needed.append(t)
        }
        let now = Date()
        var out = "## Coaching: the only job of this conversation\n"
        out += "This conversation coaches the user on the Coach tab. Its cards train the user's abilities one at a time, and you review every answer. " +
            "Write training cards and nothing else: no news, no paper or article summaries, no information digests, no general posts, whatever the standing instruction says. " +
            "Information the user wants delivered belongs in their scheduled tasks; the standing instruction only steers the material and the emphasis of the cards.\n\n"
        out += "Who you are training: a capable young adult who understands fast, follows through and can change a great deal, but who starts from zero in these abilities. " +
            "Their upbringing taught them little about social and practical life, so assume no prior knowledge: one idea at a time, plain words, examples from ordinary life, " +
            "and concrete steps and words to say. Be direct; no flattery, no lectures. Their own profile is USER.md above, once they have written it. " +
            "Never hand out conclusions as truths about them: they answer first, your view comes after theirs with the strongest counter-view, and you say what is evidence and what is your guess.\n\n"
        out += "How each ability is trained (its skill below holds the books and the course, unit by unit and level by level):\n"
        out += "- theory card, the knowledge to build: one idea from the current unit, in your own words (never quote the book at length): what it says, why it holds, " +
            "where it stops holding, one everyday example, and the book and part it comes from. Its prompt asks the user to restate it in their own words and give an example from their own life.\n"
        out += "- practice card, a scenario drill: a concrete situation the user is likely to meet; the prompt asks what they would do or say. " +
            "At level 1 the body may name what to watch for, never the plan itself. Your review then gives a response plan they can follow: steps and sentences.\n"
        out += "- action card, what must be done in real life: give it directly, no warm-up: what to do, when, how (the steps, the exact words), and what to watch for. " +
            "Its prompt asks them to come back after doing it: what they did, how the other side reacted, what came of it, what they would change. " +
            "The user makes the chance to do it; the real result is the feedback they correct themselves by.\n"
        out += "- Within the current level, units go in the order the skill lists them: theory first, then practice, then action. " +
            "Move to the next unit once its theory and one practice or action have scored 3 or more; stay longer on a unit whose scores are low.\n\n"
        out += "Abilities (id · name · status · level of 5 · recent scores at this level, 0 to 4):\n"
        for t in s.tracks {
            let scores = t.scores.suffix(NanoMuseGrowthStore.window).map(String.init).joined(separator: ",")
            out += "- \(t.id) · \(t.displayTitle) · \(t.status) · L\(t.level) \(levelName(t.level)) · " + (scores.isEmpty ? "no scores yet" : scores) +
                (t.challenge ? " · level check unlocked" : "") + (t.about.map { " · what the user wants: \($0)" } ?? "") + "\n"
        }
        out += "Moving on happens at L\(s.target). \(NanoMuseGrowthStore.window) answers to practice and action cards averaging 3 or more over 4 days unlock a level check; " +
            "a score of 3 or more on the level check raises the level. Theory answers are reviewed and recalled but do not count toward the level. The app counts; you only score.\n\n"
        if slots.isEmpty {
            out += "Today's plan: nothing is in training, so write no cards.\n"
        } else {
            out += "Today's plan:\n"
            for slot in slots { out += "- \(slot.count) \(slot.kind) card(s) for `\(slot.track.id)` at level \(slot.track.level)\n" }
        }
        if let f = s.focus {
            out += "\n"
            let units = unitLines(f, posts: posts)
            if units.isEmpty {
                out += "Course units of `\(f.id)` at L\(f.level): none started yet; begin with the first unit of L\(f.level) in its skill.\n"
            } else {
                out += "Course units of `\(f.id)` at L\(f.level) so far (scores per kind; ? = answered, not reviewed; open = not answered):\n"
                out += units.joined(separator: "\n") + "\n"
            }
            let open = store.unanswered(f.id, posts: posts, days: 7, action: true)
            if !open.isEmpty {
                out += "Real-life tasks still waiting for the user's report (set no new one; do not repeat them):\n"
                for p in open { out += "- \(p.title)" + (p.unit.isEmpty ? "" : " (\(p.unit))") + ", \(Int(now.timeIntervalSince(p.createdAt) / day)) day(s) ago\n" }
            }
        }
        let recent = store.recentGraded(8)
        if !recent.isEmpty {
            out += "\nRecently reviewed answers (adjust the difficulty, do not repeat a question):\n"
            for r in recent {
                out += "- \(r.track) L\(r.level) \(r.kind)" + (r.unit.isEmpty ? "" : " \(r.unit)") + " score \(r.score ?? 0)" +
                    (r.difficulty.map { ", felt \($0)" } ?? "") +
                    ": Q: \(r.prompt.prefix(100)) | A: \(r.answer.prefix(120)) | feedback: \((r.feedback ?? "").prefix(120))\n"
            }
            out += "When the user marked recent cards too easy or too hard, move the difficulty within the level accordingly.\n"
        }
        let weak = store.weakRecall(5)
        if !weak.isEmpty {
            out += "\nPoints the user keeps forgetting (work them into today's cards when they fit):\n"
            for w in weak { out += "- [\(w.track)] \(w.question) → \(w.answer.prefix(120))\n" }
        }
        if !pending.isEmpty {
            out += "\nAnswers waiting for review:\n"
            for p in pending {
                out += "- post=\(p.post) track=\(p.track) level=\(p.level) kind=\(p.kind)" + (p.unit.isEmpty ? "" : " unit=\(p.unit)") +
                    " Q: \(p.prompt.prefix(200)) | A: \(p.answer.prefix(800))\n"
            }
        }
        let memory = store.read(store.memoryFile)
        let observations = store.observations()
        if !memory.isEmpty || !observations.isEmpty {
            out += "\nGrowth memory (how this user learns, kept by you):\n"
            if !memory.isEmpty { out += String(memory.prefix(2500)) + "\n" }
            if !observations.isEmpty { out += "Observations since the last summary:\n" + observations.suffix(20).joined(separator: "\n") + "\n" }
        }
        let principles = store.read(store.principlesFile)
        if !principles.isEmpty { out += "\nThe user's own principles so far:\n" + String(principles.prefix(1800)) + "\n" }
        let folders = NanoMuseGrowthSources.folders().filter(\.available)
        if !folders.isEmpty {
            out += "\nThe user's own notes, mounted in the sandbox (list and read files there when a card needs material from them; this counts toward the three tool calls):\n"
            for f in folders { out += "- \(f.linuxPath) (\(f.source))\n" }
        }
        if !needed.isEmpty {
            out += "\n## Skills for these abilities (books, course units by level, card kinds, rubric)\n"
            for t in needed {
                out += "### \(t.id) (skill `\(t.skill)`)\n"
                if let body = skillBody(t.skill) { out += String(body.prefix(skillChars)) + "\n" }
                else if let general = skillBody(NanoMuseGrowthStore.generalSkill) { out += "(its own skill is not written yet; the general method follows)\n" + String(general.prefix(skillChars)) + "\n" }
                else { out += "(skill missing: train \(t.displayTitle) with good general practice)\n" }
                if let about = t.about { out += "What the user wants from this ability: \(about)\n" }
            }
        }
        if let f = s.focus {
            out += "\n"
            let books = store.bookCards(f.skill)
            if books.isEmpty {
                out += "### Book cards of `\(f.id)`: none yet. Teach from the skill's book list and your own knowledge, mark what you are not sure of as unverified, " +
                    "and once, in a card's body, suggest building the course (Build the course, on the abilities sheet).\n"
            } else {
                out += "### Book cards of `\(f.id)` (/var/minis/skills/\(f.skill)/books/): theory cards teach a model from these; put the book id and title in source\n"
                var left = bookChars
                for book in books where left > 0 {
                    let part = String(book.text.prefix(min(1500, left)))
                    out += "#### \(book.name)\n\(part)\n"
                    left -= part.count
                }
            }
            out += "\n### The user's framework for `\(f.id)` (FRAMEWORK.md, what they will keep for life)\n"
            let framework = String(store.framework(f.skill).prefix(3500))
            out += (framework.isEmpty ? "(not started: write it the first time a unit is completed, one heading per sub-skill of the course)" : framework) + "\n"
            let adjustments = store.adjustments(f.skill).suffix(12)
            if !adjustments.isEmpty {
                out += "\n### Course adjustments in force (newest last; where they differ from the course, they win)\n" + adjustments.joined(separator: "\n") + "\n"
            }
        }
        out += "\n## Formats\n"
        out += "When a message asks you to write the cards: reply with one short line, then (1) one `nanomuse-\(gradeBlock)` block for each answer waiting for review, " +
            "(2) the cards of today's plan, each its own fenced block tagged `nanomuse-feed` with JSON " +
            "{\"emoji\": \"one emoji\", \"title\": \"<= 30 characters\", \"type\": \"theory|practice|action|challenge|review\", \"track\": \"<ability id>\", \"level\": <its level>, " +
            "\"unit\": \"the unit as the skill numbers and names it, e.g. 1.2 and its name\", " +
            "\"body\": \"Markdown; theory: the idea as described above, 4 to 10 sentences; practice: the situation, 2 to 6 sentences; action: the task with its steps and the words to say; never the answer to the prompt\", " +
            "\"prompt\": \"the one question the user answers, 1 or 2 sentences\", \"source\": [\"the book and its part, or where the material came from\"]}. " +
            "Write no other kind of post. Say nothing after the last block. " +
            "A challenge card is the level check: harder than practice at the same level, mixing what the level covers, in a situation the user has not seen. " +
            "A review card revisits a kept-up ability with a scenario or a small real-life task from its level.\n"
        if weeklyDue(posts, now: now) {
            out += "Today is the weekly report: add one post of type `weekly` (no track, no prompt): what moved this week (levels, units, scores, " +
                "what the user marked too easy or too hard, the real-life tasks done and what came of them), the one recurring gap, and the one focus for next week, in 4 to 8 lines.\n"
        }
        out += "When a message starts with [GRADE]: reply with one short line and exactly one `nanomuse-\(gradeBlock)` block for that post. " +
            "Format: {\"post\": \"<post id>\", \"score\": 0-4, \"feedback\": \"Markdown in the user's language: what holds, what is missing, one concrete next step. " +
            "For a practice card add a response plan they can follow (steps and sentences). For an action report compare what happened with the plan, " +
            "name what worked and what to change, and set the next concrete attempt.\", " +
            "\"memory\": \"optional: one new line about how this user learns or thinks\", " +
            "\"takeaway\": {\"q\": \"a question\", \"a\": \"a short answer\"} optional: one point worth remembering from this answer (the idea of a theory card, a corrected English expression, a principle, the key question of a lens), the app brings it back at growing intervals, " +
            "\"principle\": {\"text\": \"...\", \"category\": \"做人|做事|公司 or similar\", \"from\": \"the event\"} only when the user adopted or rewrote a principle in this answer}. " +
            "Score with the ability's rubric at the card's level; a blank, evasive or off-topic answer scores 0; do not inflate. " +
            "An action report is scored on the doing and the reflection, not on whether the other side happened to agree. A challenge card is scored strictly: 3 means the next level is earned.\n"
        out += "When the user's scores or real-world reports show the course should change for them (repeat a unit, add a remedial unit, skip one they already master, " +
            "bring in another book, change the order), add one `nanomuse-\(courseBlock)` block with JSON {\"track\": \"<ability id>\", \"change\": \"one line: what changes and why\"}. " +
            "The app keeps these with the course and shows them to you every day.\n"
        out += "Whenever a unit of the ability in training has just been completed (its theory and one practice or action scored 3 or more), and on Sunday, " +
            "rewrite the user's framework for it: one block whose fence line is ```nanomuse-\(frameworkBlock) track=<ability id> and whose content is the whole new FRAMEWORK.md in Markdown. " +
            "Keep one heading per sub-skill of the course; under each, what the user has learnt: the model (with its book id), their own case from their answers, " +
            "and the principle or habit they hold now. Keep everything that was there, at most 4000 characters, in the user's language.\n"
        if Calendar.current.component(.weekday, from: now) == 1 || store.observations().count >= 20 {
            out += "Once in this run, also rewrite the growth memory: one `nanomuse-\(memoryBlock)` block holding the full new text (<= 1200 characters, the user's language): " +
                "how the user learns now, strengths, recurring gaps, what works for them. Fold the observations in.\n"
        }
        return out
    }

    /// The skill as it is on disk now, so an edit by the user or the agent counts at once; front matter dropped.
    private static func skillBody(_ id: String) -> String? {
        guard let dir = NanoMuseGrowthStore.shared.courseDir(id),
              let text = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return nil }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = Array(lines[(end + 1)...])
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    // MARK: Answers and reviews

    /// Saves the answer and starts its review.
    static func submit(_ post: NanoMusePost, answer: String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, post.track != nil else { return }
        NanoMuseGrowthStore.shared.recordAnswer(post, answer: text)
        review(post.id)
    }

    /// One review turn in the coach conversation, after the coach's own run when one is going. A
    /// review that cannot run now stays waiting: the next run reviews it, or a tap retries.
    static func review(_ postId: String) {
        guard !grading.contains(postId), let response = NanoMuseGrowthStore.shared.responses[postId] else { return }
        grading.insert(postId)
        Task { @MainActor in
            defer { grading.remove(postId) }
            guard await NanoMuseFeedFlow.ensureRoutine() != nil, let session = NanoMuseFeedFlow.sessionId else { return }
            let deadline = Date().addingTimeInterval(180)
            while NanoMuseFeedFlow.generating && Date() < deadline { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            guard !NanoMuseFeedFlow.generating else { return }
            // The card itself goes along: after a compaction the conversation may no longer hold it.
            let card = NanoMuseFeedStore.shared.posts.first { $0.id == postId }
            var message = "[GRADE] post=\(response.post) track=\(response.track) level=\(response.level) kind=\(response.kind)" +
                (response.unit.isEmpty ? "" : " unit=\(response.unit)") + "\n"
            if let card { message += "Card: \(card.title)\n" + String(card.body.prefix(1500)) + "\n" }
            message += "Question: \(response.prompt)\nAnswer:\n\(response.answer)"
            _ = await NanoMuseHeadless.run(prompt: message, sessionId: session, title: nil, source: "nanomuse-feed", timeout: 180)
        }
    }

    /// Reads reviews, the memory rewrite, course changes and the framework out of a finished turn of the coach conversation.
    static func afterTurn(_ text: String) {
        let store = NanoMuseGrowthStore.shared
        for o in NanoMuseFences.objects(gradeBlock, in: text) {
            let post = (o["post"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !post.isEmpty, let score = (o["score"] as? NSNumber)?.intValue, (0...4).contains(score),
                  let response = store.responses[post],
                  store.recordGrade(post: post, score: score, feedback: (o["feedback"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            if let memory = (o["memory"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !memory.isEmpty { store.observe(track: response.track, memory) }
            if let takeaway = o["takeaway"] as? [String: Any] {
                store.addRecall(track: response.track, question: takeaway["q"] as? String ?? "", answer: takeaway["a"] as? String ?? "")
            }
            if let p = o["principle"] as? [String: Any], let line = p["text"] as? String, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                store.addPrinciple(line, category: p["category"] as? String, from: p["from"] as? String)
            } else if let line = o["principle"] as? String, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                store.addPrinciple(line, category: nil, from: nil)
            }
        }
        if let memory = NanoMuseFences.blocks(memoryBlock, in: text).first?.trimmingCharacters(in: .whitespacesAndNewlines), !memory.isEmpty {
            store.replaceMemory(memory)
        }
        let tracks = store.state.tracks
        for o in NanoMuseFences.objects(courseBlock, in: text) {
            guard let track = tracks.first(where: { $0.id == (o["track"] as? String ?? "").trimmingCharacters(in: .whitespaces) }),
                  let change = (o["change"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !change.isEmpty else { continue }
            store.addAdjustment(track.skill, change)
        }
        // The framework's fence line names the ability: ```nanomuse-framework track=<id>
        if let regex = try? NSRegularExpression(pattern: "```nanomuse-\(frameworkBlock)[ \\t]+track=([A-Za-z0-9_-]+)[ \\t]*\\r?\\n([\\s\\S]*?)```") {
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let id = ns.substring(with: m.range(at: 1))
                guard let track = tracks.first(where: { $0.id == id }) else { continue }
                store.writeFramework(track.skill, ns.substring(with: m.range(at: 2)))
            }
        }
    }

    // MARK: Talking it over in a chat of its own

    /// The first message of a side chat on a training card: the ability, level and unit, the card,
    /// the question, and the answer with its review when there is one.
    static func discussOpener(_ post: NanoMusePost) -> String {
        let store = NanoMuseGrowthStore.shared
        let track = store.state.tracks.first { $0.id == post.track }
        let response = store.responses[post.id]
        var out = AppLocalized("I want to talk this card from my coach through in depth.") + "\n\n"
        if let track {
            let level = max(post.level, 1)
            let where_ = ["L\(level) " + levelName(level), post.unit].filter { !$0.isEmpty }.joined(separator: " · ")
            out += String(format: AppLocalized("Ability: %@ · %@"), track.displayTitle, where_) + "\n\n"
        }
        out += "**\(post.title)**\n\n" + String(post.body.prefix(1500)) + "\n"
        if !post.prompt.isEmpty { out += "\n" + String(format: AppLocalized("Question: %@"), post.prompt) + "\n" }
        if let r = response {
            out += "\n" + String(format: AppLocalized("My answer: %@"), String(r.answer.prefix(1500))) + "\n"
            if let score = r.score { out += "\n" + String(format: AppLocalized("Review (%d of 4): %@"), score, String((r.feedback ?? "").prefix(1500))) + "\n" }
        }
        out += "\n" + AppLocalized("Start with the one point most worth digging into and the reasoning behind it, then ask me where I want to go from there.")
        return out
    }

    /// The skill an ability's own course is written under.
    static func courseSkill(_ trackId: String) -> String { "growth-\(trackId)" }

    /// The first message of the chat that builds (or rebuilds) an ability's course with the
    /// course framework skill (growth-course-builder): the ability, what the person wants from
    /// it, its course folder and their record so far.
    static func buildOpener(_ trackId: String) -> String? {
        let store = NanoMuseGrowthStore.shared
        guard let track = store.state.tracks.first(where: { $0.id == trackId }) else { return nil }
        var skill = track.skill
        if skill == NanoMuseGrowthStore.generalSkill {
            skill = courseSkill(track.id)
            store.setSkill(track.id, skill)
        }
        let title = track.displayTitle
        let answers = store.responses.values.filter { $0.track == track.id }.count
        let scores = track.scores.suffix(NanoMuseGrowthStore.window).map(String.init).joined(separator: ", ")
        let record = String(format: AppLocalized("now %@, %d answers, recent scores at this level: %@."), "L\(track.level) " + levelName(track.level), answers, scores.isEmpty ? "-" : scores)
        let memory = String(store.read(store.memoryFile).prefix(600))
        let full = memory.isEmpty ? record : record + " " + String(format: AppLocalized("Growth memory: %@"), memory)
        let want = track.about.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? title
        return String(format: AppLocalized("Build the course for “%@” on my Coach page, following the course framework at /var/minis/skills/growth-course-builder/SKILL.md. What I want to be able to do: %@\n\nCourse folder: %@. Skill name: %@. If a course is already there, this is a rebuild.\n\nMy growth record: %@\n\nAsk me two or three questions first, and send me the book list to confirm before you write the book cards."),
                      title, want, "/var/minis/skills/\(skill)/", skill, full)
    }
}

/// The reviews in flight, observable by the cards that show "Reviewing your answer…".
@MainActor
final class NanoMuseGrowthReviews: ObservableObject {
    static let shared = NanoMuseGrowthReviews()
    @Published var grading: Set<String> = []
}

/// What the training draws on, counted for the training settings: the skill behind each ability
/// and the knowledge the cards are made from. Only reads.
@MainActor
enum NanoMuseGrowthSources {
    struct Folder { var name: String; var source: String; var linuxPath: String; var available: Bool }

    /// The knowledge the cards are made from, counted. The iPhone has no Mosaic diary, so its
    /// entries and habits are not among them.
    struct Snapshot {
        var userChars: Int
        var globalChars: Int
        /// Days of the last seven with the agent's daily memory file.
        var diaryDays: Int
        var activeGoals: Int
        var folders: [Folder]
        var answers: Int
        var graded: Int
        var recall: Int
        var recallDue: Int
        var principles: Int
        var observations: Int
    }

    /// The folders mounted under Settings, as the sandbox sees them.
    static func folders() -> [Folder] {
        let manager = MountedFoldersManager.shared
        return manager.entries.map { f in
            Folder(name: f.name, source: f.sourceDisplayName, linuxPath: "/var/minis/mounts/\(f.name)", available: manager.resolvedURL(for: f.id) != nil)
        }
    }

    static func snapshot() -> Snapshot {
        let memory = NanoMuseDirs.memory
        func chars(_ name: String) -> Int {
            ((try? String(contentsOf: memory.appendingPathComponent(name), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        let diary = (0..<7).filter { i in
            guard let date = Calendar.current.date(byAdding: .day, value: -i, to: Date()) else { return false }
            return FileManager.default.fileExists(atPath: memory.appendingPathComponent(NanoMuseDay.key(date) + ".md").path)
        }.count
        let store = NanoMuseGrowthStore.shared
        let responses = store.responses.values
        let principles = store.read(store.principlesFile).components(separatedBy: "\n")
            .filter { $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("- ") }.count
        return Snapshot(userChars: chars("USER.md"), globalChars: chars("GLOBAL.md"), diaryDays: diary,
                        activeGoals: NanoMuseGoalStore.shared.goals.filter { $0.status == .active }.count,
                        folders: folders(), answers: responses.count, graded: responses.filter { $0.score != nil }.count,
                        recall: store.recall.count, recallDue: store.dueRecall().count, principles: principles,
                        observations: store.observations().count)
    }
}
