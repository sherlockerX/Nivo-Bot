import SwiftUI

/// 经典布局复用相同模块页面，关闭当前弹层后再处理跨模块和对话跳转。
struct NivoLifeClassicPresenter: ViewModifier {
    var enabled: Bool
    @ObservedObject private var navigation = NivoLifeNavigation.shared
    @ObservedObject private var life = NivoLifeModel.shared
    @State private var room: NivoClassicLifeRoom?
    @State private var pendingAction: NivoClassicRoomAction?
    @State private var pendingScope: NivoLifeScope?
    @State private var editingRoutine: NanoMuseRoutine?
    @State private var launchError: String?
    @State private var isLaunching = false
    @State private var isDismissingRoom = false
    @State private var didCheckFocusRestoration = false

    func body(content: Content) -> some View {
        content
            .onAppear { receive() }
            .nmOnChange(of: navigation.pendingRoom) { _ in receive() }
            .nmOnChange(of: enabled) { isEnabled in
                if isEnabled { receive() }
                else { clearPresentations() }
            }
            .nmOnChange(of: life.accessScope) { scope in
                if scope == nil { didCheckFocusRestoration = false; clearPresentations() }
                else { receive() }
            }
            .sheet(item: $room, onDismiss: finishNavigation) { selected in
                NavigationStack {
                    Group {
                        switch selected.id {
                        case "todo": NivoTodoRoom(chrome: chrome)
                        case "focus": NivoFocusRoom(chrome: chrome)
                        case "mosaic": NivoMosaicRoom(chrome: chrome)
                        case "routines": NanoMuseRoutinesView()
                        case "coach": coach
                        case "ideas": ideas
                        case "legacy": NivoCoachLegacyArchive()
                        default: EmptyView()
                        }
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Close"), action: dismissRoom) } }
                }
            }
            .sheet(item: $editingRoutine, onDismiss: receive) { routine in
                NanoMuseRoutineEditor(routine: routine)
            }
            .disabled(isLaunching)
            .overlay {
                if isLaunching {
                    ProgressView(AppLocalized("Loading…"))
                        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert(AppLocalized("Error"), isPresented: Binding(
                get: { launchError != nil }, set: { if !$0 { launchError = nil } }
            )) { Button(AppLocalized("Close")) { launchError = nil } } message: { Text(launchError ?? "") }
    }

    private var chrome: NanoMuseRoomChrome {
        NanoMuseRoomChrome(liveId: nil, name: NanoMuseHomeView.currentAgentName(), hasMainSession: false,
                          onMenu: dismissRoom)
    }

    private func receive() {
        guard enabled, !isDismissingRoom, !isLaunching, editingRoutine == nil else { return }
        guard let name = navigation.pendingRoom else { restoreFocus(); return }
        didCheckFocusRestoration = true
        if let current = room {
            if current.id == name { _ = navigation.takePending() }
            else { dismissRoom() }
            return
        }
        _ = navigation.takePending()
        room = NivoClassicLifeRoom(id: name)
    }

    /// 经典布局也恢复上次未主动收起的计时，明确通知或菜单选择优先。
    private func restoreFocus() {
        guard !didCheckFocusRestoration, room == nil, let scope = life.accessScope else { return }
        didCheckFocusRestoration = true
        if NivoFocusPreferences.restorableSession(owner: scope.ownerKey, sessions: life.focusSessions) != nil {
            room = NivoClassicLifeRoom(id: "focus")
        }
    }

    private var coach: some View {
        NivoCoachV2Room(chrome: chrome, onOpenSession: { queue(.chat($0)) }, onOpenLegacy: { queue(.legacy) },
            onCreateCourse: { queue(.draft(AppLocalized("Help me choose an ability to develop and propose a course. Ask about my goals first, and wait for my confirmation before creating it."), usesMain: true)) },
            onManageDraft: { identifier in
                queue(.draft(String(format: AppLocalized("Review course draft %@ with me. Explain its goals, methods and sources, and wait for my confirmation before activating it."), identifier), usesMain: true))
            }, onReviewCourse: { identifier in
                queue(.draft(String(format: AppLocalized("Read course %@ and preserve its source and order. Review simulation and real-action requirements for each unit. Prepare a reviewable draft, show changes, and wait for my explicit confirmation before activating it with the existing course ID. Do not edit files directly."), identifier), usesMain: true))
            })
    }

    private var ideas: some View {
        NanoMuseIdeasRoom(chrome: chrome, onSend: { queue(.draft($0, usesMain: false)) },
            onCreateRoutine: { queue(.routine($0)) }, onStartGoal: { queue(.goal($0, $1)) })
    }

    private func queue(_ action: NivoClassicRoomAction) {
        guard let scope = life.accessScope else { return }
        pendingScope = scope
        pendingAction = action
        dismissRoom()
    }

    private func finishNavigation() {
        isDismissingRoom = false
        let action = pendingAction
        let scope = pendingScope
        pendingAction = nil
        pendingScope = nil
        guard enabled, !NanoMuseShellPrefs.shell else { return }
        guard let action, let scope, life.accessScope == scope else { receive(); return }
        switch action {
        case .chat(let identifier): openChat(identifier)
        case .legacy: room = NivoClassicLifeRoom(id: "legacy")
        case .routine(let idea):
            let time = NanoMuseDay.parseClock(idea.time) ?? (hour: 9, minute: 0)
            editingRoutine = NanoMuseRoutine(label: String(idea.title.prefix(40)), prompt: idea.promptText,
                hour: time.hour, minute: time.minute, repeatMode: .daily)
        case .draft(let text, let usesMain): launch(scope: scope, usesMain: usesMain) { _ in text }
        case .goal(let category, let seed):
            launch(scope: scope, usesMain: true) { identifier in
                let opener = NanoMuseGoalFlow.startCreation(session: identifier, category: category)
                let text = (seed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? opener : opener + " " + text
            }
        }
    }

    private func launch(scope: NivoLifeScope, usesMain: Bool, prompt: @escaping (String) -> String) {
        guard !isLaunching else { return }
        isLaunching = true
        Task { @MainActor in
            defer { isLaunching = false; receive() }
            do {
                let identifier = try await NivoClassicChatLauncher.prepare(scope: scope, usesMain: usesMain, prompt: prompt)
                guard life.accessScope == scope, !NanoMuseShellPrefs.shell else { return }
                openChat(identifier)
            } catch {
                if life.accessScope == scope { launchError = NivoLifeModel.message(error) }
            }
        }
    }

    private func openChat(_ identifier: String) {
        guard life.isReady, NanoMuseSync.shared.shows(identifier) else { return }
        NotificationCenter.default.post(name: .openSessionFromIntent, object: nil, userInfo: ["sessionId": identifier])
    }

    /// 等待系统完成退出动画，期间到达的新深链只更新队列，不抢先呈现另一个页面。
    private func dismissRoom() {
        if room != nil { isDismissingRoom = true }
        room = nil
    }

    private func clearPresentations() {
        pendingAction = nil
        pendingScope = nil
        dismissRoom()
        editingRoutine = nil
        launchError = nil
    }
}

/// 包装稳定页面标识以供sheet(item:)使用。
private struct NivoClassicLifeRoom: Identifiable { var id: String }

/// 对话、草稿和编辑器都等当前页面退出后再打开，旧账户排队意图不会继续执行。
private enum NivoClassicRoomAction {
    case chat(String), legacy, draft(String, usesMain: Bool), routine(NanoMuseIdea)
    case goal(NanoMuseGoalCategory, String?)
}
