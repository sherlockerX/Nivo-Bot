import Foundation
import Combine

/// 原生界面的账户绑定门面，磁盘事务在仓库actor执行，旧异步结果不回填新账号。
@MainActor
final class NivoLifeModel: ObservableObject {
    static let shared = NivoLifeModel()
    let repository: NivoLifeRepository
    @Published private(set) var tasks: [NivoTodoTask] = []
    @Published private(set) var categories: [NivoTodoCategory] = []
    @Published private(set) var focusSessions: [NivoFocusSession] = []
    @Published private(set) var focusSpans: [NivoFocusSpan] = []
    @Published private(set) var isReady = false
    @Published private(set) var isMosaicReady = false
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var accountCleanupError: String?
    private var scope: NivoLifeScope?
    private var activationID = UUID()
    private var isChangingAccount = false
    private var appliedStoreRevision: Int64?
    @Published private(set) var isBackupFrozen = false

    /// 默认目录位于应用私有配置中，构造时不读取用户数据。
    init(repository: NivoLifeRepository? = nil) {
        self.repository = repository ?? NivoLifeRepository(directory: NanoMuseDirs.root.appendingPathComponent("life"))
    }

    var activeFocus: NivoFocusSession? { focusSessions.first(where: \.isActive) }
    var ownerKey: String { scope?.ownerKey ?? NanoMuseAccountData.shared.current }
    var accessScope: NivoLifeScope? { isReady && !isBackupFrozen ? scope : nil }

    /// 仅账户宿主及页面生命周期触发载入，先清空旧展示再等待磁盘。
    func activate() async {
        guard !isChangingAccount, !NanoMuseAccountData.shared.isChangingAccount, !isBusy, !isBackupFrozen else { return }
        if BackupRestoreJournal.hasPendingPersonalDataRecovery {
            clear()
            errorMessage = Self.message(NivoLifeError.corruptStore)
            return
        }
        let owner = NanoMuseAccountData.shared.current
        if isReady, scope?.ownerKey == owner { await refresh(); return }
        let token = UUID()
        activationID = token
        clear()
        errorMessage = nil
        isBusy = true
        defer { if activationID == token { isBusy = false } }
        do {
            let captured = try await repository.open(ownerKey: owner, clock: NivoLifeClock.sample())
            let snapshot = try await repository.snapshot(scope: captured, clock: NivoLifeClock.sample())
            guard activationID == token, NanoMuseAccountData.shared.current == owner else { return }
            await NivoFocusBackgroundStore.shared.bind(scope: captured)
            // 生活碎片和Coach各自有独立快照；某一份损坏时保留待办/专注可用，页面会在自身加载时显示错误。
            var mosaicReady = false
            do {
                try await NivoMosaicStore.shared.bind(scope: captured, repository: repository)
                mosaicReady = true
            }
            catch { errorMessage = Self.message(error) }
            do { try await NivoCoachV2Store.shared.open(ownerKey: owner) }
            catch { errorMessage = Self.message(error) }
            guard activationID == token, NanoMuseAccountData.shared.current == owner else { return }
            scope = captured
            isMosaicReady = mosaicReady
            apply(snapshot)
            isReady = true
        } catch {
            if activationID == token { errorMessage = Self.message(error) }
        }
    }

    /// 离开账户立即隐藏数据并撤销凭证，等待仓库结算后再进行账户文件迁移。
    func suspend() async {
        activationID = UUID()
        NivoCoachChatContext.shared.clear()
        NivoCoachV2ViewModel.shared.clear()
        clear()
        isBusy = false
        await NivoFocusBackgroundStore.shared.revoke()
        await NivoMosaicStore.shared.close()
        await NivoCoachV2Store.shared.close()
        do { try await repository.close(clock: NivoLifeClock.sample()) }
        catch { errorMessage = Self.message(error) }
    }

    /// 关闭仓库必须成功结算专注，身份未提交前绝不删除任何账户资料。
    func prepareAccountSwitch() async throws {
        await NivoPersonalBackupAccess.waitForAccountAccess()
        isChangingAccount = true
        NivoFocusNotifications.shared.cancel()
        await suspend()
        // suspend保留页面错误，但仓库的第二次close会重试未提交的结算并传播失败。
        try await repository.close(clock: NivoLifeClock.sample())
    }

