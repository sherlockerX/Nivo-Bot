//
//  NanoMuseCoach.swift
//  nanoMuse
//
//  The Coach tab's own parts around the cards (NanoMuseFeed.swift): the ability in training at
//  the top, today's recall, the question and answer under a card, the abilities sheet behind
//  the growth card, and the training calendar behind the header's calendar button, a month at a
//  time with the chosen day's cards.
//  Android: ui/feed/GrowthUi.kt, ui/feed/CoachCalendar.kt.
//

import SwiftUI

/// Labels the coach's views share.
@MainActor
enum NanoMuseCoachText {
    /// "Lv2 Foundation · training".
    static func status(_ t: NanoMuseGrowthTrack) -> String {
        let status: String
        switch t.status {
        case NanoMuseGrowthStore.focus: status = AppLocalized("training")
        case NanoMuseGrowthStore.maintain: status = AppLocalized("keeping up")
        case NanoMuseGrowthStore.paused: status = AppLocalized("paused")
        default: status = AppLocalized("up next")
        }
        return NanoMuseGrowthFlow.levelLabel(t.level) + " · " + status
    }

    /// "Today · Monday · 2 Nov 2026" for today, "Sunday · 1 Nov 2026" for any other day. No
    /// morning or evening: the cards of a day are one set, whenever they were written.
    static func dayLabel(_ day: String) -> String {
        guard let date = NanoMuseDay.date(day) else { return day }
        let weekday = date.formatted(.dateTime.weekday(.wide))
        let dateText = date.formatted(date: .abbreviated, time: .omitted)
        return day == NanoMuseDay.key() ? String(format: AppLocalized("Today · %@ · %@"), weekday, dateText) : String(format: AppLocalized("%@ · %@"), weekday, dateText)
    }
}

struct NanoMuseCoachDayTitle: View {
    var day: String
    var body: some View {
        Text(NanoMuseCoachText.dayLabel(day))
            .font(.title2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.top, 8)
    }
}

/// A small round choice: filled when chosen.
struct NanoMuseCoachChip: View {
    var label: String
    var selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? NanoMuseTones.action : NanoMuseTones.fill, in: Capsule())
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Top of the page

/// The ability in training with its level and how far the next level is; the others as small
/// pills; when the ability reaches the goal, the offer to move on. A tap opens the abilities.
struct NanoMuseGrowthCard: View {
    var today: [NanoMusePost]
    var onOpen: () -> Void
    @ObservedObject private var growth = NanoMuseGrowthStore.shared

