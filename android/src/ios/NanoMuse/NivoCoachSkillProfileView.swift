import SwiftUI

/// 技能档案汇总今日任务、原话证据、训练计划、材料及课次历史。
struct NivoCoachSkillProfileView: View {
    let track: NivoCoachTrack
    let state: NivoCoachState
    var onStart: (Bool, Int, String) -> Void
    var onOpenLesson: (NivoCoachSession) -> Void
    var onOpenSource: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 15
    @State private var need = ""
    @State private var didLoadOptions = false

    private var isBlocked: Bool {
        track.paused || track.course.needsCriteriaReview || track.course.units.contains(where: \.needsCriteriaReview)
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let now = Int64(timeline.date.timeIntervalSince1970 * 1_000)
                let zone = TimeZone.current
                let today = NivoCoachSkillProfile.today(state, courseID: track.id,
                    day: NivoCoachDay.key(now, zone: zone), zone: zone)
                List {
                    todaySection(today, next: NivoCoachSkillProfile.nextStep(state, courseID: track.id, now: now))
                    performanceSection(NivoCoachSkillProfile.performance(state, courseID: track.id, now: now))
                    planSection
                    materialSection(today)
                    historySection
                }
                .onAppear {
                    guard !didLoadOptions else { return }
                    didLoadOptions = true
                    if let plan = today.plan { minutes = plan.minutes; need = plan.need }
                }
            }
            .navigationTitle(track.course.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { dismiss() } } }
        }
    }

    private func todaySection(_ today: NivoCoachToday, next: NivoCoachNextStep) -> some View {
        Section(AppLocalized("Today's training")) {
            if let plan = attachedPlan(today) {
                Text(plan.task).font(.headline)
                Text(plan.reason.isEmpty ? nextReason(plan.nextKind) : plan.reason).foregroundStyle(.secondary)
                Text(String(format: AppLocalized(plan.source == "base" ? "Basic exercise, %d minutes" : "Coach plan, %d minutes"), plan.minutes))
                    .font(.caption).foregroundStyle(.secondary)
                if !plan.need.isEmpty { Text(plan.need).font(.caption) }
            } else {
                Text(nextReason(next.kind)).foregroundStyle(.secondary)
            }
            if today.status == .earlierUnfinished {
                Text(AppLocalized("An earlier lesson is unfinished. You can resume it or set it aside and start today."))
                    .font(.subheadline)
            }
            if today.status == .done {
                DisclosureGroup(AppLocalized("View today's result")) { lessonRows(Array(today.lessons.reversed())) }
            }
            if today.status != .inProgress, !isBlocked {
                DisclosureGroup(AppLocalized("Adjust time and material")) {
                    Picker(AppLocalized("Minutes"), selection: $minutes) {
                        ForEach(Array(Set([5, 10, 15, 25, 40, minutes])).sorted(), id: \.self) { Text(String($0)).tag($0) }
                    }
                    TextField(AppLocalized("Your situation or material (optional)"), text: $need, axis: .vertical)
                        .nmOnChange(of: need) { entered in
                            if entered.utf16.count > 600 { need = NivoCoachLessonPlanRules.trimmedNeed(entered) }
                        }
                }
            }
            if !isBlocked {
                Button(primaryTitle(today.status)) { onStart(false, minutes, need) }
                    .buttonStyle(.borderedProminent)
                if today.status == .earlierUnfinished {
                    Button(AppLocalized("Start today's training")) { onStart(true, minutes, need) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func attachedPlan(_ today: NivoCoachToday) -> NivoCoachLessonPlan? {
        state.plans?.first(where: { $0.id == today.openLesson?.planID }) ?? today.plan
    }

    private func primaryTitle(_ status: NivoCoachTodayState) -> String {
        switch status {
        case .notStarted: return AppLocalized("Start today's training")
        case .inProgress: return AppLocalized("Continue learning")
        case .earlierUnfinished: return AppLocalized("Continue that lesson")
        case .done: return AppLocalized("Practise more today")
        }
    }

    private func nextReason(_ kind: String) -> String {
        switch kind {
        case "new_scenario": return AppLocalized("Practise the same skill in a new situation.")
        case "independent_first": return AppLocalized("Try a smaller task without hints.")
        case "delayed_review": return AppLocalized("Your delayed review is ready.")
        case "wait_review": return AppLocalized("Practise a new situation while you wait for the delayed review.")
        case "real_action": return AppLocalized("A real-world action is waiting for your report.")
        case "disputed": return AppLocalized("Try a task that can clarify the disputed assessment.")
        case "advance": return AppLocalized("Move to the next unit")
        case "continue": return AppLocalized("Continue from your last answer.")
        default: return AppLocalized("Start with a short exercise to see what you already know.")
        }
    }

    private func performanceSection(_ items: [NivoCoachPerformanceItem]) -> some View {
        Section(AppLocalized("Current performance")) {
            ForEach(items) { item in
                if let source = item.evidence {
                    DisclosureGroup {
                        Text(source.quote).textSelection(.enabled)
                        if !source.reason.isEmpty { Text(source.reason).foregroundStyle(.secondary) }
                        Text(date(source.at)).font(.caption)
                        if !source.chatSessionId.isEmpty, !source.messageId.isEmpty {
                            Button(AppLocalized("Open conversation")) { onOpenSource(source.chatSessionId, source.messageId) }
                        }
                    } label: { performanceLabel(item) }
                } else {
                    performanceLabel(item)
                    if let due = item.dueAt, item.status == "waiting" { Text(date(due)).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func performanceLabel(_ item: NivoCoachPerformanceItem) -> some View {
        let title = item.dimension == "delayed" ? AppLocalized("Delayed review") :
            (item.dimension == "application" ? AppLocalized("Application evidence") : AppLocalized("Understanding evidence"))
        let description: String
        switch item.status {
        case "independent": description = AppLocalized("Evidence recorded")
        case "hinted": description = AppLocalized("Practised with support")
        case "attempted": description = AppLocalized("Practice records")
        case "due": description = AppLocalized("Your delayed review is ready.")
        case "waiting": description = AppLocalized("Waiting for delayed review")
        default: description = AppLocalized("Still needs evidence")
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(description).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var planSection: some View {
        Section(AppLocalized("Training plan")) {
            ForEach(track.course.units) { unit in
                Label(unit.title, systemImage: track.demonstrated.contains(unit.id) ? "checkmark.seal.fill" :
                    (unit.id == track.currentUnitID ? "arrow.right.circle" : "circle"))
            }
            let plans = (state.plans ?? []).filter { $0.courseId == track.id }
            if !plans.isEmpty {
                DisclosureGroup(AppLocalized("Earlier plans")) {
                    ForEach(plans.reversed()) { plan in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plan.task)
                            Text(plan.localDate).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func materialSection(_ today: NivoCoachToday) -> some View {
        Section(AppLocalized("Knowledge and material")) {
            if let unit = track.course.units.first(where: { $0.id == track.currentUnitID }) {
                if !unit.method.isEmpty { Text(unit.method) }
                if !unit.source.isEmpty { Text(unit.source).font(.caption).foregroundStyle(.secondary) }
            }
            if let plan = attachedPlan(today) {
                ForEach(Array(plan.concepts.enumerated()), id: \.offset) { item in Text(item.element) }
                ForEach(Array(plan.materials.enumerated()), id: \.offset) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.element.title)
                        Text(originTitle(item.element.origin)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var historySection: some View {
        Section(AppLocalized("Lesson archive")) {
            let lessons = state.sessions.filter { $0.course.id == track.id }
            let byDay = Dictionary(grouping: lessons, by: { NivoCoachDay.key($0) ?? "" })
            ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                DisclosureGroup(day.isEmpty ? AppLocalized("Earlier") : day) {
                    lessonRows(Array((byDay[day] ?? []).reversed()))
                }
            }
        }
    }

    private func lessonRows(_ lessons: [NivoCoachSession]) -> some View {
        ForEach(lessons) { lesson in
            Button { onOpenLesson(lesson) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(lesson.course.units.first(where: { $0.id == lesson.unitID })?.title ?? lesson.course.title)
                    Text(NivoCoachDisplay.status(lesson.status)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func originTitle(_ origin: String) -> String {
        switch origin {
        case "course": return AppLocalized("From the course")
        case "user": return AppLocalized("Your material")
        case "self_authored": return AppLocalized("Written for practice")
        default: return AppLocalized("Unverified")
        }
    }

    private func date(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000).formatted(date: .abbreviated, time: .shortened)
    }
}