    /// 身份提交后的幂等清理；失败由账户事务保留日志并在启动时重试。
    func discardAccount(_ account: String) async throws {
        try await repository.removeAccount(ownerKey: account)
        try await NivoMosaicStore.shared.removeAccount(ownerKey: account)
        try await NivoCoachV2Store.shared.removeAccount(ownerKey: account)
        NivoFocusPreferences.remove(owner: account)
        accountCleanupError = nil
    }

    /// 凭证和账号文件均切换完成之后才允许新页面请求。
    func enter() async {
        isChangingAccount = false
        await activate()
    }

    /// 只刷新状态边界，不让每秒显示刷新产生磁盘写入。
    func refresh() async {
        guard let captured = accessScope, !isBusy else { return }
        let token = activationID
        do {
            let snapshot = try await repository.snapshot(scope: captured, clock: NivoLifeClock.sample())
            guard token == activationID, captured.ownerKey == NanoMuseAccountData.shared.current else { return }
            apply(snapshot)
        } catch {
            if token == activationID { errorMessage = Self.message(error) }
        }
    }

    /// 秒针由TimelineView显示，到期或开机标识改变时才请求持久化及界面发布。
    func refreshFocusIfNeeded() async {
        guard let session = activeFocus,
              NivoFocusPresentationRules.needsReconciliation(session, clock: NivoLifeClock.sample()) else { return }
        await refresh()
    }

    /// 碎片初始化失败可独立重试，待办与专注无需退出账户或重新建立仓库。
    func retryMosaicLoad() async {
        guard let captured = accessScope, !isBusy else { return }
        let token = activationID
        isBusy = true
        defer { if activationID == token { isBusy = false } }
        do {
            try await NivoMosaicStore.shared.bind(scope: captured, repository: repository)
            guard activationID == token, accessScope == captured else { return }
            isMosaicReady = true
            errorMessage = nil
        } catch {
            if activationID == token { errorMessage = Self.message(error) }
        }
    }

    /// 工具查询必须确认这次读取成功，不能把上次界面缓存当成本轮结果。
    func refreshForTool(scope captured: NivoLifeScope) async throws {
        guard accessScope == captured, captured.ownerKey == NanoMuseAccountData.shared.current else { throw NivoLifeError.accountChanged }
        let snapshot = try await repository.snapshot(scope: captured, clock: NivoLifeClock.sample())
        guard accessScope == captured, captured.ownerKey == NanoMuseAccountData.shared.current else { throw NivoLifeError.accountChanged }
        apply(snapshot)
    }

    /// 编辑器仅在返回成功时关闭，冲突时保留原草稿供用户比较。
    func saveTask(_ task: NivoTodoTask, operationID: String, scope expectedScope: NivoLifeScope) async -> Bool {
        await performResult(scope: expectedScope) { repository, scope, clock in
            try await repository.saveTask(task, operationID: operationID, scope: scope,
                                          now: clock.wallMs, today: NivoLifeDay.value())
        } != nil
    }

    /// AI工具需要返回事务实际保存的快照，不能用界面当前排序猜测新任务。
    func saveTaskResult(_ task: NivoTodoTask, operationID: String, scope expectedScope: NivoLifeScope) async -> NivoTodoTask? {
        await performResult(scope: expectedScope) { repository, scope, clock in
            try await repository.saveTask(task, operationID: operationID, scope: scope,
                                          now: clock.wallMs, today: NivoLifeDay.value())
        }
    }

    /// 勾选是用户直接确认，AI完成操作另有用户原话授权入口。
    func setStatus(_ task: NivoTodoTask, status: NivoTodoStatus, scope expectedScope: NivoLifeScope) async {
        _ = await setStatusResult(task, status: status, scope: expectedScope)
    }

    /// 状态写入返回服务端快照，完成标签由规则冻结。
    func setStatusResult(_ task: NivoTodoTask, status: NivoTodoStatus,
                         completedDay: Int64? = nil,
                         operationID: String = UUID().uuidString, scope expectedScope: NivoLifeScope) async -> NivoTodoTask? {
        guard task.ownerKey == expectedScope.ownerKey else { return nil }
        return await performResult(scope: expectedScope) { repository, scope, clock in
            try await repository.changeTaskStatus(
                id: task.id, status: status, expectedRevision: task.revision, completedDay: completedDay,
                operationID: operationID, scope: scope, now: clock.wallMs, today: NivoLifeDay.value()
            )
        }
    }

    /// 删除只作用于页面持有的版本，其他入口已修改时提示刷新。
    func deleteTask(_ task: NivoTodoTask, scope expectedScope: NivoLifeScope) async {
        _ = await deleteTaskResult(task, scope: expectedScope)
    }

