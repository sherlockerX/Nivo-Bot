import Foundation
#if canImport(Combine)
import Combine
#endif

/// 编辑器的媒体操作有独立身份；页面结束或请求撤销后，迟到结果不能修改草稿。
@MainActor
final class NivoMosaicEditorLifecycle {
    #if canImport(Combine)
    @Published private var importID: UUID?
    @Published private var cameraPreparationID: UUID?
    @Published private(set) var hasFinished = false
    #else
    private var importID: UUID?
    private var cameraPreparationID: UUID?
    private(set) var hasFinished = false
    #endif

    var isImporting: Bool { importID != nil }
    var isPreparingCamera: Bool { cameraPreparationID != nil }
    var isBusy: Bool { isImporting || isPreparingCamera }

    /// 在创建读取任务之前同步占用身份，连第一次挂起之前的按钮事件也不能穿过。
    func beginImport() -> UUID? {
        guard !hasFinished, !isBusy else { return nil }
        let identifier = UUID()
        importID = identifier
        return identifier
    }

    /// 读取、写入和交付都校验同一请求；仅当前请求返回真，允许调用方清理对应的照片选择。
    @discardableResult
    func importPhoto(id: UUID, read: @MainActor () async throws -> Data,
                     store: @MainActor (Data) async throws -> String,
                     scopeIsCurrent: @MainActor () -> Bool,
                     apply: @MainActor (String) -> Void,
                     onError: @MainActor (Error) -> Void) async -> Bool {
        defer { finishImport(id) }
        do {
            guard acceptsImport(id), scopeIsCurrent() else { return false }
            let data = try await read()
            guard acceptsImport(id), scopeIsCurrent() else { return false }
            let path = try await store(data)
            guard acceptsImport(id), scopeIsCurrent() else { return false }
            apply(path)
        } catch {
            if acceptsImport(id), scopeIsCurrent(), !(error is CancellationError) { onError(error) }
        }
        return acceptsImport(id) && scopeIsCurrent()
    }

    /// 先明确保存当前草稿，成功后才打开相机；取消拍照也不会丢失之前的文字。
    func prepareCamera(saveDraft: @MainActor () async throws -> Void,
                       scopeIsCurrent: @MainActor () -> Bool,
                       present: @MainActor () -> Void,
                       onError: @MainActor (Error) -> Void) async {
        guard !hasFinished, !isBusy, !Task.isCancelled, scopeIsCurrent() else { return }
        let identifier = UUID()
        cameraPreparationID = identifier
        defer { finishCameraPreparation(identifier) }
        do {
            try await saveDraft()
            guard !hasFinished, cameraPreparationID == identifier,
                  !Task.isCancelled, scopeIsCurrent() else { return }
            // 相机回调必须能开始新的导入，因此先释放准备状态，再呈现相机。
            finishCameraPreparation(identifier)
            present()
        } catch {
            if !hasFinished, cameraPreparationID == identifier, !Task.isCancelled,
               scopeIsCurrent(), !(error is CancellationError) { onError(error) }
        }
    }

    /// 撤销当前导入后可重新选择照片；旧请求完成时不会释放新请求的锁。
    func cancelImport() {
        importID = nil
    }

    /// 正式关闭、保存成功、放弃或账户失效都永久结束这一编辑器的回调生命周期。
    func finish() {
        hasFinished = true
        importID = nil
        cameraPreparationID = nil
    }

    private func acceptsImport(_ identifier: UUID) -> Bool {
        !hasFinished && importID == identifier && !Task.isCancelled
    }

    private func finishImport(_ identifier: UUID) {
        guard importID == identifier else { return }
        cancelImport()
    }

    private func finishCameraPreparation(_ identifier: UUID) {
        guard cameraPreparationID == identifier else { return }
        cameraPreparationID = nil
    }
}

#if canImport(Combine)
extension NivoMosaicEditorLifecycle: ObservableObject {}
#endif
