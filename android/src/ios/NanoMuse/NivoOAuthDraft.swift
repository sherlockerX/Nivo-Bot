import Foundation

/// 授权前登记新实例的清理所有权，文件只保存随机实例标识，不保存凭证。
@MainActor
final class NivoOAuthDraftRegistry {
    enum Failure: Error { case invalidRegistry }

    let fileURL: URL
    private var activeIDs: Set<String> = []

    init(fileURL: URL) { self.fileURL = fileURL }

    /// 已有实例不取得草稿所有权；登记失败时调用方必须停止登录。
    func begin(instanceID: String, isExisting: Bool) throws {
        guard !isExisting else { return }
        var identifiers = try read()
        if !identifiers.contains(instanceID) {
            identifiers.append(instanceID)
            try write(identifiers)
        }
        activeIDs.insert(instanceID)
    }

    /// 表单退出只释放活动租约，删除确认之前不遗忘持久标识。
    func abandon(instanceID: String) { activeIDs.remove(instanceID) }

    /// 页面退出不能抢在提交或回滚之前释放草稿，即使保存任务已取消也要等它结束。
    func abandon(instanceID: String, after submission: Task<Void, Never>) async {
        await submission.value
        abandon(instanceID: instanceID)
    }

    /// 配置或凭证删除成功后才能结束登记，失败仍可重新读取。
    func complete(instanceID: String) throws {
        let identifiers = try read()
        if identifiers.contains(instanceID) { try write(identifiers.filter { $0 != instanceID }) }
        activeIDs.remove(instanceID)
    }

    /// 进程重启后活动租约为空，未完成草稿自动进入恢复候选。
    func pendingIDs() throws -> [String] {
        try read().filter { !activeIDs.contains($0) }.sorted()
    }

    /// 删除由既有凭证协调器确认；已经安装的实例只移除草稿记录。
    func clean(instanceID: String, isInstalled: () throws -> Bool,
               remove: () async throws -> Void) async throws {
        guard try pendingIDs().contains(instanceID) else { return }
        if try !isInstalled() { try await remove() }
        try complete(instanceID: instanceID)
    }

    private func read() throws -> [String] {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        guard data.count <= 1_048_576 else { throw Failure.invalidRegistry }
        let identifiers = try JSONDecoder().decode([String].self, from: data)
        try validate(identifiers)
        return identifiers
    }

    private func write(_ identifiers: [String]) throws {
        try validate(identifiers)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(identifiers.sorted()).write(to: fileURL, options: .atomic)
    }

    private func validate(_ identifiers: [String]) throws {
        guard identifiers.count <= 4096, Set(identifiers).count == identifiers.count,
              identifiers.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0") }) else {
            throw Failure.invalidRegistry
        }
    }
}

/// Kimi成功提示期间的取消或下拉仍报告已写入，完成回调只发送一次。
struct NivoOAuthLoginCompletion {
    private(set) var hasPersistedCredential = false
    private(set) var hasFinished = false

    /// 必须紧接管理器确认写入之后调用，不跨越提示延时。
    mutating func didPersist() { hasPersistedCredential = true }

    /// 显式取消、自动完成和系统关闭共享同一个结果。
    mutating func finish() -> Bool? {
        guard !hasFinished else { return nil }
        hasFinished = true
        return hasPersistedCredential
    }
}
