import SwiftUI

/// 习惯管理保留历史计划，暂停和归档只影响此后的日期。
struct NivoMosaicHabitsView: View {
    @ObservedObject var model: NivoMosaicViewModel
    let access: NivoLifeScope
    @Environment(\.dismiss) private var dismiss
    @State private var editing: NivoMosaicHabit?
    @State private var archiving: NivoMosaicHabit?

    var body: some View {
        NavigationStack {
            List {
                Section(AppLocalized("Habits")) {
                    ForEach(model.habits.filter { $0.archivedDay == nil }) { habit in row(habit) }
                    if model.habits.allSatisfy({ $0.archivedDay != nil }) { Text(AppLocalized("No habits yet")).foregroundStyle(.secondary) }
                }
                let archived = model.habits.filter { $0.archivedDay != nil }
                if !archived.isEmpty {
                    Section(AppLocalized("Archived habits")) {
                        ForEach(archived) { habit in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(habit.title)
                                if let day = habit.archivedDay {
                                    Text(NivoLifeDay.date(day).formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section { Text(AppLocalized("Schedule changes apply from today. Earlier days keep their original plan.")).font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle(AppLocalized("Habits"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Close")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = NivoMosaicHabit(ownerKey: access.ownerKey, id: "", title: "", weekdays: Set(1...7), createdAt: NivoMosaicViewModel.now)
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel(AppLocalized("Add habit"))
                }
            }
            .sheet(item: $editing) { habit in NivoMosaicHabitEditor(habit: habit, model: model, access: access) }
            .confirmationDialog(AppLocalized("Archive this habit?"), isPresented: Binding(get: { archiving != nil }, set: { if !$0 { archiving = nil } }), titleVisibility: .visible) {
                if let selected = archiving {
                    Button(AppLocalized("Archive"), role: .destructive) {
                        var habit = selected
                        habit.archivedDay = NivoLifeDay.value()
                        Task { _ = await model.saveHabit(habit, scope: access) }
                    }
                }
            }
            .disabled(model.isSaving)
            .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in dismiss() }
        }
    }

    private func row(_ habit: NivoMosaicHabit) -> some View {
        let weekdays = NivoMosaicRules.weekdays(habit, on: NivoLifeDay.value())
        return HStack(spacing: 12) {
            NivoMosaicTileShape(kind: habit.shape ?? "rounded").fill(NanoMuseTones.action.opacity(0.20)).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(habit.title)
                Text(weekdays.isEmpty ? AppLocalized("Paused") : weekdaySummary(weekdays)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button(AppLocalized("Edit")) { editing = habit }
                Button(weekdays.isEmpty ? AppLocalized("Resume") : AppLocalized("Pause")) {
                    var changed = habit
                    changed.weekdays = weekdays.isEmpty
                        ? (habit.schedules ?? []).last(where: { !$0.weekdays.isEmpty })?.weekdays ?? Set(1...7) : []
                    Task { _ = await model.saveHabit(changed, scope: access) }
                }
                Button(AppLocalized("Archive"), role: .destructive) { archiving = habit }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
            .accessibilityLabel(AppLocalized("More options") + ", " + habit.title)
        }
    }

    private func weekdaySummary(_ weekdays: Set<Int>) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        return weekdays.sorted().map { symbols[$0 % 7] }.joined(separator: " · ")
    }
}

/// 习惯编辑保留原版本，保存冲突时继续留在表单供核对。
private struct NivoMosaicHabitEditor: View {
    @State var habit: NivoMosaicHabit
    @ObservedObject var model: NivoMosaicViewModel
    let access: NivoLifeScope
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(AppLocalized("Habit")) {
                    TextField(AppLocalized("Title"), text: $habit.title)
                    Picker(AppLocalized("Shape"), selection: Binding(get: { habit.shape ?? "rounded" }, set: { habit.shape = $0 })) {
                        ForEach(["rounded", "circle", "hexagon", "triangle", "heart", "blob1"], id: \.self) { kind in
                            Text(NivoMosaicDisplay.shape(kind)).tag(kind)
                        }
                    }
                }
                Section(AppLocalized("Repeat on")) {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(Calendar.current.weekdaySymbols[day % 7], isOn: Binding(get: { habit.weekdays.contains(day) }, set: { value in
                            if value { habit.weekdays.insert(day) } else { habit.weekdays.remove(day) }
                        }))
                    }
                    if habit.weekdays.isEmpty { Text(AppLocalized("Paused")).font(.caption).foregroundStyle(.secondary) }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle(habit.id.isEmpty ? AppLocalized("Add habit") : AppLocalized("Edit habit"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Save")) {
                        Task {
                            if await model.saveHabit(habit, scope: access) { dismiss() }
                            else { errorMessage = model.errorMessage }
                        }
                    }.disabled(habit.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSaving)
                }
            }.interactiveDismissDisabled(model.isSaving)
        }
    }
}

/// 回收站保留七天，恢复不会重演此前的待办完成操作。
struct NivoMosaicBinView: View {
    @ObservedObject var model: NivoMosaicViewModel
    let access: NivoLifeScope
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(AppLocalized("Deleted fragments are kept for seven days. Restoring a fragment does not change task progress."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.bin) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.text.isEmpty ? AppLocalized("Attached photo") : entry.text).lineLimit(3)
                        Text(NivoLifeDay.date(entry.day).formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                        Button(AppLocalized("Restore")) { Task { _ = await model.changeEntry(entry, restore: true, scope: access) } }
                    }
                }
                if model.bin.isEmpty { Text(AppLocalized("No deleted fragments")).foregroundStyle(.secondary) }
            }.navigationTitle(AppLocalized("Recently deleted"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { dismiss() } } }
                .disabled(model.isSaving)
                .task { await model.sweep(scope: access) }
                .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in dismiss() }
        }
    }
}
