import SwiftUI

/// 专注入口复用应用房间布局，右上角进入记录、统计及背景图库。
struct NivoFocusRoom: View {
    var chrome: NanoMuseRoomChrome
    @ObservedObject private var model = NivoLifeModel.shared
    @ObservedObject private var navigation = NivoLifeNavigation.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundID = ""
    @State private var section = "timer"
    @State private var isStarting = false
    @State private var startingTaskID = ""
    @State private var startingScope: NivoLifeScope?
    @State private var isShowingBackgrounds = false
    @State private var immersive: NivoFocusPresentation?
    @State private var pendingStart: NivoFocusSession?
    @State private var deleting: NivoFocusSession?
    @State private var deletionScope: NivoLifeScope?
    @State private var didRestore = false
    @State private var isExporting = false
    @State private var pendingReflection: NivoLifeItemTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NanoMuseRoomHeader(chrome: chrome) {
                    Menu {
                        Button(AppLocalized("Focus")) { section = "timer" }
                        Button(AppLocalized("Focus records")) { section = "records" }
                        Button(AppLocalized("Statistics")) { section = "statistics" }
                        Divider()
                        Button(AppLocalized("Focus backgrounds")) { isShowingBackgrounds = true }
                        Button(AppLocalized("Export focus records")) { isExporting = true }
                            .disabled(!model.isReady || model.isBusy)
                    } label: { NanoMuseRoundDisc(symbol: "slider.horizontal.3") }
                    .accessibilityLabel(AppLocalized("Focus views"))
                }
                Text(AppLocalized("Focus")).font(.largeTitle.bold())
                if !model.isReady {
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.secondary)
                        Button(AppLocalized("Retry")) { Task { await model.activate() } }
                    } else { ProgressView().frame(maxWidth: .infinity) }
                } else {
                    switch section {
                    case "records": records
                    case "statistics": NivoFocusStatisticsView(model: model)
                    default: timer
                    }
                }
            }.padding(.horizontal, 20).padding(.bottom, 24)
                .frame(maxWidth: 880).frame(maxWidth: .infinity)
        }
        .background(NanoMuseTones.canvas.ignoresSafeArea())
        .task {
            await model.activate()
            backgroundID = NivoFocusPreferences.background(owner: model.ownerKey)
            resolveEntry()
        }
        .nmOnChange(of: model.accessScope) { scope in
            if scope == nil { clearPresentations() }
            else {
                backgroundID = NivoFocusPreferences.background(owner: model.ownerKey)
                resolveEntry()
            }
        }
        .nmOnChange(of: navigation.focusTarget) { target in
            if target != nil { Task { await model.refresh(); resolveEntry() } }
        }
        .nmOnChange(of: navigation.focusTaskTarget) { target in
            if target != nil { Task { await model.refresh(); resolveEntry() } }
        }
        .modifier(NivoFocusRefresh(model: model, isVisible: immersive == nil))
        .nmOnChange(of: scenePhase) { phase in if phase == .active { Task { await model.refresh(); resolveEntry() } } }
        .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in
            clearPresentations()
            backgroundID = NivoFocusPreferences.background(owner: model.ownerKey)
        }
        .sheet(isPresented: $isStarting, onDismiss: {
            startingTaskID = ""
            startingScope = nil
            if let session = pendingStart { pendingStart = nil; present(session) }
            resolveEntry()
        }) {
            if let startingScope {
                NivoFocusStartView(model: model, access: startingScope, initialTaskID: startingTaskID,
                    backgroundID: $backgroundID) { session in pendingStart = session }
            }
        }
        .sheet(isPresented: $isShowingBackgrounds, onDismiss: resolveEntry) {
            if let scope = model.accessScope { NivoFocusBackgroundPicker(scope: scope, selectedID: $backgroundID) }
        }
        .sheet(isPresented: $isExporting, onDismiss: resolveEntry) {
            if let scope = model.accessScope { NivoLifeFileTransferView(kind: .focus, scope: scope) }
        }
        .fullScreenCover(item: $immersive, onDismiss: openPendingReflection) { presentation in
            NivoFocusImmersiveView(sessionID: presentation.id, model: model,
                backgroundID: presentation.backgroundID, access: presentation.scope,
                onReflection: { requestReflection(sessionID: presentation.id, scope: presentation.scope) }) {
                guard model.accessScope == presentation.scope else { return }
                NivoFocusPreferences.dismissImmersive(presentation.id, owner: presentation.scope.ownerKey)
                if immersive?.id == presentation.id, immersive?.scope == presentation.scope { immersive = nil }
            }
        }
        .confirmationDialog(AppLocalized("Delete this focus record?"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            if let deleting, let deletionScope {
                Button(AppLocalized("Delete"), role: .destructive) {
                    guard pendingReflection == nil else { return }
                    Task { _ = await model.controlFocus(deleting, action: "delete", scope: deletionScope) }
                }.disabled(pendingReflection != nil)
            }
        } message: { Text(AppLocalized("It will be removed from focus statistics.")) }
        .alert(AppLocalized("Error"), isPresented: Binding(
            get: { model.errorMessage != nil && model.isReady && !isStarting && immersive == nil && !isExporting && !isShowingBackgrounds },
            set: { if !$0 { model.errorMessage = nil } }
        )) { Button(AppLocalized("Close")) { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }

    private var timer: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button {
                if let active = model.activeFocus { present(active) } else { prepareStart(taskID: "") }
            } label: {
                ZStack(alignment: .bottomLeading) {
                    NivoFocusBackdropView(backgroundID: backgroundID, ownerKey: model.ownerKey)
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.activeFocus?.title ?? AppLocalized("Make room for one thing"))
                            .font(.title2.bold()).multilineTextAlignment(.leading)
                        Label(AppLocalized(model.activeFocus == nil ? "Start focus" : "Return to focus"), systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                    }.foregroundStyle(.white).padding(24)
                }.frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 28))
            }.buttonStyle(.plain).disabled(model.isBusy)
            if let active = model.activeFocus {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack {
                        Label(active.status.title, systemImage: active.status == .paused ? "pause.circle" : "timer")
                        Spacer()
                        Text(NivoFocusFormat.clock(NivoFocusPresentationRules.displayedDuration(active, clock: NivoLifeClock.sample())))
                            .monospacedDigit()
                    }.font(.subheadline)
                }
            }
            Text(AppLocalized("Link a task, choose a background, then focus. Finishing a timer does not complete the task."))
                .font(.subheadline).foregroundStyle(.secondary)
            NivoFocusStatisticsView(model: model, isCompact: true)
            HStack {
                Text(AppLocalized("Recent focus records")).font(.headline)
                Spacer()
                Button(AppLocalized("Focus records")) { section = "records" }.font(.subheadline)
            }
            if recentSessions.isEmpty {
                Text(AppLocalized("No focus records yet")).foregroundStyle(.secondary)
            }
            ForEach(recentSessions) { session in recordCard(session) }
        }
    }

    private var recentSessions: [NivoFocusSession] {
        Array(model.focusSessions.filter { $0.status == .finished && $0.deletedAt == nil }
            .sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }.prefix(3))
    }

    private var records: some View {
        LazyVStack(spacing: 12) {
            if model.focusSessions.isEmpty {
                Text(AppLocalized("No focus records yet")).foregroundStyle(.secondary).padding(.vertical, 32)
            }
            ForEach(model.focusSessions) { session in recordCard(session) }
        }
    }

    /// 首页与历史共用卡片及心得入口，起止日期均保留，跨午夜时段仍可辨认。
    private func recordCard(_ session: NivoFocusSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(session.title).font(.headline)
                Spacer()
                Text(session.mode.title).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalized("Start") + ": " + Date(timeIntervalSince1970: Double(session.startedAt) / 1_000)
                    .formatted(date: .abbreviated, time: .shortened))
                if let endedAt = session.endedAt {
                    Text(AppLocalized("End") + ": " + Date(timeIntervalSince1970: Double(endedAt) / 1_000)
                        .formatted(date: .abbreviated, time: .shortened))
                }
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(session.status.title)
                Spacer()
                Text(NivoFocusFormat.clock(session.elapsedMs)).monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            if session.isActive {
                Button(AppLocalized("Return to focus")) { present(session) }
            } else {
                if NivoFocusReflectionRules.canReflect(session), let scope = model.accessScope {
                    Button(AppLocalized("Record reflection")) { requestReflection(sessionID: session.id, scope: scope) }
                        .disabled(model.isBusy || pendingReflection != nil || !model.isMosaicReady)
                }
                Button(AppLocalized("Delete"), role: .destructive) {
                    deletionScope = model.accessScope
                    deleting = session
                }
                    .font(.caption).disabled(model.isBusy || pendingReflection != nil)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func present(_ session: NivoFocusSession) {
        guard let scope = model.accessScope, session.ownerKey == scope.ownerKey,
              model.focusSessions.contains(where: { $0.id == session.id }) else { return }
        NivoFocusPreferences.rememberImmersive(session.id, owner: scope.ownerKey)
        immersive = NivoFocusPresentation(id: session.id, scope: scope,
            backgroundID: NivoFocusPreferences.background(forSession: session.id, owner: scope.ownerKey))
    }

    private func resolveEntry() {
        guard let scope = model.accessScope, !isStarting, !isShowingBackgrounds, !isExporting,
              pendingReflection == nil else { return }
        _ = NivoFocusPreferences.restorableSession(owner: scope.ownerKey, sessions: model.focusSessions)
        let destination = NivoLifeEntryRules.focusDestination(
            requestedSessionID: navigation.takeFocusTarget(), requestedTask: navigation.takeFocusTaskTarget(),
            storedID: NivoFocusPreferences.immersiveSession(owner: scope.ownerKey),
            sessions: model.focusSessions, tasks: model.tasks, scope: scope,
            shouldRestore: !didRestore
        )
        didRestore = true
        switch destination {
        case .session(let identifier):
            if let session = model.focusSessions.first(where: { $0.id == identifier }) { present(session) }
        case .task(let identifier): prepareStart(taskID: identifier)
        case .busy: model.errorMessage = NivoLifeModel.message(NivoLifeError.activeSessionExists)
        case .unavailable: model.errorMessage = AppLocalized("This item no longer exists. Reload the list.")
        case .none: break
        }
    }

    private func prepareStart(taskID: String) {
        guard let scope = model.accessScope else { return }
        startingScope = scope
        startingTaskID = taskID
        isStarting = true
    }

    private func clearPresentations() {
        pendingReflection = nil
        immersive = nil
        pendingStart = nil
        deleting = nil
        deletionScope = nil
        isStarting = false
        startingScope = nil
        startingTaskID = ""
        isShowingBackgrounds = false
        isExporting = false
        didRestore = false
    }

    /// 先清除全屏恢复标记；有全屏时仅排队，等待系统完成关闭后再跨模块导航。
    private func requestReflection(sessionID: String, scope: NivoLifeScope) {
        guard pendingReflection == nil, model.accessScope == scope, !model.isBusy, model.isMosaicReady,
              let session = model.focusSessions.first(where: { $0.id == sessionID && $0.ownerKey == scope.ownerKey }),
              NivoFocusReflectionRules.canReflect(session) else { return }
        pendingReflection = NivoLifeItemTarget(id: sessionID, scope: scope)
        NivoFocusPreferences.dismissImmersive(sessionID, owner: scope.ownerKey)
        if immersive != nil { immersive = nil }
        else { openPendingReflection() }
    }

    /// 原生与经典宿主都复用此一次性入口，不在全屏退场动画中呈现编辑器。
    private func openPendingReflection() {
        guard let target = pendingReflection else { return }
        pendingReflection = nil
        guard model.accessScope == target.scope else { return }
        navigation.openReflection(sessionID: target.id, scope: target.scope)
    }
}

