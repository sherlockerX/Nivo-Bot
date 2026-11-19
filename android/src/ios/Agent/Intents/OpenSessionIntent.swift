import AppIntents
import Foundation

/// Opens a specific chat session in the Minis app.
struct OpenSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Session"
    static var description = IntentDescription("Opens a nanoMuse chat session in the app.")
    static var openAppWhenRun = true

    @Parameter(title: "Session")
    var session: SessionEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        // nanoMuse: 侧载无共享权限时拒绝跨进程动作，先于读库、创建会话和启动后台任务。
        try NivoStoragePaths.requireSharedContainer()
        NotificationCenter.default.post(
            name: .openSessionFromIntent,
            object: nil,
            userInfo: ["sessionId": session.id]
        )
        return .result()
    }
}

extension Notification.Name {
    static let openSessionFromIntent = Notification.Name("openSessionFromIntent")
}
