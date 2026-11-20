import Foundation

/// 编辑器只把尚未创建的文件视为空白，其他读取错误必须交给界面处理。
enum NivoEditableText {
    static func readIfPresent(_ file: URL) throws -> String {
        do { return try String(contentsOf: file, encoding: .utf8) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return ""
        }
    }

    /// 训练偏好仅在首次打开或确实为空时使用默认值。
    static func preferences(at file: URL, fallback: String) throws -> String {
        let text = try readIfPresent(file).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }
}
