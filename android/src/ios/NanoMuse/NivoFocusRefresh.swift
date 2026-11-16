import SwiftUI

/// 仅前台可见的计时页面检查到期，锁屏后由系统通知及下次前台恢复结算。
@MainActor
struct NivoFocusRefresh: ViewModifier {
    @ObservedObject var model: NivoLifeModel
    var isVisible = true
    @Environment(\.scenePhase) private var scenePhase

    private var refreshID: NivoFocusRefreshIdentity? {
        guard isVisible, scenePhase == .active, let scope = model.accessScope,
              let session = model.activeFocus, session.status == .running else { return nil }
        return NivoFocusRefreshIdentity(scope: scope, sessionID: session.id)
    }

    /// 切号、暂停、结束、收起或进入后台均取消当前轮询。
    func body(content: Content) -> some View {
        content.task(id: refreshID) {
            guard let identity = refreshID else { return }
            while !Task.isCancelled, refreshID == identity {
                await model.refreshFocusIfNeeded()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
            }
        }
    }
}

/// 账户代次改变会取消旧任务，即便恢复后的会话仍使用同一标识。
private struct NivoFocusRefreshIdentity: Hashable {
    var scope: NivoLifeScope
    var sessionID: String
}
