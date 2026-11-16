import Foundation
import Combine

/// 档案退出到聊天列表之间保留一次导航意图，任何读盘和滚动均由现有聊天宿主负责。
@MainActor
final class NivoCoachSourceNavigation: ObservableObject {
    static let shared = NivoCoachSourceNavigation()
    @Published private(set) var state = NivoCoachSourceNavigationState()
    private var scopeObservation: AnyCancellable?

    private init() {
        scopeObservation = NivoLifeModel.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.invalidateScope() }
    }

    /// 调用方必须携带档案打开时的账户凭证，不从新页面补取。
    func enqueue(chatID: String, messageID: String, scope: NivoLifeScope) {
        guard NivoLifeModel.shared.accessScope == scope, NanoMuseSync.shared.shows(chatID) else { return }
        var candidate = state
        _ = candidate.enqueue(chatID: chatID, messageID: messageID, scope: scope)
        state = candidate
    }

    /// 查询不消费意图，UIKit确认目标行已进入快照后再提交。
    func decision(for vm: AIChatViewModel, isVisible: Bool) -> NivoCoachSourceNavigationState.Decision {
        state.decision(scope: NivoLifeModel.shared.accessScope, chatID: vm.sessionId,
            isReady: vm.hasCompletedInitialLoad && !vm.isLoadingSession && !vm.streamingUIUpdatesSuspended,
            isVisible: isVisible && vm.sessionId.map { NanoMuseSync.shared.shows($0) } == true,
            messages: vm.messages.filter { !$0.isInternalBridge }.map {
                NivoCoachSourceMessageTarget(id: $0.id, sourceIDs: $0.nmSourceMessageIDs)
            })
    }

    /// 成功或明确不可用后移除同一请求，避免下一次页面出现再次跳转。
    func consume(_ identifier: UUID) {
        var candidate = state
        candidate.consume(identifier)
        if candidate != state { state = candidate }
    }

    private func invalidateScope() {
        var candidate = state
        candidate.invalidate(unless: NivoLifeModel.shared.accessScope)
        if candidate != state { state = candidate }
    }
}
