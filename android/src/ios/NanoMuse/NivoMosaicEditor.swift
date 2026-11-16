import SwiftUI
import PhotosUI

/// 碎片编辑器保留草稿和所见任务版本，正式保存一次性提交所有关联状态。
struct NivoMosaicEditor: View {
    @State var draft: NivoMosaicDraft
    let access: NivoLifeScope
    @ObservedObject var model: NivoMosaicViewModel
    @ObservedObject private var life = NivoLifeModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var isImporting = false
    @State private var isSubmitting = false
    @State private var autosave: Task<Void, Never>?
    @State private var pendingSave: NivoMosaicDraft?
    @State private var operationID = UUID().uuidString
    @State private var errorMessage: String?
    @State private var discardOpen = false

    private var canSave: Bool {
        NivoMosaicRules.canSave(draft)
    }

    private var latestEditableDate: Date {
        guard let original = model.entries.first(where: { $0.id == draft.entryID }) else { return Date() }
        return max(Date(), NivoLifeDay.date(original.day))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red).font(.subheadline) } }
                Section(AppLocalized("Fragment")) {
                    DatePicker(AppLocalized("Date"), selection: Binding(get: { NivoLifeDay.date(draft.day) }, set: { draft.day = NivoLifeDay.value($0) }),
                               in: ...latestEditableDate, displayedComponents: .date)
                    TextEditor(text: $draft.text).frame(minHeight: 140).accessibilityLabel(AppLocalized("Fragment"))
                    Picker(AppLocalized("Mood"), selection: $draft.mood) {
                        Text(AppLocalized("Not selected")).tag(nil as NivoMosaicMood?)
                        ForEach(NivoMosaicMood.allCases, id: \.self) { mood in
                            Text(NivoMosaicDisplay.mood(mood) + " " + NivoMosaicDisplay.moodName(mood)).tag(mood as NivoMosaicMood?)
                        }
                    }
                    if let habitID = draft.habitID, let habit = model.habits.first(where: { $0.id == habitID }) {
                        Toggle(habit.title, isOn: Binding(get: {
                            draft.shouldMarkHabitDone ?? model.snapshot?.habitDays?.contains {
                                $0.habitID == habitID && $0.day == draft.day && $0.status == .done
                            } ?? false
                        }, set: { draft.shouldMarkHabitDone = $0 }))
                    }
                }
                photoSection
                Section(AppLocalized("Shape")) {
                    Picker(AppLocalized("Shape"), selection: Binding(get: { draft.shape ?? "rounded" }, set: { draft.shape = $0 })) {
                        ForEach(["square", "rounded", "circle", "hexagon", "triangle", "heart", "blob1"], id: \.self) { kind in
                            Label(NivoMosaicDisplay.shape(kind), systemImage: NivoMosaicDisplay.shapeSymbol(kind)).tag(kind)
                        }
                    }
                }
                tasksSection
                focusSection
                Section {
                    Text(AppLocalized("Task changes are applied only when you save this fragment."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(AppLocalized("Discard draft"), role: .destructive) { discardOpen = true }.disabled(isImporting)
                }
            }
            .navigationTitle(draft.entryID == nil ? AppLocalized("New fragment") : AppLocalized("Edit fragment"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Close")) { Task { await closeKeepingDraft() } } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSubmitting { ProgressView() }
                    else { Button(AppLocalized("Save")) { Task { await save() } }.disabled(!canSave || isImporting) }
                }
            }
            .disabled(isSubmitting || life.accessScope != access)
            .interactiveDismissDisabled()
            .nmOnChange(of: draft) { value in queueDraft(value) }
            .nmOnChange(of: photo) { item in if let item { Task { await importPhoto(item) } } }
            .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in autosave?.cancel(); dismiss() }
            .onDisappear { autosave?.cancel() }
            .confirmationDialog(AppLocalized("Discard this saved draft?"), isPresented: $discardOpen, titleVisibility: .visible) {
                Button(AppLocalized("Discard draft"), role: .destructive) {
                    Task { await discardDraft() }
                }
            }
        }
    }

    private var photoSection: some View {
        Section(AppLocalized("Photo")) {
            if let path = draft.mediaPath {
                NivoMosaicPhoto(path: path, crop: draft.crop ?? NivoMosaicCrop(), access: access, thumbnail: false)
                    .frame(height: 240).clipShape(NivoMosaicTileShape(kind: draft.shape ?? "rounded"))
                cropSlider(AppLocalized("Horizontal position"), keyPath: \.focusX, range: 0...1)
                cropSlider(AppLocalized("Vertical position"), keyPath: \.focusY, range: 0...1)
                cropSlider(AppLocalized("Zoom"), keyPath: \.zoom, range: 1...4)
                Button(AppLocalized("Remove photo"), role: .destructive) { draft.mediaPath = nil; draft.crop = nil }
            }
            PhotosPicker(selection: $photo, matching: .images) {
                Label(AppLocalized("Choose a photo"), systemImage: "photo.badge.plus")
            }.disabled(isImporting)
            if isImporting { ProgressView(AppLocalized("Importing photo")) }
            Text(AppLocalized("Photos stay on this device. The coach can read your text and whether a photo is attached, not its contents."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func cropSlider(_ title: String, keyPath: WritableKeyPath<NivoMosaicCrop, Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(minWidth: 85, alignment: .leading)
            Slider(value: Binding(get: { (draft.crop ?? NivoMosaicCrop())[keyPath: keyPath] }, set: { value in
                var crop = draft.crop ?? NivoMosaicCrop()
                crop[keyPath: keyPath] = value
                draft.crop = crop
            }), in: range).accessibilityLabel(title)
        }
    }

    private var tasksSection: some View {
        Section(AppLocalized("Link tasks")) {
            if life.tasks.isEmpty { Text(AppLocalized("No tasks here")).foregroundStyle(.secondary) }
            ForEach(life.tasks) { task in
                VStack(alignment: .leading, spacing: 6) {
                    let saved = originalEntry?.taskSnapshots?.first { $0.id == task.id }
                    Toggle(task.title, isOn: Binding(get: { draft.taskIDs.contains(task.id) }, set: { setTask(task, selected: $0) }))
                    if draft.taskIDs.contains(task.id) {
                        // 编辑旧记录时明确展示历史快照，避免把保留历史误解为采用待办的最新状态。
                        if let saved, saved.title != task.title || saved.status != task.status {
                            Text(AppLocalized("Task status when saved") + ": " + saved.title + " · " + saved.status.title)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker(AppLocalized("Task status when saved"), selection: Binding(get: {
                            draft.taskSelections?.first { $0.taskId == task.id }?.requestedStatus
                        }, set: { setTaskStatus(task, status: $0) })) {
                            Text(AppLocalized(saved == nil ? "Keep current status" : "Keep saved status"))
                                .tag(nil as NivoTodoStatus?)
                            Text(AppLocalized("In progress")).tag(NivoTodoStatus.inProgress as NivoTodoStatus?)
                            Text(AppLocalized("Done")).tag(NivoTodoStatus.done as NivoTodoStatus?)
                        }.font(.subheadline)
                        if draft.taskSelections?.first(where: { $0.taskId == task.id })?.requestedStatus == .done {
                            DatePicker(AppLocalized("Completion date"), selection: Binding(get: {
                                let selectedDay = draft.taskSelections?.first { $0.taskId == task.id }?.completedDay ?? draft.day
                                return NivoLifeDay.date(selectedDay)
                            }, set: { setTaskCompletionDay(task.id, day: NivoLifeDay.value($0)) }),
                                       in: ...Date(), displayedComponents: .date)
                        }
                        if let selection = draft.taskSelections?.first(where: { $0.taskId == task.id }),
                           selection.expectedRevision != task.revision,
                           selection.requestedStatus != nil || originalEntry?.taskSnapshots?.contains(where: { $0.id == task.id }) != true {
                            Button(AppLocalized("Review latest task version")) { refreshTask(task) }.font(.caption)
                            Text(AppLocalized("This item changed. Reload before saving.")).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            ForEach(draft.taskIDs.filter { identifier in !life.tasks.contains { $0.id == identifier } }, id: \.self) { identifier in
                historicalLink(title: originalEntry?.taskSnapshots?.first { $0.id == identifier }?.title ?? identifier) {
                    draft.taskIDs.removeAll { $0 == identifier }
                    draft.taskSelections?.removeAll { $0.taskId == identifier }
                }
            }
        }
    }

    private var focusSection: some View {
        Section(AppLocalized("Link focus")) {
            let sessions = life.focusSessions.filter { $0.status == .finished && $0.mode != .rest }
            if sessions.isEmpty { Text(AppLocalized("No completed focus sessions")).foregroundStyle(.secondary) }
            ForEach(sessions) { session in
                Toggle(isOn: Binding(get: { draft.focusIDs.contains(session.id) }, set: { checked in
                    draft.focusIDs.removeAll { $0 == session.id }
                    if checked { draft.focusIDs.append(session.id) }
                })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title)
                        Text(Date(timeIntervalSince1970: Double(session.startedAt) / 1_000).formatted(date: .abbreviated, time: .shortened) + " · " + NivoMosaicDisplay.duration(session.elapsedMs))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(draft.focusIDs.filter { identifier in !sessions.contains { $0.id == identifier } }, id: \.self) { identifier in
                historicalLink(title: originalEntry?.focusSnapshots?.first { $0.id == identifier }?.title ?? identifier) {
                    draft.focusIDs.removeAll { $0 == identifier }
                }
            }
        }
    }

    private var originalEntry: NivoMosaicEntry? { model.entries.first { $0.id == draft.entryID } }

    /// 已删除的任务或时段仍展示旧关联，让用户可以明确移除而不被隐藏引用挡住保存。
    private func historicalLink(title: String, remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            Text(AppLocalized("This item no longer exists. Reload the list.")).font(.caption).foregroundStyle(.secondary)
            Button(AppLocalized("Remove"), role: .destructive, action: remove)
                .accessibilityLabel(AppLocalized("Remove") + ": " + title)
        }
    }

    /// 完成日期可以与日记日期不同，只修改当前草稿，提交前不改变待办。
    private func setTaskCompletionDay(_ identifier: String, day: Int64) {
        guard let index = draft.taskSelections?.firstIndex(where: { $0.taskId == identifier }) else { return }
        draft.taskSelections?[index].completedDay = day
    }

    private func setTask(_ task: NivoTodoTask, selected: Bool) {
        draft.taskIDs.removeAll { $0 == task.id }
        var selections = draft.taskSelections ?? []
        selections.removeAll { $0.taskId == task.id }
        if selected {
            draft.taskIDs.append(task.id)
            selections.append(NivoTodoSelection(taskId: task.id, expectedRevision: task.revision))
        }
        draft.taskSelections = selections
    }

    private func setTaskStatus(_ task: NivoTodoTask, status: NivoTodoStatus?) {
        var selections = draft.taskSelections ?? []
        var selection = selections.first { $0.taskId == task.id } ?? NivoTodoSelection(taskId: task.id, expectedRevision: task.revision)
        selection.requestedStatus = status
        selection.completedDay = status == .done ? selection.completedDay ?? draft.day : nil
        selections.removeAll { $0.taskId == task.id }
        selections.append(selection)
        draft.taskSelections = selections
    }

    private func refreshTask(_ task: NivoTodoTask) {
        var selections = draft.taskSelections ?? []
        selections.removeAll { $0.taskId == task.id }
        // 用户重新核对之后清除待执行状态，需要再次明确选择。
        selections.append(NivoTodoSelection(taskId: task.id, expectedRevision: task.revision))
        draft.taskSelections = selections
    }

    private func queueDraft(_ value: NivoMosaicDraft) {
        guard !isSubmitting else { return }
        pendingSave = nil
        operationID = UUID().uuidString
        let previous = autosave
        previous?.cancel()
        var captured = value
        captured.updatedAt = NivoMosaicViewModel.now
        autosave = Task { @MainActor in
            do {
                await previous?.value
                try await Task.sleep(nanoseconds: 600_000_000)
                try Task.checkCancellation()
                try await model.saveDraft(captured, scope: access)
            } catch is CancellationError { }
            catch { errorMessage = NivoLifeModel.message(error) }
        }
    }

    private func finishAutosave() async {
        let pending = autosave
        autosave = nil
        pending?.cancel()
        await pending?.value
    }

    private func save() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        await finishAutosave()
        if pendingSave == nil {
            var candidate = draft
            candidate.updatedAt = NivoMosaicViewModel.now
            pendingSave = candidate
        }
        guard let candidate = pendingSave else { return }
        if await model.save(candidate, operationID: operationID, scope: access) { dismiss() }
        else { errorMessage = model.errorMessage }
    }

    private func closeKeepingDraft() async {
        guard !isSubmitting, !isImporting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        await finishAutosave()
        do {
            var candidate = draft
            candidate.updatedAt = NivoMosaicViewModel.now
            try await model.saveDraft(candidate, scope: access)
            dismiss()
        } catch { errorMessage = NivoLifeModel.message(error) }
    }

    /// 放弃期间冻结输入并排空自动保存，避免删除后迟到写入重新生成草稿。
    private func discardDraft() async {
        guard !isSubmitting, !isImporting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        await finishAutosave()
        if await model.discard(draft, scope: access) { dismiss() }
        else { errorMessage = model.errorMessage }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false; photo = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), life.accessScope == access else {
                throw NivoLifeError.accountChanged
            }
            let path = try await NivoMosaicMediaStore.shared.add(data, scope: access)
            guard life.accessScope == access else { return }
            draft.mediaPath = path
            draft.crop = NivoMosaicCrop()
        } catch { errorMessage = NivoLifeModel.message(error) }
    }
}
