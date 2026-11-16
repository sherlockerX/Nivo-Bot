import Foundation

/// 专注状态机只接受设备时钟，不接受用户或模型指定已专注时长。
enum NivoFocusRules {
    static let maximumSessionMs: Int64 = 12 * 60 * 60 * 1_000

    /// 同一开机周期使用单调时钟，跨重启的未知区间不计入。
    static func delta(_ session: NivoFocusSession, clock: NivoFocusClockSample) -> Int64 {
        guard session.status == .running, session.bootID == clock.bootID,
              session.runningElapsed >= 0, clock.elapsedMs >= session.runningElapsed else { return 0 }
        return min(clock.elapsedMs - session.runningElapsed, max(0, session.targetMs - session.elapsedMs))
    }

    /// 当前展示值不写盘，暂停和已结束状态始终返回已提交时长。
    static func currentElapsed(_ session: NivoFocusSession, clock: NivoFocusClockSample) -> Int64 {
        session.elapsedMs + delta(session, clock: clock)
    }

    /// 生成真实开始记录，关联任务的标题、分组和标签均取任务当前快照。
    static func start(
        owner: String, id: String, title: String, task: NivoTodoTask?,
        mode: NivoFocusMode, minutes: Int, clock: NivoFocusClockSample
    ) throws -> NivoFocusSession {
        guard (1...180).contains(minutes), clock.elapsedMs >= 0, !clock.bootID.isEmpty else {
            throw NivoLifeError.invalidField("duration")
        }
        if let task {
            guard task.ownerKey == owner, task.deletedAt == nil else { throw NivoLifeError.notFound("task") }
        }
        let name = (task?.title ?? title).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 500 else { throw NivoLifeError.invalidField("title") }
        return NivoFocusSession(
            ownerKey: owner, id: id, title: name, taskId: task?.id,
            groupName: task?.groupName ?? "", tags: task?.tags ?? [], mode: mode,
            targetMs: mode == .stopwatch ? maximumSessionMs : Int64(minutes) * 60_000,
            startedAt: clock.wallMs, updatedAt: clock.wallMs,
            runningWall: clock.wallMs, runningElapsed: clock.elapsedMs, bootID: clock.bootID
        )
    }

    /// 在边界提交区间并暂停，已到目标时长才自动结束。
    static func settle(
        _ input: NivoFocusSession, clock: NivoFocusClockSample, spanID: String
    ) -> (session: NivoFocusSession, span: NivoFocusSpan?) {
        guard input.status == .running else { return (input, nil) }
        let duration = delta(input, clock: clock)
        var session = input
        session.elapsedMs += duration
        let isFinished = session.elapsedMs >= session.targetMs
        session.status = isFinished ? .finished : .paused
        session.endedAt = isFinished ? input.runningWall + duration : nil
        session.runningElapsed = clock.elapsedMs
        session.runningWall = clock.wallMs
        session.bootID = clock.bootID
        let span = duration > 0 ? NivoFocusSpan(
            id: spanID, sessionId: input.id, startedAt: input.runningWall, durationMs: duration
        ) : nil
        return (session, span)
    }

    /// 暂停、继续、结束和删除都校验旧版本，完成专注不改变待办状态。
    static func mutate(
        _ input: NivoFocusSession, action: String, expectedRevision: Int64,
        clock: NivoFocusClockSample, spanID: String
    ) throws -> (session: NivoFocusSession, span: NivoFocusSpan?) {
        guard input.deletedAt == nil else { throw NivoLifeError.notFound("focus") }
        try NivoTodoRules.requireRevision(expectedRevision, actual: input.revision)
        let settled = settle(input, clock: clock, spanID: spanID)
        var session = settled.session
        switch action {
        case "pause":
            guard input.status == .running else { throw NivoLifeError.invalidTransition("not_running") }
        case "resume":
            guard input.status == .paused else { throw NivoLifeError.invalidTransition("not_paused") }
            session.status = .running
            session.runningWall = clock.wallMs
            session.runningElapsed = clock.elapsedMs
            session.bootID = clock.bootID
        case "finish":
            session.status = .finished
            session.endedAt = session.endedAt ?? clock.wallMs
        case "delete":
            guard input.status == .finished else { throw NivoLifeError.invalidTransition("finish_before_delete") }
            session.deletedAt = clock.wallMs
        default:
            throw NivoLifeError.invalidField("action")
        }
        guard input.revision < Int64.max else { throw NivoLifeError.invalidField("revision") }
        session.revision = input.revision + 1
        session.updatedAt = clock.wallMs
        return (session, settled.span)
    }

    /// 已结束且未删除的非休息区间才计入统计，范围采用左闭右开时间戳。
    static func duration(
        sessions: [NivoFocusSession], spans: [NivoFocusSpan], startMs: Int64, endMs: Int64
    ) -> Int64 {
        guard endMs > startMs else { return 0 }
        let eligible = Set(sessions.filter {
            $0.status == .finished && $0.deletedAt == nil && $0.mode != .rest
        }.map(\.id))
        return spans.filter { eligible.contains($0.sessionId) }.reduce(0) { total, span in
            total + max(0, min(endMs, span.startedAt + span.durationMs) - max(startMs, span.startedAt))
        }
    }
}
