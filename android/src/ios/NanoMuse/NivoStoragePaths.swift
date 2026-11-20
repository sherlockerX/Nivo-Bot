import Foundation

/// 共享容器与主App本地容器的路径策略；计算路径不创建目录或迁移数据。
struct NivoStorageLayout: Equatable, Sendable {
    let sharedContainer: URL?
    let localContainer: URL

    /// 共享权限有效时保持旧目录；侧载无权限时只使用主App自己的Library目录。
    init(sharedContainer: URL?, libraryDirectory: URL) {
        self.sharedContainer = sharedContainer
        localContainer = libraryDirectory.appendingPathComponent("NivoLocalContainer", isDirectory: true)
    }

    var applicationContainer: URL { sharedContainer ?? localContainer }
    var applicationFiles: URL { applicationContainer.appendingPathComponent("MinisFileProvider", isDirectory: true) }
    var applicationConfig: URL { applicationContainer.appendingPathComponent("MinisConfig", isDirectory: true) }
    var extensionFiles: URL? { sharedContainer?.appendingPathComponent("MinisFileProvider", isDirectory: true) }

    /// 扩展不能回退到自身沙盒，否则会制造主App无法读取的伪共享数据。
    func transferDirectory(isExtension: Bool) -> URL? {
        let container = isExtension ? sharedContainer : applicationContainer
        return container?.appendingPathComponent("ShareExtension", isDirectory: true)
    }
}

/// 所有主App存储入口使用同一份进程内路径决策，扩展只接受真正的共享容器。
enum NivoStoragePaths {
    static let appGroupID = "group.io.github.nanomuse.app"

    #if os(iOS)
    // entitlement在进程生命周期内不变，固定决策避免同一次运行切换目录。
    static let layout = NivoStorageLayout(
        sharedContainer: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
        libraryDirectory: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library", isDirectory: true)
    )

    static var isExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
            || Bundle.main.object(forInfoDictionaryKey: "NSExtension") != nil
    }

    static var hasSharedContainer: Bool { layout.sharedContainer != nil }

    /// 跨进程动作在缺少App Group时明确失败，调用前不初始化存储或发送通知。
    static func requireSharedContainer() throws {
        guard hasSharedContainer else { throw CocoaError(.fileReadNoPermission) }
    }
    #endif
}
