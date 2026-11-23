import Foundation

/// 附件在地址和消息标记里的写法：路径转成地址时逐字符编码，写进标记属性时转义，读回来还原。
/// 文件名可以包含中文、空格、表情、`#`、`?`和引号。
enum NivoAttachmentMarkup {
    private static let root = "/var/minis/"
    private static let fileAttributes: [(raw: String, escaped: String)] = [
        ("&", "&amp;"), ("\"", "&quot;"), ("<", "&lt;"), (">", "&gt;"), ("\n", "&#10;"), ("\r", "&#13;"),
    ]

    /// `/var/minis/`下的路径对应的地址；`#`和`?`会被编码，不会变成片段或查询。
    static func minisURL(forLinuxPath path: String) -> String? {
        guard path.hasPrefix(root) else { return nil }
        let relative = String(path.dropFirst(root.count))
        let encoded = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
        return "minis://" + encoded
    }

    /// 地址对应的路径，[minisURL]的逆过程。
    static func linuxPath(forMinisURL url: String) -> String? {
        let scheme = "minis://"
        guard url.hasPrefix(scheme) else { return nil }
        let relative = String(url.dropFirst(scheme.count))
        guard !relative.isEmpty else { return nil }
        return root + (relative.removingPercentEncoding ?? relative)
    }

    /// 写进消息的附件清单，一行一个文件。
    static func block(_ files: [AttachmentMeta], modified: String) -> String {
        let lines = files.map { file in
            "  <file path=\"\(escape(file.path))\" url=\"\(escape(file.minisURL))\" size=\"\(file.size)\" modified=\"\(modified)\" />\n"
        }
        return "<user-attached-files>\n" + lines.joined() + "</user-attached-files>"
    }

    /// 还原属性值；旧消息没有转义过，原样返回。
    static func unescape(_ value: String) -> String {
        // 与号最后还原，避免把文件名里本来的实体写法再解一次。
        fileAttributes.reversed().reduce(value) { text, pair in
            text.replacingOccurrences(of: pair.escaped, with: pair.raw)
        }
    }

    private static func escape(_ value: String) -> String {
        fileAttributes.reduce(value) { text, pair in
            text.replacingOccurrences(of: pair.raw, with: pair.escaped)
        }
    }
}