    /// 软删除返回任务快照，便于AI报告精确删除结果。
    func deleteTaskResult(_ task: NivoTodoTask, operationID: String = UUID().uuidString, scope expectedScope: NivoLifeScope) async -> NivoTodoTask? {
        guard task.ownerKey == expectedScope.ownerKey else { return nil }
        return await performResult(scope: expectedScope) { repository, scope, clock in
            try await repository.deleteTask(id: task.id, expectedRevision: task.revision,
                                             operationID: operationID, scope: scope, now: clock.wallMs)
        }
    }

    /// 独立创建分类，下次建任务可直接选用。
    func createCategory(kind: NivoTodoCategory.Kind, name: String, scope expectedScope: NivoLifeScope) async -> Bool {
        await createCategoryResult(kind: kind, name: name, scope: expectedScope) != nil
    }

    /// 分类修改要求调用页面持有当前账户代次，重试不借用其他账户的权限。
    func createCategoryResult(kind: NivoTodoCategory.Kind, name: String,
                              operationID: String = UUID().uuidString, scope expectedScope: NivoLifeScope) async -> NivoTodoCategory? {
        await performResult(scope: expectedScope) { repository, scope, clock in
            try await repository.createCategory(kind: kind, name: name, operationID: operationID,
                                                scope: scope, now: clock.wallMs)
        }
    }

    /// 删除分类保留任务本身，同时清除当前引用。
    func deleteCategory(_ category: NivoTodoCategory, scope expectedScope: NivoLifeScope) async {
        _ = await deleteCategoryResult(category, scope: expectedScope)
    }

    /// 分类名称不携带账户身份，因此必须显式校验页面捕获的scope。
    func deleteCategoryResult(_ category: NivoTodoCategory,
                              operationID: String = UUID().uuidString, scope expectedScope: NivoLifeScope) async -> NivoTodoCategory? {
        await performResult(scope: expectedScope) { repository, scope, clock in
            try await repository.deleteCategory(kind: category.kind, name: category.name,
                                                expectedCreatedAt: category.createdAt,
                                                operationID: operationID, scope: scope, now: clock.wallMs)
        }
    }

    /// 开始计时后刷新活动快照，关联待办只提供上下文，不自动完成待办。
    func startFocus(title: String, taskID: String?, mode: NivoFocusMode, minutes: Int,
                    operationID: String, scope expectedScope: NivoLifeScope) async -> Bool {
        await startFocusResult(title: title, taskID: taskID, mode: mode, minutes: minutes, operationID: operationID, scope: expectedScope) != nil
    }

    /// 开始请求在返回与展示前都保持来源账户代次。
    func startFocusResult(title: String, taskID: String?, mode: NivoFocusMode, minutes: Int,
                          operationID: String, scope expectedScope: NivoLifeScope) async -> NivoFocusSession? {
        await performResult(scope: expectedScope) { repository, scope, clock in
            try await repository.startFocus(title: title, taskID: taskID, mode: mode, minutes: minutes,
                                            operationID: operationID, scope: scope, clock: clock)
        }
    }

    /// 操作使用界面所见版本，计时到期或其他入口已修改时不会覆盖新状态。
    func controlFocus(_ session: NivoFocusSession, action: String, scope expectedScope: NivoLifeScope) async -> Bool {
        await controlFocusResult(session, action: action, scope: expectedScope) != nil
    }

    /// 会话和页面必须属于同一账户，避免恢复时相同标识被错误控制。
    func controlFocusResult(_ session: NivoFocusSession, action: String,
                            operationID: String = UUID().uuidString, scope expectedScope: NivoLifeScope) async -> NivoFocusSession? {
        guard session.ownerKey == expectedScope.ownerKey else { return nil }
        return await performResult(scope: expectedScope) { repository, scope, clock in
            try await repository.controlFocus(action: action, id: session.id,
                                              expectedRevision: session.revision,
                                              operationID: operationID, scope: scope, clock: clock)
        }
    }

