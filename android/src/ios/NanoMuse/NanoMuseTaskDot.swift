import SwiftUI
import Combine

/// 外壳保留透明聊天时显式撤销查看状态，经典布局默认由页面生命周期决定。
private struct NanoMuseRunVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 当前聊天层是否在外壳前台展示。
    var nmRunLayerVisible: Bool {
        get { self[NanoMuseRunVisibilityKey.self] }
        set { self[NanoMuseRunVisibilityKey.self] = newValue }
    }
}

/// 由真实模型运行驱动抽屉状态，页面卸载后仍能结算。
@MainActor
final class NanoMuseRunLedger: ObservableObject {
    static let shared = NanoMuseRunLedger()
    @Published private(set) var state = NanoMuseRunLedgerState()
    private var previousErrors: [UUID: (id: UUID?, error: String?)] = [:]
    private var scopeObservation: AnyCancellable?
    var running: Set<String> { state.running }
    var outcomes: [String: Bool] { state.outcomes }

    private init() {
        scopeObservation = NivoLifeModel.shared.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.synchronizeContext() }
    }

    /// 在isProcessing进入运行状态时调用，避免依赖视图onChange的交付顺序。
    func began(_ vm: AIChatViewModel) {
        synchronizeContext()
        let token = vm.nmRunLedgerToken
        guard state.runs[token] == nil else { return }
        let last = vm.messages.last { $0.role == .assistant }
        previousErrors[token] = (last?.id, last?.error)
        state.begin(token, session: vm.nmSessionKey)
    }

    /// 最后助手行上的错误和顶层错误均属于失败，不把用户停止标为完成。
    func ended(_ vm: AIChatViewModel) {
        synchronizeContext()
        let token = vm.nmRunLedgerToken
        guard state.runs[token] != nil else { return }
        let baseline = previousErrors.removeValue(forKey: token)
        let last = vm.messages.last { $0.role == .assistant }
        let hasNewAssistantError = last?.error != nil &&
            (last?.id != baseline?.id || last?.error != baseline?.error || vm.turnStartedByRetry)
        state.rebind(token, session: vm.nmSessionKey)
        let outcome: NanoMuseRunLedgerState.Outcome = vm.userDidCancel ? .cancelled :
            (vm.errorMessage != nil || hasNewAssistantError ? .failed : .completed)
        state.finish(token, outcome: outcome)
    }

    /// 草稿转换为会话时立即迁移运行提示，不等到运行结束。
    func rebind(_ vm: AIChatViewModel) {
        synchronizeContext()
        state.rebind(vm.nmRunLedgerToken, session: vm.nmSessionKey)
    }

    /// 模型对象被释放时清理残留运行，重启本来也不保留这些临时状态。
    func abandon(_ token: UUID) {
        previousErrors.removeValue(forKey: token)
        state.finish(token, outcome: .cancelled)
    }

    /// 查看状态按页面令牌登记，离开页面或进入后台时撤销。
    func setViewing(_ token: UUID, session: String?) {
        synchronizeContext()
        state.setViewing(token, session: session)
    }

    private func synchronizeContext() {
        let context = NanoMuseRunLedgerContext(ownerKey: NanoMuseAccountData.shared.current,
                                               generation: NivoLifeModel.shared.accessScope?.generation)
        guard state.context != context else { return }
        previousErrors.removeAll()
        state.bind(context)
    }
}

/// 可见且在前台才算看过结果，覆盖页面退出和后台运行两种情况。
struct NanoMuseRunViewing: ViewModifier {
    let session: String?
    let visible: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.nmRunLayerVisible) private var layerVisible
    @State private var token = UUID()
    @State private var hasAppeared = false
    @ObservedObject private var life = NivoLifeModel.shared

    private var shown: String? { visible && layerVisible && hasAppeared && scenePhase == .active ? session : nil }

    func body(content: Content) -> some View {
        content
            .onAppear { hasAppeared = true; publish() }
            .onDisappear { hasAppeared = false; NanoMuseRunLedger.shared.setViewing(token, session: nil) }
            .nmOnChange(of: shown) { _ in publish() }
            .nmOnChange(of: life.accessScope) { _ in publish() }
    }

    private func publish() { NanoMuseRunLedger.shared.setViewing(token, session: shown) }
}

/// 仅运行中创建呼吸动画；减少动态效果开启时使用静止圆点。
struct NanoMuseTaskDot: View {
    let session: String
    @ObservedObject private var ledger = NanoMuseRunLedger.shared
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let running = ledger.running.contains(session)
        let outcome = ledger.outcomes[session]
        if running || outcome != nil {
            Circle()
                .fill(color(running: running, outcome: outcome))
                .frame(width: 9, height: 9)
                .opacity(running && !reduceMotion && dim ? 0.25 : 1)
                .animation(running && !reduceMotion ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true) : .default, value: dim)
                .onAppear { dim = running && !reduceMotion }
                .nmOnChange(of: running) { dim = $0 && !reduceMotion }
                .nmOnChange(of: reduceMotion) { dim = running && !$0 }
                .accessibilityLabel(Text(label(running: running, outcome: outcome)))
        }
    }

    private func color(running: Bool, outcome: Bool?) -> Color {
        if running { return Color(red: 0.957, green: 0.729, blue: 0.208) }
        if outcome == false { return Color(red: 0.867, green: 0.325, blue: 0.325) }
        return Color(red: 0.259, green: 0.686, blue: 0.447)
    }

    private func label(running: Bool, outcome: Bool?) -> String {
        if running { return AppLocalized("Task Running") }
        return AppLocalized(outcome == false ? "Task failed" : "Task completed")
    }
}
