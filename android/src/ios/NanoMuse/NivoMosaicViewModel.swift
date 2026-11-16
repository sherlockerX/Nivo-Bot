import Foundation
import Combine

/// 每日碎片的页面状态，只接收当前账户代次的读取结果。
@MainActor
final class NivoMosaicViewModel: ObservableObject {
    @Published private(set) var snapshot: NivoMosaicState?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    @Published private(set) var loadError: String?
    private var loadToken = UUID()
    private var scope: NivoLifeScope?
    private let life = NivoLifeModel.shared

    var entries: [NivoMosaicEntry] { snapshot?.entries.filter { $0.deletedAt == nil } ?? [] }
    var drafts: [NivoMosaicDraft] { snapshot?.drafts.sorted { $0.updatedAt > $1.updatedAt } ?? [] }
    var habits: [NivoMosaicHabit] { snapshot?.habits ?? [] }
    var bin: [NivoMosaicEntry] { snapshot?.entries.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? 0) > ($1.deletedAt ?? 0) } ?? [] }

    /// 切换账户先隐藏旧内容，错误不会被空白成功状态掩盖。
    func load() async {
        let token = UUID()
        loadToken = token
        if life.isReady && !life.isMosaicReady { await life.retryMosaicLoad() }
        guard loadToken == token else { return }
        guard life.isMosaicReady, let captured = life.accessScope else {
            scope = nil
            snapshot = nil
            isLoading = false
            loadError = life.isBackupFrozen ? nil : life.errorMessage
            if life.isReady && !life.isBackupFrozen {
                loadError = loadError ?? NivoLifeModel.message(NivoLifeError.corruptStore)
            }
            return
        }
        if scope != captured { snapshot = nil; scope = captured }
        errorMessage = nil
        isLoading = snapshot == nil
        defer { if loadToken == token { isLoading = false } }
        do {
            let data = try await life.repository.mosaicSnapshot(scope: captured)
            guard loadToken == token, life.accessScope == captured else { return }
            snapshot = data
            loadError = nil
        } catch {
            if loadToken == token { loadError = NivoLifeModel.message(error) }
        }
    }

    /// 草稿自动保存不占用正式提交按钮，失败会留在编辑器内提示。
    func saveDraft(_ draft: NivoMosaicDraft, scope: NivoLifeScope) async throws {
        try require(scope)
        _ = try await life.repository.saveMosaicDraft(draft, scope: scope)
        try require(scope)
    }

    /// 点击保存后提交全部关联变更；冲突时返回失败并保留原草稿。
    func save(_ draft: NivoMosaicDraft, operationID: String, scope: NivoLifeScope) async -> Bool {
        await perform(scope: scope) {
            _ = try await self.life.repository.saveMosaic(draft, operationID: operationID, scope: scope,
                                                        now: Self.now, today: NivoLifeDay.value())
        }
    }

    /// 放弃草稿由用户显式触发，关闭编辑器默认保留。
    func discard(_ draft: NivoMosaicDraft, scope: NivoLifeScope) async -> Bool {
        await perform(scope: scope) {
            _ = try await self.life.repository.discardMosaicDraft(id: draft.id, operationID: UUID().uuidString, scope: scope)
        }
    }

    /// 删除与恢复使用列表展示的版本，其他页面的修改不会被覆盖。
    func changeEntry(_ entry: NivoMosaicEntry, restore: Bool, scope: NivoLifeScope) async -> Bool {
        await perform(scope: scope) {
            _ = try await self.life.repository.changeMosaicEntry(id: entry.id, expectedRevision: entry.revision ?? 1,
                action: restore ? "restore_fragment" : "delete_fragment", operationID: UUID().uuidString,
                scope: scope, now: Self.now)
        }
    }

    /// 创建、改名、暂停和归档共用习惯版本校验。
    func saveHabit(_ habit: NivoMosaicHabit, scope: NivoLifeScope) async -> Bool {
        await perform(scope: scope) {
            _ = try await self.life.repository.saveMosaicHabit(habit, operationID: UUID().uuidString,
                scope: scope, today: NivoLifeDay.value(), now: Self.now)
        }
    }

    /// 习惯的完成和跳过仅影响所选日期。
    func markHabit(_ habit: NivoMosaicHabit, day: Int64, status: NivoMosaicHabitDay.Status?, scope: NivoLifeScope) async -> Bool {
        await perform(scope: scope) {
            _ = try await self.life.repository.setMosaicHabitDay(habitID: habit.id, day: day, status: status,
                operationID: UUID().uuidString, scope: scope, today: NivoLifeDay.value(), now: Self.now)
        }
    }

    /// 用户选择封面或形状后，日、周、月视图读取同一份日信息。
    func saveDay(_ info: NivoMosaicDayInfo, scope: NivoLifeScope) async -> Bool {
        await perform(scope: scope) {
            _ = try await self.life.repository.saveMosaicDay(info, operationID: UUID().uuidString, scope: scope)
        }
    }

    /// 回收站过期和孤立媒体清理都在账户作用域内进行。
    func sweep(scope: NivoLifeScope) async {
        do {
            try require(scope)
            try await life.repository.sweepMosaic(scope: scope, now: Self.now)
            let state = try await life.repository.mosaicSnapshot(scope: scope)
            try require(scope)
            let paths = state.entries.compactMap(\.mediaPath) + state.drafts.compactMap(\.mediaPath)
            try await NivoMosaicMediaStore.shared.sweep(references: Set(paths), scope: scope)
            await load()
        } catch { errorMessage = NivoLifeModel.message(error) }
    }

    private func perform(scope: NivoLifeScope, action: () async throws -> Void) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try require(scope)
            try await action()
            try require(scope)
            await life.refresh()
            await load()
            NotificationCenter.default.post(name: .nivoMosaicStateChanged, object: scope.ownerKey)
            return true
        } catch {
            errorMessage = NivoLifeModel.message(error)
            return false
        }
    }

    private func require(_ scope: NivoLifeScope) throws {
        guard life.isMosaicReady, life.accessScope == scope else { throw NivoLifeError.accountChanged }
    }

    static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
}

extension Notification.Name {
    /// 只有生活事务成功落盘后才通知其他碎片页面刷新。
    static let nivoMosaicStateChanged = Notification.Name("nivo.mosaic.changed")
}
