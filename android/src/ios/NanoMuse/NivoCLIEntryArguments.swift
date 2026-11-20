import Foundation

/// 原生CLI入口的纯参数规则，不访问权限、账户或供应商状态。
enum NivoCLIEntryArguments {
    /// 模型入口只传递命令、查询词和显式筛选，不扩大可调用模型集合。
    struct ModelUseRequest: Equatable {
        let command: String
        let provider: String?
        let searchQuery: String
    }

    /// 参数缺失由各入口按自身退出码返回。
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let outputFlags: Set<String> = ["--compact", "--quiet", "-q"]
    private static let configMetadata: Set<String> = ["--actor", "--session", "--caption"]
    private static let modelFlags: Set<String> = ["--compact", "--quiet", "-q", "--all", "--stream"]
    private static let modelValueOptions: Set<String> = [
        "--provider", "--modality", "--model", "--input", "--prompt", "--prompt-file",
        "--output", "--system", "--system-file", "--max-tokens", "--temperature", "--endpoint",
    ]

    /// 返回不含程序名的参数数组中的命令位置；无命令保留list-topics默认行为。
    static func configCommandIndex(_ arguments: [String]) throws -> Int? {
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if outputFlags.contains(token) { index += 1; continue }
            guard configMetadata.contains(token) else { return index }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
                throw Failure(message: "\(token) requires a value.")
            }
            index += 2
        }
        return nil
    }

    /// 只识别入口所需字段；运行参数仍由既有命令处理，值里的选项字面量不会被再解析。
    static func modelUse(_ arguments: [String]) throws -> ModelUseRequest {
        var command: String?
        var provider: String?
        var queryWords: [String] = []
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if modelFlags.contains(token) { index += 1; continue }
            if token.hasPrefix("--provider=") {
                let value = try checkedProvider(String(token.dropFirst("--provider=".count)))
                provider = provider ?? value
                index += 1
                continue
            }
            if modelValueOptions.contains(token) {
                if token == "--provider" {
                    let value = try providerValue(arguments, index: index)
                    provider = provider ?? value
                }
                index += 2
                continue
            }
            // 其他选项保留旧入口的跳值行为，不在此扩展运行参数校验范围。
            if token.hasPrefix("-") {
                index += legacyOptionWidth(arguments, index: index)
                continue
            }
            if command == nil { command = token }
            else { queryWords.append(token) }
            index += 1
        }
        guard let command else { throw Failure(message: "No command specified. Use --help for usage.") }
        return ModelUseRequest(command: command, provider: provider, searchQuery: queryWords.joined(separator: " "))
    }

    private static func providerValue(_ arguments: [String], index: Int) throws -> String {
        guard index + 1 < arguments.count else { throw Failure(message: "--provider requires a value.") }
        return try checkedProvider(arguments[index + 1])
    }

    private static func checkedProvider(_ value: String) throws -> String {
        guard !value.hasPrefix("-"), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "--provider requires a provider label or ID.")
        }
        return value
    }

    private static func legacyOptionWidth(_ arguments: [String], index: Int) -> Int {
        arguments[index].hasPrefix("--") && index + 1 < arguments.count && !arguments[index + 1].hasPrefix("-") ? 2 : 1
    }
}
