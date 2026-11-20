import AppIntents
import Foundation

/// Lists all chat sessions — useful for automation scripts that need a session ID.
struct ListSessionsIntent: AppIntent {
    static var title: LocalizedStringResource = "List Sessions"
    static var description = IntentDescription("Lists all nanoMuse chat sessions with their titles and IDs.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // nanoMuse: 侧载无共享权限时拒绝跨进程动作，先于读库、创建会话和启动后台任务。
        try NivoStoragePaths.requireSharedContainer()
        let sessions = await NanoMuseSync.shared.visible(await ChatStore.shared.listSessions()) // nanoMuse: C12 — another account's chats stay hidden

        if sessions.isEmpty {
            return .result(value: "No sessions found.")
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated

        let lines = sessions.map { session -> String in
            let title = session.title ?? "Untitled"
            let age = formatter.localizedString(for: session.updatedAt, relativeTo: Date())
            return "\(title) (\(age)) — \(session.id)"
        }

        return .result(value: lines.joined(separator: "\n"))
    }
}
