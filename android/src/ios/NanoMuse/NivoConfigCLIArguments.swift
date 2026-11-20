import Foundation

/// 配置终端的只读参数与退出码契约，不访问应用状态或凭据。
enum NivoConfigCLIArguments {
    /// 已校验的读请求；零表示调用方未指定分页，保留旧版桥接语义。
    struct GetRequest: Equatable {
        let path: String
        let filter: String?
        let page: Int
        let pageSize: Int
    }

    /// 可直接传给终端错误信封的参数诊断。
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let outputFlags: Set<String> = ["--compact", "--quiet", "-q"]
    private static let auditOptions: Set<String> = ["--session", "--actor", "--caption"]
    private static let optionNames = [
        "--filter": "filter", "-f": "filter", "--page": "page", "-p": "page",
        "--page-size": "page-size", "-s": "page-size",
    ]

    /// 解析get参数，拒绝遗漏值、未知选项、多余位置参数和重复选项。
    static func parseGet(_ arguments: [String]) throws -> GetRequest {
        var path: String?
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            if outputFlags.contains(token) { index += 1; continue }
            if auditOptions.contains(token) {
                _ = try optionValue(arguments, index: index)
                index += 2
                continue
            }
            if let name = optionNames[token] {
                guard values[name] == nil else { throw Failure(message: "Duplicate option: \(token).") }
                values[name] = try optionValue(arguments, index: index)
                index += 2
                continue
            }
            guard !token.hasPrefix("-"), !token.isEmpty, path == nil else {
                throw Failure(message: "Unexpected argument '\(token)'. Use get <path> [--filter <keywords>] [--page N] [--page-size N].")
            }
            path = token
            index += 1
        }
        guard let path else { throw Failure(message: "get <path> requires a field path.") }
        return GetRequest(path: path, filter: values["filter"],
            page: try positiveInteger(values["page"], option: "--page"),
            pageSize: try positiveInteger(values["page-size"], option: "--page-size"))
    }

    /// topic-help只接受一个已登记主题；空集合仍可拥有有效主题。
    static func parseTopic(_ arguments: [String], availableTopics: [String]) throws -> String {
        let request = try parseGet(arguments)
        guard request.filter == nil, request.page == 0, request.pageSize == 0,
              availableTopics.contains(request.path) else {
            throw Failure(message: "topic-help <topic> requires one known topic. Use list-topics to see available topics.")
        }
        return request.path
    }

    /// 配置命令保留自身的退出码约定，不使用通用offload的参数错误码2。
    static func exitCode(isOK: Bool, error: String?) -> Int {
        guard !isOK else { return 0 }
        switch error {
        case "permission_denied": return 126
        case "timeout": return 124
        case "user_rejected", "all_rejected": return 125
        default: return 1
        }
    }

    private static func optionValue(_ arguments: [String], index: Int) throws -> String {
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
            throw Failure(message: "\(arguments[index]) requires a value.")
        }
        return arguments[index + 1]
    }

    private static func positiveInteger(_ raw: String?, option: String) throws -> Int {
        guard let raw else { return 0 }
        guard !raw.isEmpty, raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let value = Int(raw), value > 0 else {
            throw Failure(message: "\(option) must be a positive integer.")
        }
        return value
    }
}
