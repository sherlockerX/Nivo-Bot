import Foundation
import XCTest
@testable import Minis

/// 验证侧载权限缺失时的生产路径策略，不依赖签名证书或Apple共享容器服务。
final class NivoStoragePathsTests: XCTestCase {
    /// 有共享权限时必须延用历史布局，避免升级后把已有数据表现为空。
    func testSharedContainerPreservesExistingPaths() {
        let group = URL(fileURLWithPath: "/existing-group", isDirectory: true)
        let layout = NivoStorageLayout(sharedContainer: group,
                                       libraryDirectory: URL(fileURLWithPath: "/app/Library", isDirectory: true))
        XCTAssertEqual(layout.applicationContainer, group)
        XCTAssertEqual(layout.applicationFiles, group.appendingPathComponent("MinisFileProvider", isDirectory: true))
        XCTAssertEqual(layout.applicationConfig, group.appendingPathComponent("MinisConfig", isDirectory: true))
        XCTAssertEqual(layout.extensionFiles, layout.applicationFiles)
        XCTAssertEqual(layout.transferDirectory(isExtension: true), layout.transferDirectory(isExtension: false))
    }

    /// 主App的所有原共享数据根使用同一个持久容器，不能落到缓存或临时目录。
    func testMissingGroupUsesOnePersistentMainAppContainer() {
        let library = URL(fileURLWithPath: "/app/Library", isDirectory: true)
        let layout = NivoStorageLayout(sharedContainer: nil, libraryDirectory: library)
        let container = library.appendingPathComponent("NivoLocalContainer", isDirectory: true)
        XCTAssertEqual(layout.applicationContainer, container)
        XCTAssertEqual(layout.applicationFiles.deletingLastPathComponent(), container)
        XCTAssertEqual(layout.applicationConfig.deletingLastPathComponent(), container)
        XCTAssertEqual(layout.transferDirectory(isExtension: false)?.deletingLastPathComponent(), container)
    }

    /// 扩展权限缺失时没有任何回退根，无法写出主App看不到的伪共享数据。
    func testMissingGroupNeverProvidesAnExtensionFallback() {
        let extensionLibrary = URL(fileURLWithPath: "/extension/Library", isDirectory: true)
        let layout = NivoStorageLayout(sharedContainer: nil, libraryDirectory: extensionLibrary)
        XCTAssertNil(layout.sharedContainer)
        XCTAssertNil(layout.extensionFiles)
        XCTAssertNil(layout.transferDirectory(isExtension: true))
        XCTAssertNotNil(layout.transferDirectory(isExtension: false))
    }

    /// 路径查询只能计算位置，不能触发迁移、创建目录或改写历史文件。
    func testResolvingPathsDoesNotModifyExistingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("existing-data")
        let data = Data("unchanged".utf8)
        try data.write(to: marker)
        let layout = NivoStorageLayout(sharedContainer: nil, libraryDirectory: directory)
        _ = layout.applicationFiles
        _ = layout.applicationConfig
        _ = layout.transferDirectory(isExtension: false)
        XCTAssertEqual(try Data(contentsOf: marker), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing-data"])
    }

    /// 两次启动分别按实际权限解析，权限恢复时共享布局不被先前本地路径替代。
    func testRestoredGroupUsesOriginalSharedLayoutWithoutMovingLocalFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = NivoStorageLayout(sharedContainer: nil, libraryDirectory: directory)
        try FileManager.default.createDirectory(at: local.applicationConfig, withIntermediateDirectories: true)
        let marker = local.applicationConfig.appendingPathComponent("local-record")
        try Data("local".utf8).write(to: marker)
        let group = directory.appendingPathComponent("actual-shared-container", isDirectory: true)
        let restored = NivoStorageLayout(sharedContainer: group, libraryDirectory: directory)
        XCTAssertEqual(restored.applicationContainer, group)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "local")
        XCTAssertFalse(FileManager.default.fileExists(atPath: group.path))
    }
}
