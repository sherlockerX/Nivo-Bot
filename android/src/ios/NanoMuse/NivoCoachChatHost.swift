import SwiftUI

/// 训练沿用原生聊天输入、流式回复和朗读；只有绑定专题才显示轻量课次控制。
struct NivoCoachChatHost: ViewModifier {
    @ObservedObject var vm: AIChatViewModel
    let readOnly: Bool
    @ObservedObject private var context = NivoCoachChatContext.shared
    @ObservedObject private var life = NivoLifeModel.shared
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var selectedLesson: NivoCoachSheetTarget<NivoCoachSession>?
    @State private var pendingSource: NivoCoachSourceRequestTarget?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let topic = context.topic(for: vm.sessionId) { controls(topic) }
                else if vm.sessionSource == NivoCoachConversationIdentity.source,
                        let error = context.failure(for: vm.sessionId) {
                    recoveryNotice(error)
                }
            }
            .task(id: vm.nmSessionKey) { await context.refresh(sessionID: vm.sessionId) }
            .nmOnChange(of: life.isReady) { ready in
                if ready { Task { await context.refresh(sessionID: vm.sessionId) } }
                else { selectedLesson = nil }
            }
            .nmOnChange(of: life.accessScope) { _ in selectedLesson = nil; pendingSource = nil; errorMessage = nil }
            .nmOnChange(of: vm.nmSessionKey) { _ in selectedLesson = nil; pendingSource = nil; errorMessage = nil }
            .onReceive(NotificationCenter.default.publisher(for: .nivoCoachStateChanged)) { _ in
                Task { await context.refresh(sessionID: vm.sessionId) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .nivoCoachSourcesChanged)
                .receive(on: RunLoop.main).debounce(for: .milliseconds(200), scheduler: RunLoop.main)) { _ in
                Task { await context.refresh(sessionID: vm.sessionId) }
            }
            .nmOnChange(of: vm.isProcessing) { running in
                if !running { Task { await context.refresh(sessionID: vm.sessionId) } }
            }
            .sheet(item: $selectedLesson, onDismiss: finishSourceNavigation) { target in
                NivoCoachLessonDetail(lessonID: target.item.id, state: context.state, onOpenChat: { chatID, messageID in
                    guard life.accessScope == target.scope else { return }
                    if let messageID {
                        pendingSource = NivoCoachSourceRequestTarget(chatID: chatID, messageID: messageID, scope: target.scope)
                    }
                    selectedLesson = nil
                }, loadError: context.failure(for: vm.sessionId),
                   onRetry: { Task { await context.refresh(sessionID: vm.sessionId) } })
            }
            .alert(AppLocalized("Error"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button(AppLocalized("Close")) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }

    private func controls(_ topic: NivoCoachTopic) -> some View {
        let lesson = context.lesson(for: topic)
        let displayedScope = life.accessScope
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let lesson { Text(NivoCoachDisplay.status(lesson.status)).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                if isBusy { ProgressView() }
                Menu {
                    if let lesson {
                        Button(AppLocalized("Lesson archive")) {
                            if let scope = displayedScope, life.accessScope == scope {
                                selectedLesson = NivoCoachSheetTarget(item: lesson, scope: scope)
                            }
                        }
                        if !readOnly, topic.status == "active", ["active", "waiting_real"].contains(lesson.status) {
                            Button(AppLocalized("End lesson")) { perform("end_lesson", targetID: lesson.id, scope: displayedScope) }
                        }
                        if !readOnly, lesson.status == "active" {
                            Button(AppLocalized("Pause")) { perform("pause_session", targetID: lesson.id, scope: displayedScope) }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel(AppLocalized("Lesson controls"))
            }
            if topic.status == "active", !readOnly {
                lessonAction(topic: topic, lesson: lesson, scope: displayedScope)
            }
            if let failure = context.failure(for: vm.sessionId) {
                HStack(alignment: .top) {
                    Text(failure).font(.caption).foregroundStyle(.secondary)
                    Button(AppLocalized("Retry")) { Task { await context.refresh(sessionID: vm.sessionId) } }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(NanoMuseTones.surface)
        .disabled(isBusy || vm.isProcessing)
    }

    /// 首载失败时仍在专属训练聊天提供重试；普通主聊天不出现教练档案组件。
    private func recoveryNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(AppLocalized("Retry")) { Task { await context.refresh(sessionID: vm.sessionId) } }
                .disabled(vm.isProcessing || isBusy)
        }.padding(12).background(NanoMuseTones.surface)
    }

    /// 等档案退出后才发送定位意图，聊天尚未加载时由导航队列保留。
    private func finishSourceNavigation() {
        defer { pendingSource = nil }
        guard let target = pendingSource, life.accessScope == target.scope else { return }
        NivoCoachSourceNavigation.shared.enqueue(chatID: target.chatID, messageID: target.messageID, scope: target.scope)
        if target.chatID != vm.sessionId {
            NotificationCenter.default.post(name: .openSessionFromIntent, object: nil, userInfo: ["sessionId": target.chatID])
        }
    }

    @ViewBuilder
    private func lessonAction(topic: NivoCoachTopic, lesson: NivoCoachSession?, scope: NivoLifeScope?) -> some View {
        if lesson?.status == "complete" || lesson == nil {
            Button(AppLocalized("Continue learning")) { perform("start_lesson", targetID: topic.id, scope: scope, beginTeaching: true) }
                .buttonStyle(.bordered)
        } else if lesson?.status == "paused", let lesson {
            Button(AppLocalized("Resume")) { perform("resume_session", targetID: lesson.id, scope: scope) }.buttonStyle(.bordered)
        } else if lesson?.turns.isEmpty == true {
            Button(AppLocalized("Start teaching")) {
                guard let scope, life.accessScope == scope else { return }
                vm.nmSendNow(AppLocalized("Start this unit with an explanation and a concrete example."))
            }
                .buttonStyle(.borderedProminent)
        } else if lesson?.assessment != nil {
            Label(AppLocalized("Independent check"), systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func perform(_ action: String, targetID: String, scope: NivoLifeScope?, beginTeaching: Bool = false) {
        guard !isBusy, !vm.isProcessing, !readOnly, let scope, life.accessScope == scope else { return }
        let chatID = vm.sessionId
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            do {
                try await NivoCoachConversationCoordinator.shared.command(action, targetID: targetID, scope: scope)
                await context.refresh(sessionID: chatID)
                guard life.accessScope == scope, vm.sessionId == chatID else { return }
                if beginTeaching { vm.nmSendNow(AppLocalized("Continue learning")) }
            } catch {
                if life.accessScope == scope, vm.sessionId == chatID { errorMessage = NivoLifeModel.message(error) }
            }
        }
    }
}

/// 弹层退出过程中保留原消息及账户代次，不从之后出现的聊天推断目标。
private struct NivoCoachSourceRequestTarget {
    let chatID: String
    let messageID: String
    let scope: NivoLifeScope
}
