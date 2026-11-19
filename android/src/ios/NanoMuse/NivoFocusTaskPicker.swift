import SwiftUI

/// 在开始专注前搜索或保存待办，创建成功只选择任务，不启动计时。
struct NivoFocusTaskPicker: View {
    @ObservedObject var model: NivoLifeModel
    let access: NivoLifeScope
    @Binding var selectedID: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var group = ""
    @State private var lastDraft: NivoTodoTask?
    @State private var operationID = UUID().uuidString
    @State private var isSaving = false

    var body: some View {
        let choices = NivoFocusTaskChoices(tasks: model.tasks, owner: access.ownerKey, query: query)
        NavigationStack {
            List {
                Button(AppLocalized("No linked task")) { pick("") }
                if choices.canCreate {
                    Section(AppLocalized("New task")) {
                        Picker(AppLocalized("Group"), selection: $group) {
                            Text(AppLocalized("Ungrouped")).tag("")
                            ForEach(groups, id: \.self) { Text($0).tag($0) }
                        }
                        Button { create(choices) } label: { Label(choices.title, systemImage: "plus.circle") }
                    }
                }
                Section(AppLocalized("Tasks")) {
                    if choices.matches.isEmpty { Text(AppLocalized("No results")).foregroundStyle(.secondary) }
                    ForEach(choices.matches) { task in
                        Button { pick(task.id) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(task.title)
                                    if !task.groupName.isEmpty { Text(task.groupName).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if selectedID == task.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(AppLocalized("Search")))
            .disabled(isSaving || model.isBusy || model.accessScope != access)
            .navigationTitle(AppLocalized("Link task")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Cancel")) { dismiss() }.disabled(isSaving) } }
            .interactiveDismissDisabled(isSaving)
            .nmOnChange(of: model.accessScope) { if $0 != access { dismiss() } }
        }
    }

    private var groups: [String] {
        let catalogue = model.categories.filter { $0.kind == .group }.map(\.name)
        let taskGroups = model.tasks.filter { $0.ownerKey == access.ownerKey && $0.status != .done && $0.deletedAt == nil }.map(\.groupName)
        return Set(catalogue + taskGroups).filter { !$0.isEmpty }.sorted()
    }

    private func pick(_ id: String) {
        guard model.accessScope == access else { return }
        selectedID = id
        dismiss()
    }

    private func create(_ choices: NivoFocusTaskChoices) {
        guard !isSaving, !model.isBusy, model.accessScope == access, choices.canCreate else { return }
        let draft = NivoTodoTask(ownerKey: access.ownerKey, title: choices.title, groupName: group)
        if lastDraft != draft { operationID = UUID().uuidString; lastDraft = draft }
        let requestID = operationID
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            if let saved = await model.saveTaskResult(draft, operationID: requestID, scope: access) { pick(saved.id) }
        }
    }
}
