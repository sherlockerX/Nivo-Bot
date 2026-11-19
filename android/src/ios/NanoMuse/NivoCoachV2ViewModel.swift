import Foundation
import Combine

/// Coach v2页面的主线程投影；磁盘状态仍由actor单独负责。
@MainActor
final class NivoCoachV2ViewModel: ObservableObject {
    static let shared = NivoCoachV2ViewModel()
    @Published private(set) var state = NivoCoachState()
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var loadError: String?
    @Published var errorMessage: String?
    private var owner: String?
    private var loadedScope: NivoLifeScope?
    private var reloadID = UUID()
    private var mutationID = UUID()

    /// 过期读取不会把前一个账户的课程写回当前页面。
    func reload(ownerKey: String) async {
        guard let scope = NivoLifeModel.shared.accessScope, scope.ownerKey == ownerKey,
              NanoMuseAccountData.shared.current == ownerKey else { clear(); return }
        let token = UUID()
        reloadID = token
        if loadedScope != scope {
            state = NivoCoachState(); owner = nil; hasLoaded = false; loadError = nil
            loadedScope = scope
        }
        isLoading = true
        defer { if reloadID == token { isLoading = false } }
        do {
            try await NivoCoachV2Store.shared.retryOpen(ownerKey: ownerKey)
            guard reloadID == token, NivoLifeModel.shared.accessScope == scope else { return }
            let generation = try await NivoCoachV2Store.shared.access(ownerKey: ownerKey)
            let recoveryError = try await NivoCoachArchiveRecovery.retryAll(scope: scope, generation: generation)
            try await NivoCoachReconciliation.reconcileAll(scope: scope, generation: generation)
            let snapshot = try await NivoCoachV2Store.shared.snapshot(ownerKey: ownerKey)
            guard reloadID == token, NivoLifeModel.shared.accessScope == scope,
                  NanoMuseAccountData.shared.current == ownerKey else { return }
            state = snapshot
            owner = ownerKey
            hasLoaded = true
            loadError = recoveryError
        } catch {
            if reloadID == token, NivoLifeModel.shared.accessScope == scope { loadError = NivoLifeModel.message(error) }
        }
    }

    /// 切换账户时同时撤销内存投影和未完成的读取。
    func clear() {
        reloadID = UUID()
        mutationID = UUID()
        owner = nil
        loadedScope = nil
        state = NivoCoachState()
        isLoading = false
        isMutating = false
        hasLoaded = false
        loadError = nil
        errorMessage = nil
    }

    /// 暂停课程使用与AI完全相同的版本化事务。
    func pause(courseID: String, paused: Bool, scope: NivoLifeScope) async {
        guard !isMutating, owner == scope.ownerKey, loadedScope == scope,
              NivoLifeModel.shared.accessScope == scope else { return }
        let token = UUID()
        mutationID = token
        isMutating = true
        defer { if mutationID == token { isMutating = false } }
        do {
            try await NivoCoachConversationCoordinator.shared.command(paused ? "pause_course" : "resume_course",
                                                                      targetID: courseID, scope: scope)
            guard mutationID == token, NivoLifeModel.shared.accessScope == scope else { return }
            await reload(ownerKey: scope.ownerKey)
        } catch {
            if mutationID == token, NivoLifeModel.shared.accessScope == scope { errorMessage = NivoLifeModel.message(error) }
        }
    }

    /// 进入的是专题聊天ID，不能把内部课次ID误当成聊天会话ID。
    func start(courseID: String, unitID: String, scope: NivoLifeScope, startToday: Bool = false,
               minutes: Int = 15, need: String = "", openChat: (String) -> Void) async {
        guard !isMutating, owner == scope.ownerKey, loadedScope == scope,
              NivoLifeModel.shared.accessScope == scope else { return }
        let token = UUID()
        mutationID = token
        isMutating = true
        defer { if mutationID == token { isMutating = false } }
        do {
            let chatID = try await NivoCoachConversationCoordinator.shared.open(courseID: courseID, unitID: unitID, scope: scope,
                startToday: startToday, minutes: minutes, need: need)
            guard mutationID == token, NivoLifeModel.shared.accessScope == scope else { return }
            await reload(ownerKey: scope.ownerKey)
            guard mutationID == token, owner == scope.ownerKey, NivoLifeModel.shared.accessScope == scope,
                  NanoMuseAccountData.shared.current == scope.ownerKey else { return }
            openChat(chatID)
        } catch {
            if mutationID == token, NivoLifeModel.shared.accessScope == scope { errorMessage = NivoLifeModel.message(error) }
        }
    }

    /// 推进始终携带用户看到的单元，旧页面不能跳过另一个刚推进的单元。
    func advance(courseID: String, unitID: String, scope: NivoLifeScope) async {
        guard !isMutating, owner == scope.ownerKey, loadedScope == scope,
              NivoLifeModel.shared.accessScope == scope else { return }
        let token = UUID()
        mutationID = token
        isMutating = true
        defer { if mutationID == token { isMutating = false } }
        do {
            try await NivoCoachConversationCoordinator.shared.command("advance", targetID: courseID,
                scope: scope, payload: ["unitId": unitID])
            guard mutationID == token, NivoLifeModel.shared.accessScope == scope else { return }
            await reload(ownerKey: scope.ownerKey)
        } catch {
            if mutationID == token, NivoLifeModel.shared.accessScope == scope { errorMessage = NivoLifeModel.message(error) }
        }
    }
}
