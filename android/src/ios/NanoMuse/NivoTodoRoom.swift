import SwiftUI

/// 待办主页面沿用应用的宠物头部和浮动底栏，子视图统一从右上角进入。
struct NivoTodoRoom: View {
    var chrome: NanoMuseRoomChrome
    @ObservedObject private var model = NivoLifeModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var section = NivoTodoSection.list
    @State private var query = ""
    @State private var status = "all"
    @State private var selectedDate = Date()
    @State private var editing: NivoTodoEditTarget?
    @State private var detail: NivoTodoTask?
    @State private var detailScope: NivoLifeScope?
    @State private var pendingFocus: NivoLifeItemTarget?
    @State private var pendingFragment: NivoLifeItemTarget?
    @State private var isManagingCategories = false
    @State private var categoryScope: NivoLifeScope?
    @State private var isShowingBackup = false

    private var visible: [NivoTodoTask] {
        model.tasks.filter { task in
            let matchesStatus = status == "all" || task.status.rawValue == status
            let matchesQuery = query.isEmpty || ([task.id, task.title, task.notes, task.groupName] + task.tags)
                .contains { $0.localizedCaseInsensitiveContains(query) }
            return matchesStatus && matchesQuery
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                NanoMuseRoomHeader(chrome: chrome) {
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(NivoTodoSection.allCases) { item in
                                Button { section = item } label: { Label(item.title, systemImage: item.symbol) }
                            }
                            Divider()
                            Button(AppLocalized("Groups and tags")) {
                                categoryScope = model.accessScope
                                isManagingCategories = categoryScope != nil
                            }.disabled(!model.isReady || model.isBusy)
                            Button(AppLocalized("Task backup")) { isShowingBackup = true }
                                .disabled(!model.isReady || model.isBusy)
                        } label: { NanoMuseRoundDisc(symbol: section.symbol) }
                        .accessibilityLabel(AppLocalized("Task views"))
                        NanoMuseRoundButton(symbol: "plus", label: AppLocalized("New task")) {
                            if let scope = model.accessScope {
                                editing = NivoTodoEditTarget(task: NivoTodoTask(ownerKey: scope.ownerKey), scope: scope)
                            }
                        }
                            .disabled(!model.isReady || model.isBusy)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(AppLocalized("Tasks")).font(.largeTitle.bold())
                    Spacer()
                    Text(section.title).font(.subheadline).foregroundStyle(.secondary)
                }
                if !model.isReady {
                    if model.errorMessage == nil { ProgressView().frame(maxWidth: .infinity) }
                    else {
                        Text(model.errorMessage ?? "").foregroundStyle(.secondary)
                        Button(AppLocalized("Retry")) { Task { await model.activate() } }
                    }
                } else {
                    searchAndFilter
                    content
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
        .background(NanoMuseTones.canvas.ignoresSafeArea())
        .overlay(alignment: .top) { if model.isBusy { ProgressView().padding(8).background(.regularMaterial, in: Capsule()) } }
        .task { await model.activate() }
        .nmOnChange(of: scenePhase) { phase in if phase == .active { Task { await model.refresh() } } }
        .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in
            editing = nil
            detail = nil
            detailScope = nil
            pendingFocus = nil
            pendingFragment = nil
            isManagingCategories = false
            categoryScope = nil
            isShowingBackup = false
            Task { await model.activate() }
        }
        .nmOnChange(of: model.accessScope) { scope in
            if editing?.scope != scope { editing = nil }
            if categoryScope != scope { isManagingCategories = false; categoryScope = nil }
            if detailScope != scope { detail = nil; detailScope = nil; pendingFocus = nil; pendingFragment = nil }
        }
        .sheet(item: $editing) { target in NivoTodoEditor(task: target.task, access: target.scope, model: model) }
        .sheet(item: $detail, onDismiss: navigateAfterDetail) { task in
            if let detailScope {
                NivoTodoDetailView(taskID: task.id, access: detailScope, model: model,
                    onOpenFocus: { pendingFocus = $0; detail = nil },
                    onOpenFragment: { pendingFragment = $0; detail = nil })
            }
        }
        .sheet(isPresented: $isManagingCategories) {
            if let categoryScope { NivoTodoCategoriesView(access: categoryScope, model: model) }
        }
        .sheet(isPresented: $isShowingBackup) {
            if let scope = model.accessScope { NivoLifeFileTransferView(kind: .tasks, scope: scope) }
        }
        .alert(AppLocalized("Error"), isPresented: Binding(
            get: { model.errorMessage != nil && model.isReady && editing == nil && detail == nil && !isManagingCategories && !isShowingBackup },
            set: { if !$0 { model.errorMessage = nil } }
        )) { Button(AppLocalized("Close")) { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }

    private var searchAndFilter: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(AppLocalized("Search"), text: $query).textInputAutocapitalization(.never)
            }
            .padding(12)
            .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 16))
            Picker(AppLocalized("Status"), selection: $status) {
                Text(AppLocalized("All")).tag("all")
                ForEach(NivoTodoStatus.allCases, id: \.rawValue) { item in Text(item.title).tag(item.rawValue) }
            }.pickerStyle(.segmented)
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .list: taskList(visible)
        case .calendar:
            NivoTodoCalendarView(tasks: visible, selectedDate: $selectedDate) { taskList($0) }
                .id(model.accessScope)
        case .quadrants:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280))], alignment: .leading, spacing: 16) {
                ForEach(0..<4) { quadrant in
                    let important = quadrant < 2
                    let urgent = quadrant % 2 == 0
                    VStack(alignment: .leading, spacing: 12) {
                        Text(NivoTodoSection.quadrantTitle(important: important, urgent: urgent)).font(.headline)
                        taskList(visible.filter { $0.isImportant == important && $0.isUrgent == urgent })
                    }.padding(14).background(NanoMuseTones.fill, in: RoundedRectangle(cornerRadius: 20))
                }
            }
        case .groups:
            ForEach(Array(Set(visible.map(\.groupName))).sorted(), id: \.self) { group in
                Text(group.isEmpty ? AppLocalized("Ungrouped") : group).font(.headline)
                taskList(visible.filter { $0.groupName == group })
            }
        case .status:
            ForEach(NivoTodoStatus.allCases, id: \.rawValue) { item in
                Text(item.title).font(.headline)
                taskList(visible.filter { $0.status == item })
            }
        case .statistics: NivoTodoStatisticsView(tasks: model.tasks)
        }
    }

    @ViewBuilder private func taskList(_ tasks: [NivoTodoTask]) -> some View {
        let rowScope = model.accessScope
        if tasks.isEmpty {
            Text(AppLocalized("No tasks here")).foregroundStyle(.secondary).padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(tasks) { task in
                    NivoTodoRow(task: task, isBusy: model.isBusy, onEdit: {
                        guard let rowScope, model.accessScope == rowScope else { return }
                        detailScope = rowScope
                        detail = task
                    }, onToggle: {
                        if let rowScope {
                            Task { await model.setStatus(task, status: task.status == .done ? .todo : .done, scope: rowScope) }
                        }
                    })
                    .contextMenu {
                        Button(AppLocalized("Edit")) {
                            if let rowScope, model.accessScope == rowScope { editing = NivoTodoEditTarget(task: task, scope: rowScope) }
                        }
                        if task.status == .todo {
                            Button(AppLocalized("Start")) {
                                if let rowScope { Task { await model.setStatus(task, status: .inProgress, scope: rowScope) } }
                            }
                        }
                        Button(AppLocalized("Delete"), role: .destructive) {
                            if let rowScope { Task { await model.deleteTask(task, scope: rowScope) } }
                        }
                    }
                }
            }
        }
    }

    /// 先关闭详情再切换房间，避免两层sheet同时呈现；跨账户意图直接作废。
    private func navigateAfterDetail() {
        defer { pendingFocus = nil; pendingFragment = nil; detailScope = nil }
        if let target = pendingFocus, target.scope == model.accessScope {
            NivoLifeNavigation.shared.openFocus(taskID: target.id, scope: target.scope)
        } else if let target = pendingFragment, target.scope == model.accessScope {
            NivoLifeNavigation.shared.openMosaic(entryID: target.id, scope: target.scope)
        }
    }
}

