import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 只接受持久home/bin中的显式脚本，参数始终保留argv边界。
struct NivoRoutineScript: Codable, Equatable, Sendable {
    var id: String
    var arguments: [String] = []
    var requireOutput = false
    var logStdout = false

    var guestPath: String { "/var/minis/home/bin/" + id }
    var interpreter: String { id.hasSuffix(".py") ? "/usr/bin/python3" : "/bin/sh" }

    /// 拒绝路径、二进制、NUL和无限参数，不能靠文件名截断变成另一个命令。
    func validate() throws {
        guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$", options: .regularExpression) != nil,
              !id.contains(".."), id.hasSuffix(".sh") || id.hasSuffix(".py") else {
            throw NivoLifeError.invalidField("SCRIPT_PATH_INVALID")
        }
        guard arguments.count <= 16, arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 256 }) else {
            throw NivoLifeError.invalidField("SCRIPT_ARG_INVALID")
        }
    }
}

/// 读取完成后冻结正文与参数；审批和执行都引用这个值，不再打开原文件。
struct NivoScheduledScriptVersion: Sendable {
    static let maximumBytes = 65_536
    let script: NivoRoutineScript
    let body: String
    let digest: String

    /// UTF-8正文没有替换字符兜底，避免审批内容与实际解释器收到的字节不同。
    init(script: NivoRoutineScript, data: Data) throws {
        try script.validate()
        guard data.count <= Self.maximumBytes else { throw NivoLifeError.invalidField("SCRIPT_TOO_LARGE") }
        guard let body = String(data: data, encoding: .utf8), !body.contains("\0") else {
            throw NivoLifeError.invalidField("SCRIPT_ENCODING_INVALID")
        }
        self.script = script
        self.body = body
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(script)
        let material = Data("\(encoded.count):".utf8) + encoded + data
        self.digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    /// 正文作为解释器的单独参数传入；参数里的引号、美元和分号不会再次解析。
    var invocationArguments: [String] {
        if script.id.hasSuffix(".py") {
            let bootstrap = "import os,sys; os.chdir('/var/minis/home'); p=sys.argv.pop(1); c=sys.argv.pop(1); sys.argv[0]=p; "
                + "sys.path[0]='/var/minis/home/bin'; exec(compile(c,p,'exec'),{'__name__':'__main__','__file__':p})"
            return ["-c", bootstrap, script.guestPath, body] + script.arguments
        }
        // 固定工作目录后再解释被冻结的正文，避免相对路径随上一次聊天命令变化。
        return ["-c", "cd /var/minis/home || exit 125\n" + body, script.guestPath] + script.arguments
    }
}

/// 固定偏移用POSIX时区表达，地区时区要求真实规则库，不能静默退回UTC。
struct NivoScheduledTimezone: Equatable, Sendable {
    let environmentValue: String
    let requiredDataPath: String?

    /// 只将经过校验的地区标识放进预检命令，偏移时区不依赖tzdata文件。
    init(_ zone: TimeZone) throws {
        let identifier = zone.identifier
        guard identifier.range(of: "^[A-Za-z0-9_+./-]+$", options: .regularExpression) != nil,
              !identifier.contains("..") else { throw NivoLifeError.invalidField("TIMEZONE_DATA_UNAVAILABLE") }
        if ["UTC", "GMT"].contains(identifier)
            || identifier.range(of: "^GMT[+-][0-9]{4}$", options: .regularExpression) != nil {
            let offset = zone.secondsFromGMT()
            let magnitude = abs(offset)
            let sign = offset < 0 ? "+" : "-"
            environmentValue = offset == 0 ? "UTC0" : "UTC\(sign)\(magnitude / 3600):\(magnitude / 60 % 60):\(magnitude % 60)"
            requiredDataPath = nil
        } else {
            environmentValue = identifier
            requiredDataPath = "/usr/share/zoneinfo/" + identifier
        }
    }
}
