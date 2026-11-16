import SwiftUI

/// 按真实课次和回合时间查询学习记录，不用课程进度推算不存在的训练日期。
struct NivoCoachCalendarView: View {
    var sessions: [NivoCoachSession]
    var onSelect: (NivoCoachSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Date()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DatePicker(AppLocalized("Training calendar"), selection: $selected, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
                Section(selected.formatted(date: .complete, time: .omitted)) {
                    let matches = lessonsForSelectedDay
                    if matches.isEmpty { Text(AppLocalized("No lessons on this day")).foregroundStyle(.secondary) }
                    ForEach(matches) { session in
                        Button { onSelect(session) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.course.title).font(.headline).foregroundStyle(.primary)
                                Text(session.course.units.first { $0.id == session.unitID }?.title ?? session.unitID)
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Text(NivoCoachDisplay.status(session.status)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle(AppLocalized("Training calendar"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { dismiss() } } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in dismiss() }
    }

    private var lessonsForSelectedDay: [NivoCoachSession] {
        let day = NivoLifeDay.value(selected)
        return sessions.filter { session in
            let moments = [session.startedAt, session.endedAt] + session.turns.map(\.createdAt)
            return moments.contains { $0 > 0 && NivoLifeDay.value(Date(timeIntervalSince1970: Double($0) / 1_000)) == day }
        }.sorted { $0.startedAt > $1.startedAt }
    }
}

/// 草案只展示内容与来源；确认激活仍通过主聊天的当前用户回合完成。
struct NivoCoachDraftDetail: View {
    let draft: NivoCoachDraft
    var onDiscuss: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(draft.text).textSelection(.enabled)
                    Text(draft.status == "proposed" ? AppLocalized("Awaiting your confirmation") : AppLocalized("Course draft"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if draft.sourceStatus == "unverified" {
                        Label(AppLocalized("Sources need verification"), systemImage: "exclamationmark.triangle")
                    }
                    Button(AppLocalized("Discuss in the main chat"), action: onDiscuss)
                }
                if let course = draft.course {
                    Section(course.title) {
                        ForEach(course.units) { unit in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(unit.title).font(.headline)
                                Text(unit.focus)
                                Text(unit.method).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(AppLocalized("Course draft"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { dismiss() } } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in dismiss() }
    }
}
