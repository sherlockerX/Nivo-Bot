import Foundation

/// 按已登记的子项身份解析配置路径，允许模型ID和叶字段各自包含点号。
enum NivoConfigPath {
    /// 先尝试最长身份，调用方仍须用完整字段路径核对最终结果。
    static func childIDs(matching path: String, basePath: String, existingIDs: [String]) -> [String] {
        existingIDs.filter { identifier in
            let prefix = "\(basePath).\(identifier)."
            return !identifier.isEmpty && path.hasPrefix(prefix) && path.count > prefix.count
        }.sorted { $0.count > $1.count }
    }
}
