import Foundation
import UIKit
import UserNotifications

// MARK: - Types

struct HubDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String   // phone | computer | web
    let os: String
    let version: String
    let online: Bool
    let lastSeen: Date?
    /// The hub actions the device answers (`coding.sessions`, `shell`, …); empty when it did not say.
    let actions: [String]

    var isPhone: Bool { kind == "phone" }
    var isComputer: Bool { kind == "computer" }

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        name = (json["name"] as? String) ?? id
        kind = (json["kind"] as? String) ?? "computer"
        os = (json["os"] as? String) ?? ""
        version = (json["version"] as? String) ?? ""
        online = (json["online"] as? Bool) ?? false
        actions = (json["actions"] as? [String]) ?? []
        if let t = json["last_seen"] as? Double, t > 0 { lastSeen = Date(timeIntervalSince1970: t) } else { lastSeen = nil }
    }
}

struct HubError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// A failure from the hub or from a computer, said in the phone's language: Android's
/// `HubErrors.describe`. The codes are the relay's (`cloud/nanomuse_cloud/hub.py`) and the
/// runtime's coding service's (`nanomuse/coding/service.py`); anything else is one plain
/// sentence, and the computer's own words stay in the log.
enum NanoMuseHubErrors {
    static func describe(_ error: Error) -> String {
        guard let hub = error as? HubError else { return AppLocalized("The computer could not do it.") }
        return describe(code: hub.code, message: hub.message)
    }

    static func describe(code: String, message: String = "") -> String {
        switch code {
        case "disconnected", "closed": return AppLocalized("Not connected to the hub right now.")
        case "timeout": return AppLocalized("The computer did not answer in time.")
        case "device_offline", "no_device": return AppLocalized("That computer is offline.")
        case "busy": return AppLocalized("The computer is busy with another run; try again in a moment.")
        case "not_controllable", "self_call": return AppLocalized("That device cannot be asked to do things.")
        case "unknown_agent": return AppLocalized("That coding agent is not on the computer.")
        case "no_session": return AppLocalized("That session is not on the computer any more.")
        case "unknown_action": return AppLocalized("The computer runs an older nanoMuse that does not know this action.")
        case "bad_key", "bad_device": return AppLocalized("Signed out on the relay; sign in again.")
        default:
            if !message.isEmpty { AppLogger(category: "NanoMuseHub").info("hub failure \(code): \(message)") }
            return AppLocalized("The computer could not do it.")
        }
    }
}

// MARK: - The hub

/// 旧设备记录的兼容接口。远程中继已移除，不建立连接或接受远端操作。
@MainActor
final class NanoMuseHub: ObservableObject {
    static let shared = NanoMuseHub()
    static let actions: [String] = []
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    enum State: Equatable {
        case idle, connecting, connected, reconnecting, paused, replaced, refused
        case error(String)
    }

    @Published private(set) var connected = false
    @Published private(set) var devices: [HubDevice] = []
    @Published private(set) var state = State.idle

    private init() {}

    /// 旧开关不能恢复已移除的远程服务。
    var enabled: Bool { get { false } set {} }
    var remoteControl: Bool { get { false } set {} }
    var others: [HubDevice] { [] }
    var webConsoleURL: String { "" }

    /// 历史消息只读取本机原标识，不向服务端登记。
    var deviceId: String {
        UserDefaults.standard.string(forKey: "nanomuse.hub.device_id") ?? "local-device"
    }

    var name: String {
        get { UserDefaults.standard.string(forKey: "nanomuse.hub.name") ?? UIDevice.current.name }
        set { UserDefaults.standard.set(newValue, forKey: "nanomuse.hub.name") }
    }

    /// 保留旧调用点的停止语义，不创建计时器或后台重连。
    func autoStart() {}
    func start() {}
    func stop() {}
    func restart() {}
    func abandon(_ id: String) {}
    func forget(_ deviceId: String) {}
    func find(_ query: String?) -> HubDevice? { nil }

    static func newCallId() -> String { String(UUID().uuidString.lowercased().prefix(12)) }

    /// 对旧快捷指令明确返回功能已移除，不等待永远不会到达的远端响应。
    func call(to: String, action: String, args: [String: Any] = [:], timeout: TimeInterval = 120,
              id given: String? = nil, onEvent: (([String: Any]) -> Void)? = nil) async throws -> [String: Any] {
        throw NivoLocalModeError.cloudRemoved
    }
}
