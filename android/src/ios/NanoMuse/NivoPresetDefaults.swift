import Foundation

/// 只升级整份未经修改的历史预置记忆，用户和助手写入的内容保持原样。
enum NivoPresetDefaults {
    /// 将统一预置资源中的新旧Android设备称呼转换为iPhone上的文案。
    static func contentForIPhone(_ bundled: String) -> String {
        bundled
            .replacingOccurrences(of: "Android客户端", with: "iOS客户端")
            .replacingOccurrences(of: "Android 手机", with: "iPhone")
            .replacingOccurrences(of: "Android手机", with: "iPhone")
    }

    /// 返回精确历史模板的新资源文本；不局部替换身份句或其他用户内容。
    static func migratedGlobalContent(_ markdown: String, replacement: String) -> String? {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let normalizedReplacement = replacement.replacingOccurrences(of: "\r\n", with: "\n")
        guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized != normalizedReplacement,
              ["Android 手机", "iPhone"].contains(where: { normalized == legacyGlobal(device: $0) }) else {
            return nil
        }
        return replacement
    }

    /// 对已有文件执行原子替换，读写失败由调用者保留原文件并稍后重试。
    @discardableResult
    static func migrateGlobalFile(at fileURL: URL, replacement: String) throws -> Bool {
        let existing = try String(contentsOf: fileURL, encoding: .utf8)
        guard let updated = migratedGlobalContent(existing, replacement: replacement) else {
            return false
        }
        try updated.write(to: fileURL, atomically: true, encoding: .utf8)
        return true
    }

    /// 保留已核实历史资产的完整快照，只允许安装器原有的设备名替换。
    private static func legacyGlobal(device: String) -> String {
        """
        # 长期记忆

        ## 关于你自己
        - 你是 Nicholasx，运行在我的 \(device)上，模型来自我自己配置的服务商。
        - 你看得到 SOUL.md（你的性格）、USER.md（关于我）和这份长期记忆；每天的零碎写进当天的记忆日志。

        ## 关于"拼图"
        - "拼图"页是我的生活记录：每天的照片、一句话和习惯完成情况，只保存在这台手机上。
        - 你现在读不到拼图里的记录。需要复盘时，请我把当天或这周的内容告诉你，或者直接问我。

        ## 约定
        - 我说"记住……"时，把它写进长期记忆或 USER.md，并告诉我写在了哪里。
        - 关于我的长期事实（称呼、作息、目标、重要的人）更新到 USER.md，不要重复堆在这里。
        - 过时或被我纠正的内容，直接改掉，不要留下互相矛盾的两条。

        """
    }
}
