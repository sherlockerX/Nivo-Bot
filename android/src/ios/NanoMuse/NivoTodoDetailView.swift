import SwiftUI

/// 任务详情汇总用户保存的状态、专注及碎片；编辑有独立草稿，不因跳转而丢失。
struct NivoTodoDetailView: View {
    let taskID: String
    let access: NivoLifeScope
    @ObservedObject var model: NivoLifeModel
    var onOpenFocus: (NivoLifeItemTarget) -> Void
    var onOpenFragment: (NivoLifeItemTarget) -> Void
    @StateObject private var mosaic = NivoMosaicViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var editing: NivoTodoTask?
    @State private var isDeleting = false
    @State private var isCompleting = false
    @State private var completionDate = Date()
    @State private var operationID = UUID().uuidString
    @State private var lastOperation = ""

    private var task: NivoTodoTask? {
        guard model.accessScope == access else { return nil }
        return model.tasks.first { $0.id == taskID && $0.ownerKey == access.ownerKey }
    }

    var body: some View {
        NavigationStack {
            List {
                if let task {
                    taskInformation(task)
                    focusHistory(task)
                    statusControls(task)
                    fragments(task)
                    if let error = model.errorMessage {
                        Section {
                            Text(error).foregroundStyle(.red)
                            Button(AppLocalized("Reload saved task")) { Task { await model.refresh() } }
                        }
                    }
                    Section {
                        Button(AppLocalized("Delete"), role: .destructive) { isDeleting = true }
                            .disabled(model.isBusy)
                    }
                } else {
                    Text(AppLocalized("This item no longer exists. Reload the list.")).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(AppLocalized("Task details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Close")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let task { Button(AppLocalized("Edit")) { editing = task }.disabled(model.isBusy) }
                }
            }
            .sheet(item: $editing) { NivoTodoEditor(task: $0, access: access, model: model) }
            .task(id: access) { await mosaic.load() }
            .onReceive(NotificationCenter.default.publisher(for: .nivoMosaicStateChanged)) { _ in
                Task { await mosaic.load() }
            }
            .nmOnChange(of: model.accessScope) { if $0 != access { editing = nil; dismiss() } }
            .confirmationDialog(AppLocalized("Delete this task?"), isPresented: $isDeleting, titleVisibility: .visible) {
                Button(AppLocalized("Delete"), role: .destructive) { Task { await delete() } }
            } message: { Text(AppLocalized("Linked fragments and focus records are kept.")) }
        }
    }

    private func taskInformation(_ task: NivoTodoTask) -> some View {
        Section {
            Text(task.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            Text(task.status.title).font(.subheadline).foregroundStyle(.secondary)
            if !task.notes.isEmpty { Text(task.notes).textSelection(.enabled) }
            if !task.groupName.isEmpty { Label(task.groupName, systemImage: "folder") }
            if !task.tags.isEmpty { Label(task.tags.joined(separator: " · "), systemImage: "tag") }
            if task.isImportant { Label(AppLocalized("Important"), systemImage: "star") }
            if task.isUrgent { Label(AppLocalized("Urgent"), systemImage: "bolt") }
            if let day = task.scheduledDay { dateRow("Scheduled date", day: day) }
            if let day = task.dueDay { dateRow("Due date", day: day) }
            if let day = task.completedDay { dateRow("Completion date", day: day) }
        }
    }

    private func focusHistory(_ task: NivoTodoTask) -> some View {
        let sessions = NivoLifeEntryRules.finishedFocus(for: task, sessions: model.focusSessions)
        return Section(AppLocalized("Focus")) {
            Button {
                onOpenFocus(NivoLifeItemTarget(id: task.id, scope: access))
            } label: { Label(AppLocalized("Focus on this task"), systemImage: "timer") }
                .disabled(model.isBusy || (task.status == .done && model.activeFocus?.taskId != task.id))
            if !sessions.isEmpty {
                LabeledContent(AppLocalized("Focused time"), value: NivoFocusFormat.clock(sessions.reduce(0) { $0 + $1.elapsedMs }))
                ForEach(Array(sessions.prefix(3))) { session in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Date(timeIntervalSince1970: Double(session.startedAt) / 1_000), style: .date)
                            .font(.subheadline)
                        HStack {
                            Text(Date(timeIntervalSince1970: Double(session.startedAt) / 1_000), style: .time)
                            Text("→")
                            Text(Date(timeIntervalSince1970: Double(session.endedAt ?? session.startedAt) / 1_000), style: .time)
                            Spacer()
                            Text(NivoFocusFormat.clock(session.elapsedMs)).monospacedDigit()
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func statusControls(_ task: NivoTodoTask) -> some View {
        Section(AppLocalized("Status")) {
            ForEach(NivoTodoStatus.allCases, id: \.rawValue) { status in
                Button {
                    if status == .done { isCompleting = true }
                    else { Task { await changeStatus(status) } }
                } label: {
                    HStack {
                        Text(status.title)
                        Spacer()
                        if status == task.status { Image(systemName: "checkmark") }
                    }
                }.disabled(model.isBusy || status == task.status)
            }
            if isCompleting {
                DatePicker(AppLocalized("Completion date"), selection: $completionDate, in: ...Date(), displayedComponents: .date)
                Button(AppLocalized("Complete task")) {
                    Task { await changeStatus(.done, day: NivoLifeDay.value(completionDate)) }
                }.disabled(model.isBusy)
                Button(AppLocalized("Cancel")) { isCompleting = false }.disabled(model.isBusy)
            }
        }
    }

    private func fragments(_ task: NivoTodoTask) -> some View {
        let entries = NivoLifeEntryRules.linkedFragments(for: task, entries: mosaic.entries)
        return Section(AppLocalized("Linked fragments")) {
            if mosaic.isLoading { ProgressView() }
            else if let error = mosaic.loadError {
                Text(error).foregroundStyle(.secondary)
                Button(AppLocalized("Retry")) { Task { await mosaic.load() } }
            } else if entries.isEmpty { Text(AppLocalized("No linked fragments yet")).foregroundStyle(.secondary) }
            else {
                ForEach(entries) { entry in
                    Button { onOpenFragment(NivoLifeItemTarget(id: entry.id, scope: access)) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(NivoLifeDay.date(entry.day), style: .date).font(.caption).foregroundStyle(.secondary)
                            Text(entry.text.isEmpty ? AppLocalized("Fragment without text") : entry.text)
                                .lineLimit(4).foregroundStyle(.primary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.disabled(model.isBusy)
                }
            }
        }
    }

    private func dateRow(_ title: String.LocalizationValue, day: Int64) -> some View {
        LabeledContent(AppLocalized(title)) { Text(NivoLifeDay.date(day), style: .date) }
    }

    private func changeStatus(_ status: NivoTodoStatus, day: Int64? = nil) async {
        guard let task else { return }
        let signature = "status:\(task.revision):\(status.rawValue):\(day.map(String.init) ?? "")"
        let result = await model.setStatusResult(task, status: status, completedDay: day,
            operationID: operation(for: signature), scope: access)
        if result != nil { isCompleting = false }
    }

    private func delete() async {
        guard let task else { return }
        let result = await model.deleteTaskResult(task, operationID: operation(for: "delete:\(task.revision)"), scope: access)
        if result != nil { dismiss() }
    }

    private func operation(for signature: String) -> String {
        if signature != lastOperation { operationID = UUID().uuidString; lastOperation = signature }
        return operationID
    }
}
