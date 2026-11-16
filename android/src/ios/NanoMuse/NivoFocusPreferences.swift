import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 图片选择只保存账号哈希和随机图片标识，删除账号时同时清除偏好。
enum NivoFocusPreferences {
    /// 账户路径与偏好键使用同一不可逆标识，不保存原始账户名称。
    static func ownerHash(_ owner: String) -> String {
        SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 最近选择只供下一次开始前预选，不改变已经开始的会话。
    static func background(owner: String, defaults: UserDefaults = .standard) -> String {
        validBackground(defaults.string(forKey: key("background", owner: owner)))
    }

    /// 保存账户自己的图库选择，空标识代表默认矢量背景。
    static func setBackground(_ id: String, owner: String, defaults: UserDefaults = .standard) {
        defaults.set(validBackground(id), forKey: key("background", owner: owner))
    }

    /// 与安卓一致，只保留最近一次由页面开始的会话绑定；AI开始的会话使用默认背景。
    static func bindBackground(_ id: String, sessionID: String, owner: String, defaults: UserDefaults = .standard) {
        defaults.set(["sessionID": sessionID, "backgroundID": validBackground(id)],
                     forKey: key("sessionBackground", owner: owner))
    }

    /// 重入全屏及进程恢复读取开始时的绑定，绝不回退到最近选择。
    static func background(forSession sessionID: String, owner: String, defaults: UserDefaults = .standard) -> String {
        let binding = defaults.dictionary(forKey: key("sessionBackground", owner: owner))
        guard binding?["sessionID"] as? String == sessionID else { return "" }
        return validBackground(binding?["backgroundID"] as? String)
    }

    /// 图库删除同时解除选中和会话引用，保留会话自身与专注时长。
    static func removeBackground(_ id: String, owner: String, defaults: UserDefaults = .standard) {
        if background(owner: owner, defaults: defaults) == id {
            defaults.removeObject(forKey: key("background", owner: owner))
        }
        let binding = defaults.dictionary(forKey: key("sessionBackground", owner: owner))
        if binding?["backgroundID"] as? String == id {
            defaults.removeObject(forKey: key("sessionBackground", owner: owner))
        }
    }

    /// 全屏恢复标识按账户保存，另一账户的页面退出不会清除它。
    static func immersiveSession(owner: String, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: key("immersive", owner: owner)) ?? ""
    }

    /// 仅记录已经存在的会话；调用方先核验仓库，不凭此偏好启动计时。
    static func rememberImmersive(_ sessionID: String, owner: String, defaults: UserDefaults = .standard) {
        defaults.set(sessionID, forKey: key("immersive", owner: owner))
    }

    /// 迟到的关闭回调只能清除自己打开的会话，不影响后开的计时。
    static func dismissImmersive(_ sessionID: String, owner: String, defaults: UserDefaults = .standard) {
        guard immersiveSession(owner: owner, defaults: defaults) == sessionID else { return }
        defaults.removeObject(forKey: key("immersive", owner: owner))
    }

    /// 两种布局共用冷启动恢复，失效、删除或外账户记录均不自动打开。
    static func restorableSession(owner: String, sessions: [NivoFocusSession], defaults: UserDefaults = .standard) -> String? {
        migrateLegacyImmersive(owner: owner, sessions: sessions, defaults: defaults)
        let identifier = immersiveSession(owner: owner, defaults: defaults)
        return sessions.contains { $0.id == identifier && $0.ownerKey == owner && $0.deletedAt == nil }
            ? identifier : nil
    }

    /// 常亮由当前账户明确选择，首次使用默认允许系统自动息屏。
    static func keepAwake(owner: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key("keepAwake", owner: owner))
    }

    /// 不跨账户复制屏幕常亮设置。
    static func setKeepAwake(_ value: Bool, owner: String, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key("keepAwake", owner: owner))
    }

    /// 删除账户时清理其全部展示偏好，保留其他账户数据。
    static func remove(owner: String, defaults: UserDefaults = .standard) {
        for field in ["background", "sessionBackground", "immersive", "keepAwake"] {
            defaults.removeObject(forKey: key(field, owner: owner))
        }
    }

    private static func key(_ field: String, owner: String) -> String {
        "nivo.focus." + field + "." + ownerHash(owner)
    }

    private static func validBackground(_ id: String?) -> String {
        guard let id, UUID(uuidString: id) != nil else { return "" }
        return id
    }

    /// 旧全局偏好只有在仓库证实归属后迁移，不能让先登录的其他账户认领。
    private static func migrateLegacyImmersive(owner: String, sessions: [NivoFocusSession], defaults: UserDefaults) {
        guard let identifier = defaults.string(forKey: "nivo.focus.immersive"),
              sessions.contains(where: { $0.id == identifier && $0.ownerKey == owner && $0.deletedAt == nil }) else { return }
        if defaults.object(forKey: key("immersive", owner: owner)) == nil {
            rememberImmersive(identifier, owner: owner, defaults: defaults)
            if defaults.object(forKey: key("sessionBackground", owner: owner)) == nil {
                bindBackground(background(owner: owner, defaults: defaults), sessionID: identifier, owner: owner, defaults: defaults)
            }
            if defaults.object(forKey: key("keepAwake", owner: owner)) == nil {
                setKeepAwake(defaults.bool(forKey: "nivo.focus." + "keepAwake"), owner: owner, defaults: defaults)
            }
        }
        defaults.removeObject(forKey: "nivo.focus.immersive")
        defaults.removeObject(forKey: "nivo.focus." + "keepAwake")
    }
}
