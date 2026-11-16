import Foundation

/// 专注请求签名不包含实时采样值，网络重试复用第一次的真实操作结果。
private struct NivoFocusRequest: Codable {
    var action: String
    var id: String?
    var expectedRevision: Int64?
    var title: String?
    var taskID: String?
    var mode: NivoFocusMode?
    var minutes: Int?
}

extension NivoLifeRepository {
    /// 工具签名包含宿主用户回合，原版本在精确回放之后才与当前计时比较。
    func executeFocusTool(_ request: NivoFocusToolCommand, operationID: String, scope: NivoLifeScope,
                          clock: NivoFocusClockSample) throws -> NivoFocusSession {
        try executeFocusToolResult(request, operationID: operationID, scope: scope, clock: clock).value
    }

    /// 相同版本也可能是精确重试，回放标志必须来自仓库事务。
    func executeFocusToolResult(_ request: NivoFocusToolCommand, operationID: String, scope: NivoLifeScope,
                               clock: NivoFocusClockSample) throws -> NivoLifeTransactionResult<NivoFocusSession> {
        try transactionResult(operationID: operationID, request: request, scope: scope) { state in
            if request.action == "start" {
                return try applyStart(title: request.title, taskID: request.taskID, mode: request.mode,
                    minutes: request.minutes, owner: scope.ownerKey, state: &state, clock: clock)
            }
            guard let expected = request.expectedRevision else { throw NivoLifeError.invalidField("expectedRevision") }
            return try applyControl(action: request.action, id: request.targetID, expectedRevision: expected,
                                    state: &state, clock: clock)
        }
    }

    /// 同一账号最多有一个活动计时，暂停中的计时也占用活动位置。
    func startFocus(
        title: String, taskID: String? = nil, mode: NivoFocusMode, minutes: Int,
        operationID: String, scope: NivoLifeScope, clock: NivoFocusClockSample
    ) throws -> NivoFocusSession {
        let request = NivoFocusRequest(
            action: "start_focus", title: title, taskID: taskID, mode: mode, minutes: minutes
        )
        return try transaction(operationID: operationID, request: request, scope: scope) { state in
            try applyStart(title: title, taskID: taskID, mode: mode, minutes: minutes,
                           owner: scope.ownerKey, state: &state, clock: clock)
        }
    }

    /// 控制计时器只结算真实区间，不接收外部elapsedMs或endedAt。
    func controlFocus(
        action: String, id: String, expectedRevision: Int64,
        operationID: String, scope: NivoLifeScope, clock: NivoFocusClockSample
    ) throws -> NivoFocusSession {
        let request = NivoFocusRequest(action: "focus_" + action, id: id, expectedRevision: expectedRevision)
        return try transaction(operationID: operationID, request: request, scope: scope) { state in
            try applyControl(action: action, id: id, expectedRevision: expectedRevision, state: &state, clock: clock)
        }
    }

    private func applyStart(title: String, taskID: String?, mode: NivoFocusMode, minutes: Int,
                            owner: String, state: inout NivoLifeState, clock: NivoFocusClockSample) throws -> NivoFocusSession {
        _ = try reconcileFocus(state: &state, clock: clock)
        guard !state.focusSessions.contains(where: \.isActive) else { throw NivoLifeError.activeSessionExists }
        let task = try taskID.map { identifier in
            guard let task = state.tasks.first(where: { $0.id == identifier && $0.deletedAt == nil }) else {
                throw NivoLifeError.notFound("task")
            }
            return task
        }
        let result = try NivoFocusRules.start(owner: owner, id: UUID().uuidString, title: title, task: task,
            mode: mode, minutes: minutes, clock: clock)
        state.focusSessions.append(result)
        return result
    }

    private func applyControl(action: String, id: String, expectedRevision: Int64,
                              state: inout NivoLifeState, clock: NivoFocusClockSample) throws -> NivoFocusSession {
        guard let index = state.focusSessions.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
            throw NivoLifeError.notFound("focus")
        }
        let result = try NivoFocusRules.mutate(state.focusSessions[index], action: action,
            expectedRevision: expectedRevision, clock: clock, spanID: UUID().uuidString)
        state.focusSessions[index] = result.session
        if let span = result.span { state.focusSpans.append(span) }
        return result.session
    }
}