    var body: some View {
        let state = growth.state
        let focus = state.focus
        let cards = today.filter { !$0.prompt.isEmpty && $0.track != nil }
        let answered = cards.filter { growth.responses[$0.id] != nil }.count
        let streak = growth.streak()
        let others = state.tracks.filter { $0.id != focus?.id }
        VStack(alignment: .leading, spacing: 0) {
            Text(AppLocalized("Now training")).font(.footnote).foregroundStyle(.secondary)
            if let focus {
                HStack(alignment: .firstTextBaseline) {
                    Text(focus.displayTitle).font(.title3.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(NanoMuseGrowthFlow.levelLabel(focus.level))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(NanoMuseTones.action)
                }
                .padding(.top, 4)
                let window = Array(focus.scores.suffix(NanoMuseGrowthStore.window))
                ProgressView(value: Double(window.count), total: Double(NanoMuseGrowthStore.window))
                    .tint(NanoMuseTones.action)
                    .padding(.top, 10)
                let average = window.isEmpty ? "-" : String(format: "%.1f", Double(window.reduce(0, +)) / Double(window.count))
                let progress = focus.challenge ? AppLocalized("Level check unlocked: 3 or more on it raises the level")
                    : String(format: AppLocalized("%d of %d toward the next level, average %@"), window.count, NanoMuseGrowthStore.window, average)
                Text(progress + " · " + String(format: AppLocalized("move on at %@"), NanoMuseGrowthFlow.levelName(state.target)))
                    .font(.caption)
                    .foregroundStyle(focus.challenge ? NanoMuseTones.action : Color.secondary)
                    .padding(.top, 6)
            } else {
                Text(state.tracks.contains { $0.status == NanoMuseGrowthStore.queued }
                     ? AppLocalized("Nothing is in training. Tap here and pick an ability.")
                     : AppLocalized("Every ability has reached its goal. Add a new one or raise the goal."))
                    .font(.subheadline)
                    .padding(.top, 4)
            }
            if !cards.isEmpty || streak > 0 {
                Text([cards.isEmpty ? nil : String(format: AppLocalized("Today %d of %d answered"), answered, cards.count),
                      streak > 0 ? String(format: AppLocalized("%d days in a row"), streak) : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            if !others.isEmpty {
                NanoMuseFlowLayout(spacing: 6) {
                    ForEach(others) { t in
                        Text(t.displayTitle + " · " + NanoMuseCoachText.status(t))
                            .font(.caption)
                            .foregroundStyle(Color.primary.opacity(t.status == NanoMuseGrowthStore.paused ? 0.45 : 0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(NanoMuseTones.fill, in: Capsule())
                    }
                }
                .padding(.top, 12)
            }
            if let done = state.promotion {
                let next = state.next()
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: AppLocalized("%@ has reached %@."), done.displayTitle, NanoMuseGrowthFlow.levelName(done.level)))
                        .font(.subheadline.weight(.semibold))
                    Text(next.map { String(format: AppLocalized("Next up: %@. It keeps getting a review card now and then."), $0.displayTitle) }
                         ?? AppLocalized("Nothing else is queued. Add an ability to keep going."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Button(AppLocalized("Keep going")) { growth.keepGoing() }
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        if next != nil {
                            Button { growth.advance() } label: {
                                Text(AppLocalized("Move on"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 8)
                                    .background(NanoMuseTones.action, in: Capsule())
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NanoMuseTones.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 12)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

/// Today's recall, one point at a time like a flashcard: the question, the answer on a tap,
/// then a self-rating that sets when it comes back. Hidden when nothing is due.
struct NanoMuseRecallCard: View {
    @ObservedObject private var growth = NanoMuseGrowthStore.shared
    @State private var shownId: String?

    var body: some View {
        let due = growth.dueRecall()
        if let item = due.first {
            VStack(alignment: .leading, spacing: 0) {
                Text(String(format: AppLocalized("Recall, %d left today"), due.count)).font(.footnote).foregroundStyle(.secondary)
                Text(item.question).font(.body.weight(.semibold)).padding(.top, 6)
                if shownId != item.id {
                    NanoMuseCoachChip(label: AppLocalized("Show the answer"), selected: false) { shownId = item.id }
                        .padding(.top, 10)
                } else {
                    Text(item.answer)
                        .font(.subheadline)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(NanoMuseTones.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.top, 10)
                    HStack(spacing: 6) {
                        NanoMuseCoachChip(label: AppLocalized("Forgot"), selected: false) { growth.rateRecall(id: item.id, rating: "again") }
                        NanoMuseCoachChip(label: AppLocalized("Vague"), selected: false) { growth.rateRecall(id: item.id, rating: "hard") }
                        NanoMuseCoachChip(label: AppLocalized("Remembered"), selected: true) { growth.rateRecall(id: item.id, rating: "good") }
                    }
                    .padding(.top, 10)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

// MARK: - On a card

/// The ability, level, kind of card and course unit a training card belongs to, above its title.
struct NanoMuseGrowthTag: View {
    var post: NanoMusePost
    @ObservedObject private var growth = NanoMuseGrowthStore.shared

    var body: some View {
        if let id = post.track, let track = growth.state.tracks.first(where: { $0.id == id }) {
            Text([track.displayTitle, NanoMuseGrowthFlow.levelLabel(max(post.level, 1)), NanoMusePost.typeLabel(post.type), post.unit]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption.weight(.medium))
                .foregroundStyle(NanoMuseTones.action)
        }
    }
}

/// Under a training card, its question and the answer box; once answered, the answer, then the
/// review in progress or the score and feedback. A review that could not run waits; a tap retries.
struct NanoMuseGrowthAnswer: View {
    var post: NanoMusePost
    @ObservedObject private var growth = NanoMuseGrowthStore.shared
    @ObservedObject private var reviews = NanoMuseGrowthReviews.shared
    @State private var text = ""

    var body: some View {
        if !post.prompt.isEmpty, post.track != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text(post.prompt).font(.subheadline.weight(.semibold))
                if let response = growth.responses[post.id] {
                    Text(response.answer)
                        .font(.subheadline)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(NanoMuseTones.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if let score = response.score {
                        Text(String(repeating: "●", count: score) + String(repeating: "○", count: max(4 - score, 0)) + "  " + String(format: AppLocalized("%d of 4"), score))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(NanoMuseTones.action)
                        if let feedback = response.feedback, !feedback.isEmpty {
                            NanoMuseInlineMarkdown(text: feedback)
                                .font(.subheadline)
                                .foregroundStyle(Color.primary.opacity(0.86))
                        }
                        // How the card felt steers the next ones within the level.
                        HStack(spacing: 6) {
                            ForEach(["too_easy", "ok", "too_hard"], id: \.self) { value in
                                NanoMuseCoachChip(label: Self.difficultyLabel(value), selected: response.difficulty == value) { growth.setDifficulty(post: post.id, value) }
                            }
                        }
                    } else if reviews.grading.contains(post.id) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(NanoMuseTones.action)
                            Text(AppLocalized("Reviewing your answer…")).font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Button(AppLocalized("Not reviewed yet. Tap to try again.")) { NanoMuseGrowthFlow.review(post.id) }
                            .font(.footnote)
                            .foregroundStyle(NanoMuseTones.action)
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                    }
                } else {
                    TextField(post.type == "action" ? AppLocalized("Do it first, then come back: what you did, how the other side reacted, what came of it.") : AppLocalized("Write your answer first. The review follows."),
                              text: $text, axis: .vertical)
                        .font(.subheadline)
                        .lineLimit(3...10)
                        .padding(10)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(NanoMuseTones.hairline))
                    HStack {
                        Spacer(minLength: 0)
                        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        Button { NanoMuseGrowthFlow.submit(post, answer: text) } label: {
                            Text(AppLocalized("Submit"))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 22)
                                .padding(.vertical, 8)
                                .background(NanoMuseTones.action.opacity(blank ? 0.4 : 1), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(blank)
                    }
                }
            }
            .padding(.leading, 56)
            .padding(.trailing, 4)
            .padding(.top, 10)
        }
    }

    private static func difficultyLabel(_ value: String) -> String {
        switch value {
        case "too_easy": return AppLocalized("Too easy")
        case "too_hard": return AppLocalized("Too hard")
        default: return AppLocalized("About right")
        }
    }
}

// MARK: - Abilities

/// Every ability with its level and status, the order they are trained in, the level at which
/// the next one starts, adding an ability, and the files the coach keeps.
struct NanoMuseGrowthSheet: View {
    /// A chat of its own with this first message: an ability's course is built, or rebuilt, with the agent.
    var onChat: (_ title: String, _ opener: String) -> Void
    @ObservedObject private var growth = NanoMuseGrowthStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var name = ""
    @State private var about = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(AppLocalized("One ability is trained at a time, in this order. Each day brings a theory card and a scenario, and a real-life task once the last one is reported. 6 reviewed answers to scenarios and real-life tasks at the current level, averaging 3 of 4 or better over 4 days, unlock a level check; 3 or more on it raises the level. Theory cards are reviewed and recalled but do not count. An ability you moved on from gets a review card now and then and drops a level if its reviews fall."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(Array(growth.state.tracks.enumerated()), id: \.element.id) { i, t in
                        trackRow(t, first: i == 0)
                    }
                }
                Section {
                    NanoMuseFlowLayout(spacing: 6) {
                        ForEach(2...NanoMuseGrowthStore.maxLevel, id: \.self) { level in
                            NanoMuseCoachChip(label: NanoMuseGrowthFlow.levelLabel(level), selected: level == growth.state.target) { growth.setTarget(level) }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(AppLocalized("Move on to the next ability at"))
                }
                addSection
                Section {
                    // The framework the person keeps from the ability in training, grown by the coach unit by unit.
                    if let f = growth.state.focus {
                        DisclosureGroup(String(format: AppLocalized("My framework: %@"), f.displayTitle)) { fileText(growth.framework(f.skill)) }
                    }
                    DisclosureGroup(AppLocalized("Growth memory")) {
                        let observations = growth.observations()
                        fileText([growth.read(growth.memoryFile),
                                  observations.isEmpty ? "" : "**" + AppLocalized("Observations since the last summary") + "**\n\n" + observations.joined(separator: "\n")]
                            .filter { !$0.isEmpty }.joined(separator: "\n\n"))
                    }
                    DisclosureGroup(AppLocalized("My principles")) { fileText(growth.read(growth.principlesFile)) }
                }
            }
            .navigationTitle(AppLocalized("Abilities"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { dismiss() } } }
        }
    }

    private func build(_ id: String) {
        guard let opener = NanoMuseGrowthFlow.buildOpener(id),
              let title = growth.state.tracks.first(where: { $0.id == id })?.displayTitle else { return }
        dismiss()
        onChat(title, opener)
    }

    private func trackRow(_ t: NanoMuseGrowthTrack, first: Bool) -> some View {
        let books = growth.bookCards(t.skill).count
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(t.displayTitle).font(.body.weight(.medium))
                Spacer(minLength: 8)
                Text(NanoMuseCoachText.status(t))
                    .font(.footnote)
                    .foregroundStyle(t.status == NanoMuseGrowthStore.focus ? NanoMuseTones.action : Color.secondary)
            }
            if let about = t.about { Text(about).font(.caption).foregroundStyle(.secondary) }
            Text(books > 0 ? String(format: AppLocalized("Course: %d book cards"), books) : AppLocalized("No course yet. Tap Build the course to make one with AI."))
                .font(.caption)
                .foregroundStyle(.secondary)
            NanoMuseFlowLayout(spacing: 2) {
                if t.status != NanoMuseGrowthStore.focus && t.status != NanoMuseGrowthStore.paused { action(AppLocalized("Train now")) { growth.setFocus(t.id) } }
                if !first { action(AppLocalized("Move up")) { growth.moveUp(t.id) } }
                if t.status != NanoMuseGrowthStore.focus {
                    if t.status == NanoMuseGrowthStore.paused { action(AppLocalized("Resume")) { growth.setPaused(t.id, false) } }
                    else { action(AppLocalized("Pause")) { growth.setPaused(t.id, true) } }
                }
                action(AppLocalized("Build the course")) { build(t.id) }
                if t.title != nil && t.status != NanoMuseGrowthStore.focus { action(AppLocalized("Remove")) { growth.remove(t.id) } }
            }
        }
        .padding(.vertical, 4)
    }

    private func action(_ label: String, _ run: @escaping () -> Void) -> some View {
        Button(label, action: run)
            .font(.footnote)
            .foregroundStyle(NanoMuseTones.action)
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
    }

    private var addSection: some View {
        Section {
            if !adding {
                Button(AppLocalized("Add an ability")) { adding = true }
                    .foregroundStyle(NanoMuseTones.action)
            } else {
                let blank = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                TextField(AppLocalized("Name"), text: $name)
                    .nmOnChange(of: name) { if $0.count > 30 { name = String($0.prefix(30)) } }
                TextField(AppLocalized("What you want to be able to do"), text: $about, axis: .vertical)
                    .lineLimit(2...6)
                    .nmOnChange(of: about) { if $0.count > 200 { about = String($0.prefix(200)) } }
                Text(AppLocalized("Just add trains it with the general method. Build the course opens a chat: the AI asks where you are, researches and picks 10 books, breaks each one down and writes a course with units by level. It sends you the book list to confirm first."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button(AppLocalized("Just add")) {
                        _ = growth.add(title: name, about: about)
                        reset()
                    }
                    .buttonStyle(.borderless)
                    .disabled(blank)
                    Button(AppLocalized("Build the course with AI")) {
                        let id = growth.add(title: name, about: about)
                        reset()
                        build(id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NanoMuseTones.action)
                    .disabled(blank)
                }
            }
        }
    }

    private func reset() {
        name = ""
        about = ""
        adding = false
    }

    /// The section title already names the file; its own top heading would repeat it.
    @ViewBuilder
    private func fileText(_ raw: String) -> some View {
        let text = raw.components(separatedBy: "\n").drop { $0.hasPrefix("# ") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            Text(AppLocalized("Nothing yet. It fills in as you answer.")).font(.footnote).foregroundStyle(.secondary)
        } else {
            NanoMuseInlineMarkdown(text: text).font(.subheadline).textSelection(.enabled)
        }
    }
}

// MARK: - Training calendar

/// A month at a time, with a dot under every day that has cards; under it the chosen day's cards
/// as the page showed them, with the answers and reviews, still open to an answer. The Coach
/// tab itself shows today only.
struct NanoMuseCoachCalendarSheet: View {
    var onDiscuss: (NanoMusePost) -> Void
    @ObservedObject private var store = NanoMuseFeedStore.shared
    @ObservedObject private var growth = NanoMuseGrowthStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Date
    @State private var month: Date
    @State private var detail: NanoMusePost?

    init(initialDay: String, onDiscuss: @escaping (NanoMusePost) -> Void) {
        self.onDiscuss = onDiscuss
        let cal = Calendar.current
        let day = cal.startOfDay(for: NanoMuseDay.date(initialDay) ?? Date())
        _selected = State(initialValue: day)
        _month = State(initialValue: cal.date(from: cal.dateComponents([.year, .month], from: day)) ?? day)
    }

    var body: some View {
        let byDay = Dictionary(grouping: store.posts, by: \.day)
        let key = NanoMuseDay.key(selected)
        let dayPosts = byDay[key] ?? []
        let answered = dayPosts.filter { growth.responses[$0.id] != nil }.count
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    monthCard(days: Set(byDay.keys))
                    NanoMuseCoachDayTitle(day: key)
                    Text(dayPosts.isEmpty ? AppLocalized("No training cards on this day.")
                         : String(format: dayPosts.count == 1 ? AppLocalized("%d card, %d answered") : AppLocalized("%d cards, %d answered"), dayPosts.count, answered))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                    ForEach(dayPosts) { post in
                        NanoMusePostCard(post: post, onDiscuss: {
                            dismiss()
                            onDiscuss(post)
                        }, onInfo: { detail = post })
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 28)
            }
            .background(NanoMuseTones.canvas.ignoresSafeArea())
            .navigationTitle(AppLocalized("Training calendar"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { dismiss() } } }
            .sheet(item: $detail) { post in NanoMusePostDetail(post: post) }
        }
    }

    /// Older days are pruned from disk (`NanoMuseFeedStore.keepDays`), so the months reach back as far as they do.
    @ViewBuilder
    private func monthCard(days: Set<String>) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
        let reach = cal.date(byAdding: .day, value: -NanoMuseFeedStore.keepDays, to: today) ?? today
        let earliest = cal.date(from: cal.dateComponents([.year, .month], from: reach)) ?? reach
        VStack(spacing: 0) {
            HStack {
                Button { month = cal.date(byAdding: .month, value: -1, to: month) ?? month } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(month <= earliest)
                .accessibilityLabel(Text(AppLocalized("Previous month")))
                Spacer(minLength: 0)
                Text(month.formatted(.dateTime.year().month(.wide))).font(.headline)
                Spacer(minLength: 0)
                Button { month = cal.date(byAdding: .month, value: 1, to: month) ?? month } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(month >= thisMonth)
                .accessibilityLabel(Text(AppLocalized("Next month")))
            }
            .buttonStyle(.borderless)
            .tint(Color.primary)
            monthGrid(today: today, days: days)
            Text(String(format: AppLocalized("Cards are kept for %d days."), NanoMuseFeedStore.keepDays))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .padding(.top, 8)
        }
        .padding(12)
        .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// One month, Monday first; the chosen day filled, today ringed, a dot under days with cards,
    /// the future not selectable.
    @ViewBuilder
    private func monthGrid(today: Date, days: Set<String>) -> some View {
        let cal = Calendar.current
        let leading = (cal.component(.weekday, from: month) + 5) % 7 // weekday: Sunday = 1, so Monday lands on 0
        let length = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let mondayFirst = Array(symbols.dropFirst()) + Array(symbols.prefix(1))
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(mondayFirst.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 28)
                }
            }
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(0..<(((leading + length + 6) / 7) * 7), id: \.self) { cell in
                    let offset = cell - leading
                    if offset >= 0, offset < length, let date = cal.date(byAdding: .day, value: offset, to: month) {
                        dayCell(date, today: today, has: days.contains(NanoMuseDay.key(date)))
                    } else {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
    }

    private func dayCell(_ date: Date, today: Date, has: Bool) -> some View {
        let cal = Calendar.current
        let chosen = cal.isDate(date, inSameDayAs: selected)
        let isToday = cal.isDate(date, inSameDayAs: today)
        let future = date > today
        return Button { selected = date } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: date))")
                    .font(.subheadline)
                    .foregroundStyle(chosen ? Color.white : future ? Color.secondary.opacity(0.5) : Color.primary)
                Circle()
                    .fill(has ? (chosen ? Color.white : NanoMuseTones.action) : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(Circle().fill(chosen ? NanoMuseTones.action : Color.clear))
            .overlay(Circle().stroke(isToday && !chosen ? NanoMuseTones.action : Color.clear, lineWidth: 1))
            .padding(2)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(future)
    }
}
