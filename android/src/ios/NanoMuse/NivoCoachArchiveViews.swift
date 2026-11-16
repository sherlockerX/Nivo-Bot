import SwiftUI

/// 弹层保留打开时的账户代次；相同ID的恢复档案不能接管旧弹层回调。
struct NivoCoachSheetTarget<Item: Identifiable>: Identifiable {
    let id = UUID()
    let item: Item
    let scope: NivoLifeScope
}

/// 状态文案只表达已保存的事实，结束课次不改写为掌握。
enum NivoCoachDisplay {
    static func status(_ value: String) -> String {
        switch value {
        case "active": return AppLocalized("In progress")
        case "paused": return AppLocalized("Paused")
        case "complete": return AppLocalized("Lesson completed")
        case "waiting_real", "planned": return AppLocalized("Awaiting real-world practice")
        case "deferred": return AppLocalized("Deferred")
        case "reported": return AppLocalized("Reported by you")
        default: return AppLocalized("Archived")
        }
    }
}

/// 课次按ID读取当前投影，来源失效或课程更新后不继续展示弹层打开时的旧结论。
struct NivoCoachLessonDetail: View {
    let lessonID: String
    let state: NivoCoachState
    var onOpenChat: (String, String?) -> Void
    var loadError: String?
    var onRetry: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let loadError {
                    Section {
                        Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        Button(AppLocalized("Retry"), action: onRetry)
                    }
                }
                if let lesson = state.sessions.first(where: { $0.id == lessonID }) {
                    heading(lesson)
                    NivoCoachLessonSummarySection(lesson: lesson, onOpenChat: onOpenChat)
                    if loadError == nil, isCurrentCourse(lesson), lesson.teachingProtocol == "topic-v3", !lesson.topicID.isEmpty {
                        NivoCoachProgressSection(progress: NivoCoachTeaching.progress(state, topicID: lesson.topicID))
                    }
                    NivoCoachEvidenceSection(lesson: lesson, onOpenChat: onOpenChat)
                    NivoCoachActionsSection(actions: state.actions.filter { $0.sessionID == lesson.id },
                                           chatID: lesson.chatSessionID, onOpenChat: onOpenChat)
                    Section {
                        DisclosureGroup(AppLocalized("Lesson dialogue")) {
                            ForEach(lesson.turns) { turn in
                                NivoCoachArchivedTurn(turn: turn, lesson: lesson, onOpenChat: onOpenChat)
                            }
                        }
                    }
                } else if loadError == nil {
                    Text(AppLocalized("This record is no longer available.")).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(AppLocalized("Lesson archive"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { dismiss() } } }
        }
    }

    private func heading(_ lesson: NivoCoachSession) -> some View {
        Section {
            Text(state.topics.first(where: { $0.id == lesson.topicID })?.title ?? lesson.course.title).font(.headline)
            Text(lesson.course.title).font(.subheadline).foregroundStyle(.secondary)
            Text(lesson.course.units.first(where: { $0.id == lesson.unitID })?.title ?? lesson.unitID)
            Text(NivoCoachDisplay.status(lesson.status)).foregroundStyle(.secondary)
            if !isCurrentCourse(lesson) {
                Label(AppLocalized("This record used earlier requirements. It remains available but does not count toward the updated unit."),
                      systemImage: "clock.arrow.circlepath").font(.footnote).foregroundStyle(.secondary)
            }
            if !lesson.chatSessionID.isEmpty,
               state.topics.first(where: { $0.id == lesson.topicID })?.status != "archived" {
                Button(AppLocalized("Open conversation")) { onOpenChat(lesson.chatSessionID, nil) }
            }
            if !lesson.draft.isEmpty {
                DisclosureGroup(AppLocalized("Saved unsent draft")) { Text(lesson.draft).textSelection(.enabled) }
            }
        }
    }

    private func isCurrentCourse(_ lesson: NivoCoachSession) -> Bool {
        !lesson.requiresCourseReview && state.tracks.contains {
            $0.id == lesson.course.id && $0.course.version == lesson.course.version && !$0.course.needsCriteriaReview
                && !$0.course.units.contains(where: \.needsCriteriaReview)
        }
    }
}

/// 课程单元展示学习顺序和独立标准，现实任务额外标明完成证据要求。
struct NivoCoachCourseDetail: View {
    let course: NivoCoachCourse
    var demonstrated: Set<String> = []
    var onStart: (NivoCoachUnit) -> Void
    var onReview: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var needsReview: Bool { course.needsCriteriaReview || course.units.contains(where: \.needsCriteriaReview) }

    var body: some View {
        NavigationStack {
            List {
                if needsReview {
                    Section {
                        Label(AppLocalized("Course criteria need review before training"), systemImage: "exclamationmark.triangle")
                        Button(AppLocalized("Review requirements with AI"), action: onReview)
                    }
                }
                ForEach(course.units) { unit in
                  VStack(alignment: .leading, spacing: 10) {
                    Label(unit.title, systemImage: demonstrated.contains(unit.id) ? "checkmark.seal.fill" : "circle")
                        .font(.headline)
                    Text(unit.focus)
                    Text(unit.method).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(unit.criteria, id: \.id) { criterion in
                        Label(criterion.description, systemImage: criterion.requiresRealAction ? "figure.walk" : "checkmark.circle")
                            .font(.subheadline)
                    }
                    Button(AppLocalized("Start unit")) { onStart(unit) }
                        .buttonStyle(.borderedProminent).disabled(needsReview)
                  }.padding(.vertical, 6)
                }
            }
            .navigationTitle(course.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { dismiss() } } }
        }
    }
}
