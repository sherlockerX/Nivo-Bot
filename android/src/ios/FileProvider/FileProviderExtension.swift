import FileProvider
import UniformTypeIdentifiers
import os.log

/// Replicated File Provider extension that exposes MinisFileProvider/ to the system Files app.
/// Structure: Minis → { memory, skills, shared }
/// Uses the modern NSFileProviderReplicatedExtension protocol (iOS 16+).
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    let domain: NSFileProviderDomain

    private static let log = OSLog(subsystem: "io.github.nanomuse.app.FileProvider", category: "Extension")

    /// Root directory for all FileProvider-visible files in the App Group container.
    // nanoMuse: 扩展仅访问真实共享目录，无权限时返回不可用，不创建扩展本地副本。
    static var providerRoot: URL? {
        NivoStoragePaths.layout.extensionFiles
    }

    /// The three top-level subdirectories exposed via the FileProvider.
    static let topLevelSubdirs = ["memory", "skills", "shared"]

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        let fm = FileManager.default
        // nanoMuse: 系统可能唤起上次签名遗留的域，初始化必须允许共享容器不可用。
        guard let root = Self.providerRoot else {
            os_log("FileProviderExtension unavailable: App Group access denied", log: Self.log, type: .error)
            return
        }
        for sub in Self.topLevelSubdirs {
            try? fm.createDirectory(at: root.appendingPathComponent(sub, isDirectory: true),
                                    withIntermediateDirectories: true)
        }
        os_log("FileProviderExtension init — domain: %{public}@, providerRoot: %{public}@",
               log: Self.log, type: .info,
               domain.identifier.rawValue, root.path)

        let resolvedRoot = root.resolvingSymlinksInPath().path
        var rootSummaries: [String] = []
        for sub in Self.topLevelSubdirs {
            let dir = root.appendingPathComponent(sub, isDirectory: true)
            let count = (try? fm.contentsOfDirectory(atPath: dir.path).count) ?? -1
            rootSummaries.append("\(sub)=\(count)")
        }
        // [T-ios-fp-mac-bootcrash] Stamp every SUCCESSFUL launch with the app
        // version and the executable's mtime. The pre-main SIGILL launches
        // (TestFlight D8_ZguC2Ikr7Wl0fRI7Ubn, macOS 27 beta) can never log —
        // dyld dies before our code runs — so the diagnosis has to come from
        // the other side: the main app appends an "app-updated" line to this
        // same trace file when the bundle changes, and each init line here
        // carries the executable generation. If a .crash timestamp falls
        // between an "app-updated" line and the next init with a NEW exec
        // mtime, the bundle-replacement theory is confirmed from field data.
        let bundle = Bundle.main
        let ver = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var execStamp = "?"
        if let execURL = bundle.executableURL,
           let mod = (try? fm.attributesOfItem(atPath: execURL.path))?[.modificationDate] as? Date {
            execStamp = ISO8601DateFormatter().string(from: mod)
        }
        let onMac = ProcessInfo.processInfo.isiOSAppOnMac
        FPSyncTraceLog.log("init domain=\(domain.identifier.rawValue) ver=\(ver)(\(build)) exec=\(execStamp) mac=\(onMac) providerRoot=\(root.path) resolved=\(resolvedRoot) [\(rootSummaries.joined(separator: " "))]")

        Self.recoverFakeTrashDirIfNeeded(root: root)
        Self.cleanupLegacyLogsDirIfNeeded(root: root)
        Self.cleanupLegacyMountedFoldersIfNeeded(root: root)
    }

    /// Delete leftover FileProvider extension log directories.
    /// Two historical locations exist:
    ///   1. `<providerRoot>/logs/` — original buggy location (leaked
    ///      into iOS Files).
    ///   2. `<App Group>/MinisConfig/logs/` — second iteration; private
    ///      to the app, but still grew unbounded with one log file
    ///      written per FileProvider invocation.
    /// Both are now dead — the extension no longer writes any file
    /// logs (relies on `os_log` only), so we delete whatever is there.
    private static func cleanupLegacyLogsDirIfNeeded(root: URL) {
        let fm = FileManager.default

        // Location 1: under providerRoot (would leak into iOS Files).
        let inProvider = root.appendingPathComponent("logs", isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: inProvider.path, isDirectory: &isDir), isDir.boolValue {
            try? fm.removeItem(at: inProvider)
        }

        // Location 2: under MinisConfig (private but still pure cruft).
        if let container = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.io.github.nanomuse.app") {
            let inConfig = container.appendingPathComponent("MinisConfig/logs", isDirectory: true)
            if fm.fileExists(atPath: inConfig.path, isDirectory: &isDir), isDir.boolValue {
                try? fm.removeItem(at: inConfig)
            }
        }
    }

    /// Delete a residual `mounted-folders.json` file that the main app
    /// already migrated to `MinisConfig/`. If both copies exist the main
    /// app prefers the current-location one and drops the legacy one,
    /// but if migration didn't run (e.g. extension launched first on a
    /// cold boot) we should still not expose the stale copy to Files.
    private static func cleanupLegacyMountedFoldersIfNeeded(root: URL) {
        let fm = FileManager.default
        let legacy = root.appendingPathComponent("mounted-folders.json")
        guard fm.fileExists(atPath: legacy.path) else { return }
        // Only delete if the canonical copy already exists under MinisConfig —
        // otherwise we'd lose the data.
        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.io.github.nanomuse.app") else { return }
        let canonical = container.appendingPathComponent("MinisConfig/mounted-folders.json")
        if fm.fileExists(atPath: canonical.path) {
            try? fm.removeItem(at: legacy)
        }
    }

    /// Clean up any leftover `NSFileProviderTrashContainerItemIdentifier`
    /// directory under providerRoot. Historical bug: `createItem` /
    /// `modifyItem` would happily use this literal string as a path
    /// component when iOS Files tried to move an item to trash, creating
    /// a real directory whose name collides with the system-reserved
    /// identifier. The framework then gets confused and paused syncing.
    ///
    /// Contents are moved into `shared/_recovered_trash/` so no data is
    /// lost, and the fake directory is removed.
    private static func recoverFakeTrashDirIfNeeded(root: URL) {
        let fm = FileManager.default
        let fakeTrash = root.appendingPathComponent("NSFileProviderTrashContainerItemIdentifier", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fakeTrash.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }

        let recovered = root.appendingPathComponent("shared/_recovered_trash", isDirectory: true)
        do {
            try fm.createDirectory(at: recovered, withIntermediateDirectories: true)
        } catch {
            return
        }

        if let entries = try? fm.contentsOfDirectory(atPath: fakeTrash.path) {
            for name in entries {
                let src = fakeTrash.appendingPathComponent(name)
                var dst = recovered.appendingPathComponent(name)
                var n = 1
                while fm.fileExists(atPath: dst.path) {
                    let ext = (name as NSString).pathExtension
                    let base = (name as NSString).deletingPathExtension
                    let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
                    dst = recovered.appendingPathComponent(candidate)
                    n += 1
                }
                try? fm.moveItem(at: src, to: dst)
            }
        }

        try? fm.removeItem(at: fakeTrash)
    }

    func invalidate() {
        os_log("FileProviderExtension invalidate", log: Self.log, type: .info)
    }

    // MARK: - Signal helper

    /// Notify the system that a container's contents changed so it re-enumerates.
    private func signalParent(_ parentIdentifier: NSFileProviderItemIdentifier) {
        NSFileProviderManager(for: domain)?.signalEnumerator(for: parentIdentifier) { error in
            if let error {
                os_log("signalEnumerator(%{public}@) error: %{public}@",
                       log: Self.log, type: .error,
                       parentIdentifier.rawValue, error.localizedDescription)
            }
        }
    }

    // MARK: - Item Lookup

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        // nanoMuse: 不向系统返回虚构的根目录或空数据集，保留原有缓存等待权限恢复。
        guard let root = Self.providerRoot else {
            completionHandler(nil, CocoaError(.fileReadNoPermission))
            return Progress()
        }
        os_log("item(for: %{public}@)", log: Self.log, type: .debug, identifier.rawValue)
        if identifier == .rootContainer {
            // nanoMuse: 条目持有本次已验证的共享根目录，不再隐式重取可空路径。
            completionHandler(FileProviderItem(url: root, parentIdentifier: .rootContainer, providerRoot: root, isRoot: true), nil)
            return Progress()
        }
        if identifier == .trashContainer {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        // nanoMuse: 使用已验证的共享根目录。
        let url = root.appendingPathComponent(identifier.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let parentPath = (identifier.rawValue as NSString).deletingLastPathComponent
        let parentID = parentPath.isEmpty
            ? NSFileProviderItemIdentifier.rootContainer
            : NSFileProviderItemIdentifier(parentPath)
        // nanoMuse: 传递本次操作的共享根目录。
        completionHandler(FileProviderItem(url: url, parentIdentifier: parentID, providerRoot: root), nil)
        return Progress()
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        // nanoMuse: 权限缺失是读取错误，不能伪装成目录为空导致系统误判删除。
        guard let root = Self.providerRoot else { throw CocoaError(.fileReadNoPermission) }
        os_log("enumerator(for: %{public}@)", log: Self.log, type: .info, containerItemIdentifier.rawValue)

        switch containerItemIdentifier {
        case .rootContainer:
            // nanoMuse: 枚举器仅持有经验证的真实共享目录。
            return FileProviderEnumerator(containerItemIdentifier: .rootContainer, providerRoot: root)
        case .workingSet:
            // nanoMuse: 递归枚举与普通枚举使用同一根目录。
            return FileProviderEnumerator(containerItemIdentifier: .rootContainer, providerRoot: root, recursive: true)
        case .trashContainer:
            // nanoMuse: 不为无权限的扩展创建本地垃圾桶。
            return FileProviderEnumerator(containerItemIdentifier: .trashContainer, providerRoot: root)
        default:
            // nanoMuse: 子目录继续使用已经检查过的根目录。
            return FileProviderEnumerator(containerItemIdentifier: containerItemIdentifier, providerRoot: root)
        }
    }

    // MARK: - Fetch Contents

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        // nanoMuse: 无共享权限时不复制文件到扩展临时目录。
        guard let root = Self.providerRoot else {
            completionHandler(nil, nil, CocoaError(.fileReadNoPermission))
            return Progress()
        }
        let url = root.appendingPathComponent(itemIdentifier.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let parentPath = (itemIdentifier.rawValue as NSString).deletingLastPathComponent
        let parentID = parentPath.isEmpty
            ? NSFileProviderItemIdentifier.rootContainer
            : NSFileProviderItemIdentifier(parentPath)
        // nanoMuse: 返回条目与内容读取绑定到同一个共享根目录。
        let item = FileProviderItem(url: url, parentIdentifier: parentID, providerRoot: root)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let tempFile = tempDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: tempFile)
            completionHandler(tempFile, item, nil)
        } catch {
            completionHandler(nil, nil, error)
        }
        return Progress()
    }

    // MARK: - Create Item

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        // nanoMuse: 无共享权限时拒绝创建，不能写到主App不可访问的位置。
        guard let root = Self.providerRoot else {
            completionHandler(nil, [], false, CocoaError(.fileWriteNoPermission))
            return Progress()
        }
        // Block creation directly under root — only the fixed subdirs live there.
        // Block creation under memory/ or skills/ (read-only trees).
        // Block creation under trashContainer — we do not support a trash and
        // must not let iOS Files materialize a directory named after the
        // system-reserved identifier in providerRoot.
        let parentRaw = itemTemplate.parentItemIdentifier.rawValue
        if itemTemplate.parentItemIdentifier == .rootContainer
            || itemTemplate.parentItemIdentifier == .trashContainer
            || parentRaw == "memory" || parentRaw.hasPrefix("memory/")
            || parentRaw == "skills" || parentRaw.hasPrefix("skills/") {
            completionHandler(nil, [], false,
                              NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError))
            return Progress()
        }

        // nanoMuse: 创建只使用经验证的共享根目录。
        let parentURL = root.appendingPathComponent(itemTemplate.parentItemIdentifier.rawValue)
        let destURL = parentURL.appendingPathComponent(itemTemplate.filename)

        do {
            if itemTemplate.contentType == .folder {
                try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
            } else if let sourceURL = url {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            }
            // nanoMuse: 回执中的标识基于实际写入的根目录。
            let item = FileProviderItem(url: destURL, parentIdentifier: itemTemplate.parentItemIdentifier, providerRoot: root)
            completionHandler(item, [], false, nil)
            signalParent(itemTemplate.parentItemIdentifier)
        } catch {
            completionHandler(nil, [], false, error)
        }
        return Progress()
    }

    // MARK: - Modify Item

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        // nanoMuse: 无共享权限时拒绝修改，保留系统缓存及原有共享数据。
        guard let root = Self.providerRoot else {
            completionHandler(nil, [], false, CocoaError(.fileWriteNoPermission))
            return Progress()
        }
        let idRaw = item.itemIdentifier.rawValue

        // Block rename/move of the three fixed top-level subdirectories.
        if Self.topLevelSubdirs.contains(idRaw),
           changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
            completionHandler(nil, [], false,
                              NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError))
            return Progress()
        }

        // Block modifications to items under memory/ or skills/ (read-only).
        if idRaw.hasPrefix("memory/") || idRaw.hasPrefix("skills/") {
            completionHandler(nil, [], false,
                              NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError))
            return Progress()
        }

        // Block moving items into the trash — we don't support a trash and
        // must not materialize a "NSFileProviderTrashContainerItemIdentifier"
        // directory in providerRoot. iOS Files will fall back to a hard
        // delete when it can't use the trash.
        if changedFields.contains(.parentItemIdentifier),
           item.parentItemIdentifier == .trashContainer {
            completionHandler(nil, [], false,
                              NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError))
            return Progress()
        }

        // nanoMuse: 后续移动与覆盖共用已验证的共享根目录。
        let srcURL = root.appendingPathComponent(item.itemIdentifier.rawValue)

        do {
            var destURL = srcURL
            if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                let parentURL: URL
                if item.parentItemIdentifier == .rootContainer {
                    // nanoMuse: 不在操作中重新解析容器。
                    parentURL = root
                } else {
                    // nanoMuse: 子目录与源文件保持同一共享根目录。
                    parentURL = root.appendingPathComponent(item.parentItemIdentifier.rawValue)
                }
                destURL = parentURL.appendingPathComponent(item.filename)
                if srcURL != destURL {
                    try FileManager.default.moveItem(at: srcURL, to: destURL)
                }
            }

            if changedFields.contains(.contents), let newContents {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: newContents, to: destURL)
            }

            // nanoMuse: 修改回执保留经验证的根目录。
            let resultItem = FileProviderItem(url: destURL, parentIdentifier: item.parentItemIdentifier, providerRoot: root)
            completionHandler(resultItem, [], false, nil)
            signalParent(item.parentItemIdentifier)
        } catch {
            completionHandler(nil, [], false, error)
        }
        return Progress()
    }

    // MARK: - Delete Item

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        // nanoMuse: 无共享权限时拒绝删除，不能把未访问到的文件报告为已删除。
        guard let root = Self.providerRoot else {
            completionHandler(CocoaError(.fileWriteNoPermission))
            return Progress()
        }
        os_log("deleteItem id=%{public}@", log: Self.log, type: .info, identifier.rawValue)

        let idRaw = identifier.rawValue
        if Self.topLevelSubdirs.contains(idRaw)
            || idRaw.hasPrefix("memory/") || idRaw.hasPrefix("skills/") {
            completionHandler(NSError(domain: NSCocoaErrorDomain,
                                      code: NSFileWriteNoPermissionError))
            return Progress()
        }

        // nanoMuse: 删除仅针对已经验证的共享根目录。
        let url = root.appendingPathComponent(identifier.rawValue)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                os_log("deleteItem removeItem error: %{public}@",
                       log: Self.log, type: .error, error.localizedDescription)
                completionHandler(error)
                return Progress()
            }
        }

        // Derive parent identifier and signal it to re-enumerate.
        let parentPath = (identifier.rawValue as NSString).deletingLastPathComponent
        let parentID = parentPath.isEmpty
            ? NSFileProviderItemIdentifier.rootContainer
            : NSFileProviderItemIdentifier(parentPath)
        completionHandler(nil)
        signalParent(parentID)
        return Progress()
    }
}
