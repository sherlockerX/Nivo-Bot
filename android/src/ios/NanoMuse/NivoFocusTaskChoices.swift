import Foundation

/// 专注只从当前账号的未完成待办中选择，同名匹配忽略大小写及首尾空白。
struct NivoFocusTaskChoices {
    let title: String
    let matches: [NivoTodoTask]
    let canCreate: Bool

    init(tasks: [NivoTodoTask], owner: String, query: String) {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let available = tasks.filter { $0.ownerKey == owner && $0.deletedAt == nil && $0.status != .done }
        title = search
        matches = search.isEmpty ? available : available.filter { $0.title.range(of: search, options: .caseInsensitive) != nil }
        canCreate = !search.isEmpty && search.utf16.count <= 500 && !available.contains {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(search) == .orderedSame
        }
    }
}
