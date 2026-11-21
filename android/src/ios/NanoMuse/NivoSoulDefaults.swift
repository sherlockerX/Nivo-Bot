import Foundation

/// 生成默认SOUL模板，并判断远端默认种子是否应保留本地自定义内容。
enum NivoSoulDefaults {
    /// 生成与现有首次启动逻辑一致的完整模板，保留末尾换行。
    static func content(name: String) -> String {
        "---\nname: \"\(name)\"\nstyle: \"\"\nlang: \"auto\"\n---\n"
    }

    /// 仅匹配已核实的历史及当前完整模板，CRLF之外的内容差异均视为自定义。
    static func isDefaultContent(_ markdown: String) -> Bool {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let knownNames = ["nanoMuse", "Nivo Bot", "十七", "Shiqi"]
        return knownNames.contains { normalized == content(name: $0) }
    }

    /// 远端为默认种子且本地已有自定义内容时，继续沿用接收端保护语义。
    static func shouldPreserveLocalContent(local: String, remote: String) -> Bool {
        isDefaultContent(remote) && !isDefaultContent(local)
    }

    /// 仅为未经编辑的历史默认文件提供新内容，其他文件保持原样。
    static func migratedLegacyContent(_ markdown: String, assistantName: String) -> String? {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let legacyNames = ["nanoMuse", "Nivo Bot"]
        guard legacyNames.contains(where: { normalized == content(name: $0) }) else {
            return nil
        }
        return content(name: assistantName)
    }

    /// 读取真实文件后按完整模板迁移；读取失败直接抛出，不覆盖原有字节。
    @discardableResult
    static func migrateLegacyFile(at fileURL: URL, assistantName: String) throws -> Bool {
        let existing = try String(contentsOf: fileURL, encoding: .utf8)
        guard let updated = migratedLegacyContent(existing, assistantName: assistantName) else {
            return false
        }
        try updated.write(to: fileURL, atomically: true, encoding: .utf8)
        return true
    }
}