    private func performResult<T: Sendable>(
        scope expectedScope: NivoLifeScope,
        _ action: (NivoLifeRepository, NivoLifeScope, NivoFocusClockSample) async throws -> T
    ) async -> T? {
        guard !isBusy, isReady, let captured = accessScope, captured == expectedScope,
              captured.ownerKey == NanoMuseAccountData.shared.current else { return nil }
        let token = activationID
        isBusy = true
        errorMessage = nil
        defer { if token == activationID { isBusy = false } }
        do {
            let result = try await action(repository, captured, NivoLifeClock.sample())
            let snapshot = try await repository.snapshot(scope: captured, clock: NivoLifeClock.sample())
            guard token == activationID, captured.ownerKey == NanoMuseAccountData.shared.current else { return nil }
            apply(snapshot)
            return result
        } catch {
            if token == activationID { errorMessage = Self.message(error) }
            return nil
        }
    }

    /// AI工具保留真实错误及原请求，账户切换后的迟到结果不显示到新账户。
    func performToolResult<T: Sendable>(scope captured: NivoLifeScope,
        action: (NivoLifeRepository, NivoLifeScope, NivoFocusClockSample) async throws -> T
    ) async throws -> T {
        guard accessScope == captured, captured.ownerKey == NanoMuseAccountData.shared.current else { throw NivoLifeError.accountChanged }
        guard !isBusy else { throw NivoLifeError.invalidTransition("write_in_progress") }
        try Task.checkCancellation()
        let token = activationID
        isBusy = true
        defer { if activationID == token { isBusy = false } }
        do {
            let result = try await action(repository, captured, NivoLifeClock.sample())
            let snapshot = try await repository.snapshot(scope: captured, clock: NivoLifeClock.sample())
            guard activationID == token, accessScope == captured,
                  captured.ownerKey == NanoMuseAccountData.shared.current else { throw NivoLifeError.accountChanged }
            apply(snapshot)
            return result
        } catch {
            if activationID == token { errorMessage = Self.message(error) }
            throw error
        }
    }

    /// 冻结时保留计时展示，撤销写入凭证和旧的异步刷新结果。
    func beginBackupFreeze() {
        activationID = UUID()
        isBackupFrozen = true
        isBusy = true
        NivoCoachChatContext.shared.clear()
        NivoCoachV2ViewModel.shared.clear()
    }

    /// 恢复重新读取正式文件，旧的scope不能用于新一次编辑。
    func endBackupFreeze() async {
        isBackupFrozen = false
        isBusy = false
        clear()
        await activate()
    }

    private func clear() {
        appliedStoreRevision = nil
        isReady = false
        isMosaicReady = false
        scope = nil
        tasks = []
        categories = []
        focusSessions = []
        focusSpans = []
    }

    private func apply(_ snapshot: NivoLifeState) {
        let revision = snapshot.storeRevision ?? 0
        // 相同快照没有新数据，避免秒针刷新使待办、碎片和教练观察者重复重绘。
        if let appliedStoreRevision, revision <= appliedStoreRevision { return }
        appliedStoreRevision = revision
        tasks = snapshot.tasks.filter { $0.deletedAt == nil }.sorted { $0.updatedAt > $1.updatedAt }
        categories = snapshot.categories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        focusSessions = snapshot.focusSessions.filter { $0.deletedAt == nil }.sorted { $0.startedAt > $1.startedAt }
        focusSpans = snapshot.focusSpans
        NivoFocusNotifications.shared.update(session: activeFocus)
    }

    /// 具体错误引导恢复，原始系统磁盘错误继续使用系统本地化说明。
    static func message(_ error: Error) -> String {
        if error is NivoCredentialRestoreError { return AppLocalized("Could not save") }
        if error is NivoEnvVarTransaction.Failure { return AppLocalized("Could not save") }
        if error is NivoEnvVarState.Failure { return AppLocalized("Check the fields and try again.") }
        if error is NivoChatMutationError { return AppLocalized("This item changed. Reload before saving.") }
        if error is NivoSQLiteWriteError { return AppLocalized("Could not save") }
        switch error as? NivoLifeError {
        case .staleRevision: return AppLocalized("This item changed. Reload before saving.")
        case .accountChanged: return AppLocalized("The account changed. Open this page again.")
        case .corruptStore, .unsupportedVersion: return AppLocalized("Saved data could not be opened. The original file was preserved.")
        case .activeSessionExists: return AppLocalized("Finish the current focus session first.")
        case .operationConflict: return AppLocalized("This request was already used for different content.")
        case .notFound: return AppLocalized("This item no longer exists. Reload the list.")
        case .invalidTransition("pending_archive"): return AppLocalized("The previous lesson still has unsaved dialogue. Retry from Coach before starting another lesson.")
        case .invalidField, .invalidTransition: return AppLocalized("Check the fields and try again.")
        case nil: return error.localizedDescription
        }
    }
}
