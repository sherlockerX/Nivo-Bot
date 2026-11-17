import Foundation
import Combine

/// 冷启动和热启动共享一次性导航意图，通知到达时界面尚未建立也不会丢失。
@MainActor
final class NivoLifeNavigation: ObservableObject {
    static let shared = NivoLifeNavigation()
    @Published private(set) var pendingRoom: String?
    @Published private(set) var focusTarget: String?
    @Published private(set) var focusTaskTarget: NivoLifeItemTarget?
    @Published private(set) var mosaicTarget: NivoLifeItemTarget?
    @Published private(set) var mosaicReflectionTarget: NivoLifeItemTarget?

    /// 仅接收支持的本地页面名称，不从链接执行数据修改。
    @discardableResult
    func open(_ room: String, focusID: String? = nil) -> Bool {
        guard ["todo", "focus", "mosaic", "routines", "coach", "ideas"].contains(room) else { return false }
        focusTaskTarget = nil
        mosaicTarget = nil
        mosaicReflectionTarget = nil
        focusTarget = room == "focus" ? focusID : nil
        pendingRoom = room
        return true
    }

    /// 宿主消费后清空，避免返回聊天后被历史通知再次跳转。
    func takePending() -> String? {
        defer { pendingRoom = nil }
        return pendingRoom
    }

    /// 会话是否属于当前账号由目标页面再次检查，通知本身不授予数据访问权。
    func takeFocusTarget() -> String? {
        defer { focusTarget = nil }
        return focusTarget
    }

    /// 待办详情关闭后预选关联任务，由专注页面决定返回已有计时或显示开始表单。
    func openFocus(taskID: String, scope: NivoLifeScope) {
        focusTarget = nil
        mosaicTarget = nil
        mosaicReflectionTarget = nil
        focusTaskTarget = NivoLifeItemTarget(id: taskID, scope: scope)
        pendingRoom = "focus"
    }

    /// 碎片只由显式点击打开，链接自身不读取照片或修改执行状态。
    func openMosaic(entryID: String, scope: NivoLifeScope) {
        focusTarget = nil
        focusTaskTarget = nil
        mosaicReflectionTarget = nil
        mosaicTarget = NivoLifeItemTarget(id: entryID, scope: scope)
        pendingRoom = "mosaic"
    }

    /// 全屏关闭后排队心得定位，宿主仍通过已有pendingRoom打开两种布局的碎片页。
    func openReflection(sessionID: String, scope: NivoLifeScope) {
        let target = NivoLifeItemTarget(id: sessionID, scope: scope)
        guard mosaicReflectionTarget != target else { return }
        focusTarget = nil
        focusTaskTarget = nil
        mosaicTarget = nil
        mosaicReflectionTarget = target
        pendingRoom = "mosaic"
    }

    /// 只有对应请求完成后才消费；异步读取迟到时不能清掉后来的点击。
    func handledReflection(_ target: NivoLifeItemTarget) {
        if mosaicReflectionTarget == target { mosaicReflectionTarget = nil }
    }

    /// 目标页完成加载后才消费任务意图。
    func takeFocusTaskTarget() -> NivoLifeItemTarget? {
        defer { focusTaskTarget = nil }
        return focusTaskTarget
    }

    /// 目标页完成加载后才消费碎片意图。
    func takeMosaicTarget() -> NivoLifeItemTarget? {
        defer { mosaicTarget = nil }
        return mosaicTarget
    }
}
