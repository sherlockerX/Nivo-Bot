import Foundation

/// 应用目录绑定留在宿主，便携回归直接运行相同仓库并使用独立临时目录。
extension NivoCoachV2Store {
    static let shared = NivoCoachV2Store(directory: NanoMuseDirs.root.appendingPathComponent("coach-v2", isDirectory: true))
}
