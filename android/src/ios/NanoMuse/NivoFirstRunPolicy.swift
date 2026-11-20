import Foundation

/// 本地首次使用规则：跳过后不再强制配置模型，历史对话也不重新触发引导。
enum NanoMuseFirstRun {
    private static let doneKey = "nanomuse.setup.done"
    static let notificationsKey = "nanomuse.setup.notifications_seen"

    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }
    /// 完成和跳过共享持久状态，重启后都直接进入本地功能。
    static func markDone() { UserDefaults.standard.set(true, forKey: doneKey) }
    static var notificationsSeen: Bool { UserDefaults.standard.bool(forKey: notificationsKey) }
    static func markNotificationsSeen() { UserDefaults.standard.set(true, forKey: notificationsKey) }

    /// 仅对尚未完成引导且没有历史会话的安装显示欢迎页。
    static func needed(hasSessions: Bool, done: Bool) -> Bool { !done && !hasSessions }

    enum Stage: Int { case welcome, models, notifications, meet }

    /// 无模型先给可跳过的欢迎页；本机通知和模型选择均可稍后配置。
    static func stage(hasProviders: Bool, hasGroups: Bool, modelsSkipped: Bool,
                      notificationsSeen: Bool = true) -> Stage {
        if !hasProviders { return .welcome }
        if !hasGroups && !modelsSkipped { return .models }
        if !notificationsSeen { return .notifications }
        return .meet
    }

    /// 模型、通知和开始使用对应三个进度点。
    static func dot(_ stage: Stage) -> Int {
        switch stage {
        case .welcome, .models: return 0
        case .notifications: return 1
        case .meet: return 2
        }
    }
}
