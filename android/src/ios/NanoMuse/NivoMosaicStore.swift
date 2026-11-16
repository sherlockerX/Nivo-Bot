import Foundation
import CryptoKit

/// 旧碎片文件迁移边界；新数据只写入生活事务容器，不维护第二份可变快照。
actor NivoMosaicStore {
    static let shared = NivoMosaicStore(directory: NanoMuseDirs.root.appendingPathComponent("mosaic", isDirectory: true))
    private let directory: URL
    private var activeScope: NivoLifeScope?

    init(directory: URL) { self.directory = directory }

    /// 宿主先取得生活仓库凭证，再迁移旧文件；源文件保留供备份和故障恢复。
    func bind(scope: NivoLifeScope, repository: NivoLifeRepository) async throws {
        activeScope = scope
        if try await repository.hasMosaic(scope: scope) {
            guard activeScope == scope else { throw NivoLifeError.accountChanged }
            await NivoMosaicMediaStore.shared.bind(scope: scope)
            return
        }
        let path = fileURL(scope.ownerKey)
        let legacy: NivoMosaicState
        if FileManager.default.fileExists(atPath: path.path) {
            let data = try Data(contentsOf: path)
            guard data.count <= NivoLifeValidation.maximumStoreBytes else { throw NivoLifeError.corruptStore }
            legacy = try JSONDecoder().decode(NivoMosaicState.self, from: data)
        } else { legacy = NivoMosaicState(ownerKey: scope.ownerKey) }
        try await repository.importMosaic(legacy, scope: scope)
        guard activeScope == scope else { throw NivoLifeError.accountChanged }
        await NivoMosaicMediaStore.shared.bind(scope: scope)
    }

    /// 退出账户先撤销照片读写能力，迟到的选择器回调不能重新创建目录。
    func close() async {
        activeScope = nil
        await NivoMosaicMediaStore.shared.revoke()
    }

    /// 删除只定位指定账户的旧数据和媒体目录；新容器由生活仓库删除。
    func removeAccount(ownerKey: String) async throws {
        if activeScope?.ownerKey == ownerKey { await close() }
        let folder = fileURL(ownerKey).deletingLastPathComponent()
        let resolvedParent = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard folder.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().pathComponents == resolvedParent.pathComponents else {
            throw NivoLifeError.invalidField("account_path")
        }
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try await NivoMosaicMediaStore.shared.removeAccount(ownerKey: ownerKey)
    }

    private func fileURL(_ ownerKey: String) -> URL {
        let digest = SHA256.hash(data: Data(ownerKey.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest, isDirectory: true).appendingPathComponent("state.json")
    }
}
