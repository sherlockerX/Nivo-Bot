import Foundation

/// Reads and writes PendingShare data to the App Group shared container.
/// Compiled into both the main app target and the Share Extension target.
enum SharedContainerStore {
    // nanoMuse: 与主App和扩展共用容器标识及可用性判定。
    static let appGroupID = NivoStoragePaths.appGroupID

    private static let pendingShareKey = "pendingShare"

    static var sharedDefaults: UserDefaults? {
        // nanoMuse: suiteName返回非空不代表具有共享权限；扩展无权限时禁止本地伪写入。
        if NivoStoragePaths.hasSharedContainer { return UserDefaults(suiteName: appGroupID) }
        return NivoStoragePaths.isExtension ? nil : .standard
    }

    /// Directory in the shared container for transferring attachment files.
    static var sharedFileDirectory: URL? {
        // nanoMuse: App内导入可用本地目录；扩展只允许真正共享的传输目录。
        NivoStoragePaths.layout.transferDirectory(isExtension: NivoStoragePaths.isExtension)
    }

    // MARK: - Write (called by Share Extension)

    // nanoMuse: 把保存失败交还调用方，不能静默把未交付内容报告为成功。
    @discardableResult
    static func savePendingShare(_ share: PendingShare) -> Bool {
        guard let defaults = sharedDefaults, sharedFileDirectory != nil else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(share) {
            defaults.set(data, forKey: pendingShareKey)
            defaults.synchronize()
            return true
        }
        return false
    }

    // MARK: - Read & Consume (called by main app)

    static func loadPendingShare() -> PendingShare? {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: pendingShareKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingShare.self, from: data)
    }

    static func clearPendingShare() {
        sharedDefaults?.removeObject(forKey: pendingShareKey)
        sharedDefaults?.synchronize()
    }

    /// Remove all files from the shared transfer directory.
    static func cleanSharedFiles() {
        guard let dir = sharedFileDirectory else { return }
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }
}
