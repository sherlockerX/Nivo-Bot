import Foundation
import UserNotifications

/// 到期提醒由系统调度，后台不运行每秒计时器；权限只在用户开始专注时请求。
@MainActor
final class NivoFocusNotifications {
    static let shared = NivoFocusNotifications()
    private var scheduledIdentifier = UserDefaults.standard.string(forKey: "nivo.focus.notification")
    private var scheduledSession: NivoFocusSession?
    private var generation = UUID()

    /// 不强制要求提醒权限，拒绝通知仍可正常专注。
    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        // 同一会话可能在权限弹窗前已提交，授权后重新补排提醒。
        let active = scheduledSession
        scheduledSession = nil
        update(session: active)
    }

    /// 仅会话边界变化时重排提醒，持续刷新界面不反复操作通知中心。
    func update(session: NivoFocusSession?) {
        guard session != scheduledSession || (session == nil && scheduledIdentifier != nil) else { return }
        cancel()
        scheduledSession = session
        guard let session, session.status == .running else { return }
        let token = generation
        let identifier = "nivo.focus." + token.uuidString
        scheduledIdentifier = identifier
        UserDefaults.standard.set(identifier, forKey: "nivo.focus.notification")
        let remaining = session.targetMs - NivoFocusRules.currentElapsed(session, clock: NivoLifeClock.sample())
        guard remaining > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = AppLocalized(session.mode == .rest ? "Break finished" : "Focus finished")
        content.body = AppLocalized("Open to review this session.")
        content.sound = .default
        content.userInfo = ["nivoRoom": "focus", "nivoFocusID": session.id]
        let request = UNNotificationRequest(identifier: identifier, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(
                                                timeInterval: max(1, Double(remaining) / 1_000), repeats: false))
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
                if token != generation {
                    // 已暂停或切换账户的旧请求不可在异步提交后复活。
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
                }
            } catch {
                AppLogger(category: "NivoFocus").warning("focus reminder scheduling failed")
            }
        }
    }

    /// 暂停、结束或退出账号立即取消本模块的提醒，不触及其他闹钟。
    func cancel() {
        generation = UUID()
        scheduledSession = nil
        let center = UNUserNotificationCenter.current()
        if let identifier = scheduledIdentifier {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
        scheduledIdentifier = nil
        UserDefaults.standard.removeObject(forKey: "nivo.focus.notification")
    }
}