/// 全屏展示保存会话标识，后续状态始终从当前账户仓库读取。
private struct NivoFocusPresentation: Identifiable {
    var id: String
    var scope: NivoLifeScope
    var backgroundID: String
}

/// 开始之前选择模式和待办，不用导航到另一个页面补填任务语义。
private struct NivoFocusStartView: View {
    @ObservedObject var model: NivoLifeModel
    let access: NivoLifeScope
    @Binding var backgroundID: String
    var onStarted: (NivoFocusSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var taskID = ""
    @State private var title = ""
    @State private var mode = NivoFocusMode.pomodoro
    @State private var minutes = 25
    @State private var isChoosingBackground = false
    @State private var operationID = UUID().uuidString

    init(model: NivoLifeModel, access: NivoLifeScope, initialTaskID: String,
         backgroundID: Binding<String>, onStarted: @escaping (NivoFocusSession) -> Void) {
        self.model = model
        self.access = access
        _taskID = State(initialValue: initialTaskID)
        _backgroundID = backgroundID
        self.onStarted = onStarted
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(AppLocalized("Mode"), selection: $mode) {
                        ForEach(NivoFocusMode.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if mode != .stopwatch {
                        Stepper(value: $minutes, in: 1...180) {
                            HStack { Text(AppLocalized("Minutes")); Spacer(); Text(minutes.formatted()).monospacedDigit() }
                        }
                    }
                }
                Section(AppLocalized("Task")) {
                    Picker(AppLocalized("Link task"), selection: $taskID) {
                        Text(AppLocalized("No linked task")).tag("")
                        ForEach(model.tasks) { Text($0.title).tag($0.id) }
                    }
                    if taskID.isEmpty { TextField(AppLocalized("What will you focus on?"), text: $title) }
                }
                Section(AppLocalized("Background")) {
                    Button { isChoosingBackground = true } label: {
                        NivoFocusBackdropView(backgroundID: backgroundID, ownerKey: model.ownerKey, thumbnail: true)
                            .frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain).accessibilityLabel(AppLocalized("Choose background"))
                    Button(AppLocalized("Choose background")) { isChoosingBackground = true }
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .disabled(model.isBusy)
            .navigationTitle(AppLocalized("Start focus")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Start")) { Task { await start() } }
                        .disabled(model.isBusy || model.accessScope != access
                            || (!taskID.isEmpty && !model.tasks.contains(where: { $0.id == taskID }))
                            || (taskID.isEmpty && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .sheet(isPresented: $isChoosingBackground) {
                if let scope = model.accessScope { NivoFocusBackgroundPicker(scope: scope, selectedID: $backgroundID) }
            }
            .nmOnChange(of: title) { _ in operationID = UUID().uuidString }
            .nmOnChange(of: taskID) { _ in operationID = UUID().uuidString }
            .nmOnChange(of: mode) { value in
                operationID = UUID().uuidString
                if value == .rest { minutes = 5 }
            }
            .nmOnChange(of: minutes) { _ in operationID = UUID().uuidString }
            .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in dismiss() }
            .nmOnChange(of: model.accessScope) { if $0 != access { dismiss() } }
            .onAppear { model.errorMessage = nil }
        }
    }

    private func start() async {
        guard model.accessScope == access else { return }
        let selectedBackground = backgroundID
        let result = await model.startFocusResult(title: title, taskID: taskID.isEmpty ? nil : taskID,
                                                  mode: mode, minutes: minutes, operationID: operationID, scope: access)
        guard let session = result, model.accessScope == access else { return }
        NivoFocusPreferences.bindBackground(selectedBackground, sessionID: session.id, owner: access.ownerKey)
        onStarted(session)
        dismiss()
        await NivoFocusNotifications.shared.requestPermission()
    }
}

extension NivoFocusMode {
    var title: String {
        switch self {
        case .pomodoro: return AppLocalized("Pomodoro")
        case .stopwatch: return AppLocalized("Stopwatch")
        case .rest: return AppLocalized("Break")
        }
    }
}

extension NivoFocusStatus {
    var title: String {
        switch self {
        case .running: return AppLocalized("Running")
        case .paused: return AppLocalized("Paused")
        case .finished: return AppLocalized("Finished")
        }
    }
}

/// 时间只做显示格式化，不反向解析成可写入的专注证据。
enum NivoFocusFormat {
    static func clock(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1_000)
        if seconds >= 3_600 { return String(format: "%02lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }
}
