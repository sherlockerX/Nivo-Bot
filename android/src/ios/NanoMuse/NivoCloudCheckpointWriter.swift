import Foundation

/// 同步游标等待接收批次落库；停止或重建同步引擎时可作废尚未落盘的候选。
@MainActor
final class NivoCloudCheckpointWriter {
    static let shared = NivoCloudCheckpointWriter()

    private struct PendingWrite {
        let identifier: UUID
        let task: Task<Void, Never>
    }

    private let checkpoint: NivoCloudInboundCheckpoint
    private var tasks: [URL: PendingWrite] = [:]

    init(checkpoint: NivoCloudInboundCheckpoint = .shared) {
        self.checkpoint = checkpoint
    }

    /// 删除状态文件之前先取消候选，防止旧任务在重置之后重新写回旧游标。
    func invalidate(_ url: URL) {
        tasks.removeValue(forKey: url)?.task.cancel()
    }

    /// 同一路径只保留最新候选；返回值可用于等待本次持久化完成或取消。
    @discardableResult
    func schedule(data: Data, to url: URL, onSaved: @escaping @MainActor () -> Void,
                  onFailure: @escaping @MainActor (Error) -> Void) -> Task<Void, Never> {
        invalidate(url)
        let identifier = UUID()
        let task = Task { @MainActor in
            defer {
                if tasks[url]?.identifier == identifier { tasks.removeValue(forKey: url) }
            }
            do {
                while !Task.isCancelled && !checkpoint.hasFailure {
                    guard tasks[url]?.identifier == identifier else { return }
                    if try checkpoint.persistIfSettled({ try data.write(to: url, options: .atomic) }) {
                        onSaved()
                        return
                    }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            } catch {
                if !Task.isCancelled { onFailure(error) }
            }
        }
        tasks[url] = PendingWrite(identifier: identifier, task: task)
        return task
    }
}
