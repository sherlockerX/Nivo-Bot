import SwiftUI

/// 创建与编辑使用独立草稿，保存失败保留内容，重新载入是显式操作。
struct NivoTodoEditor: View {
    let access: NivoLifeScope
    @ObservedObject var model: NivoLifeModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NivoTodoTask
    @State private var newTag = ""
    @State private var newGroup = ""
    @State private var operationID = UUID().uuidString

    /// 编辑能力由打开页面时的账户发放，不在保存时借用后来激活的代次。
    init(task: NivoTodoTask, access: NivoLifeScope, model: NivoLifeModel) {
        self.access = access
        self.model = model
        _draft = State(initialValue: task)
    }

    private var groups: [String] {
        Array(Set(model.categories.filter { $0.kind == .group }.map(\.name) + [draft.groupName]))
            .filter { !$0.isEmpty }.sorted()
    }

    private var tags: [String] {
        Array(Set(model.categories.filter { $0.kind == .tag }.map(\.name) + draft.tags)).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(AppLocalized("Title"), text: $draft.title, axis: .vertical)
                    Picker(AppLocalized("Status"), selection: $draft.status) {
                        ForEach(NivoTodoStatus.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                    }
                    TextField(AppLocalized("Notes"), text: $draft.notes, axis: .vertical).lineLimit(3...8)
                }
                Section(AppLocalized("Dates")) {
                    dayField("Scheduled date", value: $draft.scheduledDay)
                    dayField("Due date", value: $draft.dueDay)
                }
                Section(AppLocalized("Four quadrants")) {
                    Toggle(AppLocalized("Important"), isOn: $draft.isImportant)
                    Toggle(AppLocalized("Urgent"), isOn: $draft.isUrgent)
                }
                Section(AppLocalized("Group")) {
                    Picker(AppLocalized("Group"), selection: $draft.groupName) {
                        Text(AppLocalized("Ungrouped")).tag("")
                        ForEach(groups, id: \.self) { Text($0).tag($0) }
                    }
                    HStack {
                        TextField(AppLocalized("New group"), text: $newGroup)
                        Button(AppLocalized("Add")) { addGroup() }.disabled(newGroup.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section(AppLocalized("Tags")) {
                    ForEach(tags, id: \.self) { tag in
                        Toggle(tag, isOn: Binding(get: { draft.tags.contains(tag) }, set: { selected in
                            if selected { draft.tags.append(tag) } else { draft.tags.removeAll { $0 == tag } }
                        }))
                    }
                    HStack {
                        TextField(AppLocalized("New tag"), text: $newTag)
                        Button(AppLocalized("Add")) { addTag() }.disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                        if !draft.id.isEmpty {
                            Button(AppLocalized("Reload saved task")) {
                                Task {
                                    guard model.accessScope == access else { return }
                                    await model.refresh()
                                    guard model.accessScope == access else { return }
                                    if let current = model.tasks.first(where: { $0.id == draft.id }) {
                                        draft = current
                                        model.errorMessage = nil
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .disabled(model.isBusy || model.accessScope != access)
            .navigationTitle(AppLocalized(draft.id.isEmpty ? "New task" : "Edit task"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Cancel")) { dismiss() }.disabled(model.isBusy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Save")) {
                        let submitted = draft
                        let operation = operationID
                        Task { if await model.saveTask(submitted, operationID: operation, scope: access) { dismiss() } }
                    }.disabled(model.isBusy || model.accessScope != access || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .nmOnChange(of: draft) { _ in operationID = UUID().uuidString }
            .nmOnChange(of: model.accessScope) { if $0 != access { dismiss() } }
            .interactiveDismissDisabled(model.isBusy)
            .onAppear { model.errorMessage = nil }
            .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in dismiss() }
        }
    }

    @ViewBuilder private func dayField(_ title: String, value: Binding<Int64?>) -> some View {
        Toggle(AppLocalized(title), isOn: Binding(get: { value.wrappedValue != nil }, set: {
            value.wrappedValue = $0 ? NivoLifeDay.value() : nil
        }))
        if value.wrappedValue != nil {
            DatePicker(AppLocalized(title), selection: Binding(
                get: { NivoLifeDay.date(value.wrappedValue ?? NivoLifeDay.value()) },
                set: { value.wrappedValue = NivoLifeDay.value($0) }
            ), displayedComponents: .date)
        }
    }

    private func addGroup() {
        do {
            draft.groupName = try NivoTodoRules.categoryName(newGroup, kind: .group)
            newGroup = ""
        } catch { model.errorMessage = NivoLifeModel.message(error) }
    }

    private func addTag() {
        do {
            let tag = try NivoTodoRules.categoryName(newTag, kind: .tag)
            draft.tags = try NivoTodoRules.tags(draft.tags + [tag])
            newTag = ""
        } catch { model.errorMessage = NivoLifeModel.message(error) }
    }
}

/// 分类管理独立于任务编辑，删除前说明当前任务引用将被清除。
struct NivoTodoCategoriesView: View {
    let access: NivoLifeScope
    @ObservedObject var model: NivoLifeModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind = NivoTodoCategory.Kind.group
    @State private var name = ""
    @State private var deleting: NivoTodoCategory?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(AppLocalized("Type"), selection: $kind) {
                        Text(AppLocalized("Group")).tag(NivoTodoCategory.Kind.group)
                        Text(AppLocalized("Tags")).tag(NivoTodoCategory.Kind.tag)
                    }.pickerStyle(.segmented)
                    HStack {
                        TextField(AppLocalized("Name"), text: $name)
                        Button(AppLocalized("Add")) {
                            let requestedKind = kind
                            let requestedName = name
                            Task {
                                if await model.createCategory(kind: requestedKind, name: requestedName, scope: access),
                                   kind == requestedKind, name == requestedName { name = "" }
                            }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                    }
                }
                Section {
                    ForEach(model.categories.filter { $0.kind == kind }) { category in
                        HStack {
                            Text(category.name)
                            Spacer()
                            Button(role: .destructive) { deleting = category } label: { Image(systemName: "trash") }
                                .accessibilityLabel(AppLocalized("Delete") + " " + category.name)
                        }
                    }
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .disabled(model.isBusy || model.accessScope != access)
            .navigationTitle(AppLocalized("Groups and tags"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Done")) { dismiss() } } }
            .confirmationDialog(AppLocalized("Remove this category from current tasks?"), isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible) {
                if let deleting {
                    Button(AppLocalized("Delete"), role: .destructive) { Task { await model.deleteCategory(deleting, scope: access) } }
                }
            } message: { Text(AppLocalized("Tasks and completion history are kept.")) }
            .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in dismiss() }
            .nmOnChange(of: model.accessScope) { if $0 != access { deleting = nil; dismiss() } }
            .onAppear { model.errorMessage = nil }
        }
    }
}
