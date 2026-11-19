import Foundation
import UIKit

/// 历史云头像的数据结构兼容层，所有网络能力已移除。
enum NanoMuseRelayMedia {
    struct Estimate: Equatable {
        var cny: Double
        var leftCny: Double?
        var unlimited: Bool
        var affordable: Bool
        var inviteBonusCny: Double?
    }

    struct Profile {
        var rev: Int
        var name: String
        var avatar: String
        /// The emoji look's glyph and `#rrggbb` (#435); empty unless `avatar` is `emoji`.
        var emoji: String
        var color: String
        var style: String
        var description: String
        var faceId: String
        var hasFace: Bool
        var face: [String: String]?
        /// Contract C3: which device of the account connected what (raw entries).
        var connectors: [[String: Any]]
    }

    struct Contribute: Equatable {
        var on: Bool
        var samples: Int
        var defaultOn: Bool
        var privacyURL: String
    }

    /// 旧生成入口不能回退到内置账号，用户自有图像API仍由独立提供商处理。
    @MainActor static func imageModel() async throws -> String { throw NivoLocalModeError.cloudRemoved }
    @MainActor static func estimate(images: Int, clips: Int = 0) async throws -> Estimate { throw NivoLocalModeError.cloudRemoved }
    @MainActor static func generate(prompt: String, model: String, size: String = "1024*1024") async throws -> UIImage { throw NivoLocalModeError.cloudRemoved }
    @MainActor static func edit(_ image: UIImage, prompt: String, model: String, size: String = "1024*1024") async throws -> UIImage { throw NivoLocalModeError.cloudRemoved }
    @MainActor static func profile(withFace: Bool) async throws -> Profile { throw NivoLocalModeError.cloudRemoved }
    @MainActor static func putProfile(_ body: [String: Any]) async throws -> Int { throw NivoLocalModeError.cloudRemoved }
    @MainActor static func setContribute(_ on: Bool) async throws -> Contribute { throw NivoLocalModeError.cloudRemoved }
    @MainActor static func contribute() async throws -> Contribute { throw NivoLocalModeError.cloudRemoved }
    @MainActor static func deleteSamples() async throws -> Int { throw NivoLocalModeError.cloudRemoved }
}

/// 名称、头像和连接器只保存在本机，旧通知不会上传资料。
@MainActor
final class NanoMuseProfileSync: ObservableObject {
    static let shared = NanoMuseProfileSync()
    @Published private(set) var syncing = false
    @Published private(set) var lastError: String?

    private init() {}

    func start() {}
    func pull() {}
    func onHubFrame(_ frame: [String: Any]) {}
    func faceChanged() {}
    func nameChanged(now: Bool = false) {}
    func connectorsChanged() {}

    /// 清除旧设备连接缓存，不改本机连接器配置或头像文件。
    func forget() {
        NanoMuseSharedConnectors.shared.forget()
        for key in ["nanomuse.profile.rev", "nanomuse.profile.pushed_connectors", "nanomuse.profile.pushed_name"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