/// 每次编辑使用独立展示身份，固定草稿、账户和代次，不跟随全局模型重新绑定。
private struct NivoTodoEditTarget: Identifiable {
    var id = UUID()
    var task: NivoTodoTask
    var scope: NivoLifeScope
}

/// 页面选择只改变展示方式，所有页面读取同一个任务仓库。
enum NivoTodoSection: String, CaseIterable, Identifiable {
    case list, calendar, quadrants, groups, status, statistics
    var id: String { rawValue }
    var title: String {
        AppLocalized(["list": "Tasks", "calendar": "Calendar", "quadrants": "Four quadrants",
                      "groups": "Groups", "status": "Status", "statistics": "Statistics"][rawValue]!)
    }
    var symbol: String {
        ["list": "checklist", "calendar": "calendar", "quadrants": "square.grid.2x2",
         "groups": "folder", "status": "slider.horizontal.3", "statistics": "chart.pie"][rawValue]!
    }
    static func quadrantTitle(important: Bool, urgent: Bool) -> String {
        if important { return AppLocalized(urgent ? "Important and urgent" : "Important, not urgent") }
        return AppLocalized(urgent ? "Urgent, not important" : "Neither urgent nor important")
    }
}

extension NivoTodoStatus {
    var title: String {
        switch self {
        case .todo: return AppLocalized("To do")
        case .inProgress: return AppLocalized("In progress")
        case .done: return AppLocalized("Completed")
        }
    }
}

/// 行内勾选有独立的可访问标签，任务详情区不和勾选操作抢点击。
private struct NivoTodoRow: View {
    var task: NivoTodoTask
    var isBusy: Bool
    var onEdit: () -> Void
    var onToggle: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(.title2).frame(width: 44, height: 44)
            }.buttonStyle(.plain).disabled(isBusy)
                .accessibilityLabel(task.status == .done ? AppLocalized("Reopen task") : AppLocalized("Complete task"))
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title).font(.body.weight(.medium)).strikethrough(task.status == .done)
                        .multilineTextAlignment(.leading).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(task.status.title)
                        if !task.groupName.isEmpty { Text("· " + task.groupName) }
                        if task.isImportant { Image(systemName: "star.fill") }
                        if task.isUrgent { Image(systemName: "bolt.fill") }
                    }.font(.caption).foregroundStyle(.secondary)
                    if let due = task.dueDay {
                        Text(NivoLifeDay.date(due), style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(12)
        .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}
