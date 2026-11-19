import Foundation
import Combine

/// 将课程、持续案例和每日练习对话连接起来；重复点击和中断重试都复用稳定身份。
@MainActor
final class NivoCoachConversationCoordinator: ObservableObject {
    static let shared = NivoCoachConversationCoordinator()
    @Published private(set) var isOpening = false

    /// 从课程页进入当前单元的专题，显式操作才开始或恢复课次。
    func open(courseID: String, unitID: String, scope: NivoLifeScope, startToday: Bool = false,
              minutes: Int = 15, need: String = "") async throws -> String {
        guard !isOpening else { throw NivoCoachConversationError.opening }
        try requireScope(scope)
        let ownerKey = scope.ownerKey
        isOpening = true
        defer { isOpening = false }
        let generation = try await NivoCoachV2Store.shared.access(ownerKey: ownerKey)
        try requireScope(scope)
        let topic = try await selectTopic(courseID: courseID, unitID: unitID, scope: scope)
        try requireScope(scope)
        let chatID = try await ensureConversation(topic: topic, scope: scope, generation: generation)
        try requireScope(scope)
        try await NivoCoachV2Store.shared.bindTopicConversation(topicID: topic.id, chatSessionID: chatID, ownerKey: ownerKey, generation: generation)
        try requireScope(scope)
        if let failure = try await NivoCoachArchiveRecovery.retry(chatID: chatID, scope: scope, generation: generation) {
            throw NivoCoachConversationError.archive(failure)
        }
        try await NivoCoachReconciliation.reconcile(chatSessionID: chatID, scope: scope, generation: generation)
        try requireScope(scope)
        let snapshot = try await NivoCoachV2Store.shared.snapshot(ownerKey: ownerKey)
        let now = Self.now()
        let zone = TimeZone.current
        let today = NivoCoachSkillProfile.today(snapshot, courseID: courseID, day: NivoCoachDay.key(now, zone: zone), zone: zone)
        let shouldCreate = today.status == .notStarted || today.status == .done ||
            (today.status == .earlierUnfinished && startToday)
        if shouldCreate {
            try await preparePlan(courseID: courseID, chatID: chatID, scope: scope,
                                  generation: generation, minutes: minutes, need: need)
        }
        let result = try await command(shouldCreate ? "start_today" : "start_lesson", targetID: topic.id, scope: scope)
        try requireScope(scope)
        let state = try await NivoCoachV2Store.shared.snapshot(ownerKey: ownerKey)
        try requireScope(scope)
        if state.sessions.first(where: { $0.id == result.targetID })?.status == "paused" {
            _ = try await command("resume_session", targetID: result.targetID, scope: scope)
        }
        try requireScope(scope)
        await NivoCoachChatContext.shared.refresh(sessionID: chatID)
        try requireScope(scope)
        NotificationCenter.default.post(name: .sessionDidUpdate, object: nil)
        return chatID
    }

    /// 专题页继续学习与技能页使用同一个备课入口。
    func startFromChat(topic: NivoCoachTopic, scope: NivoLifeScope) async throws {
        let state = try await NivoCoachV2Store.shared.snapshot(ownerKey: scope.ownerKey)
        try requireScope(scope)
        guard NivoCoachSkillProfile.topic(state, courseID: topic.courseID)?.id == topic.id else {
            throw NivoLifeError.invalidTransition("coach_topic")
        }
        let track = try state.track(topic.courseID)
        _ = try await open(courseID: track.id, unitID: track.currentUnitID, scope: scope)
    }

    private func preparePlan(courseID: String, chatID: String, scope: NivoLifeScope, generation: UUID,
                             minutes: Int, need: String) async throws {
        try requireScope(scope)
        let store = NivoCoachV2Store.shared
        let snapshot = try await store.snapshot(ownerKey: scope.ownerKey)
        let track = try snapshot.track(courseID)
        let now = Self.now()
        let zone = TimeZone.current
        let boundedNeed = NivoCoachLessonPlanRules.trimmedNeed(need)
        let desiredMinutes = min(120, max(3, minutes))
        let day = NivoCoachDay.key(now, zone: zone)
        if NivoCoachLessonPlanRules.reusable(snapshot, courseID: courseID, unitID: track.currentUnitID,
            version: track.course.version, day: day, minutes: desiredMinutes, need: boundedNeed) != nil { return }
        let base = try NivoCoachLessonPlanRules.base(snapshot, courseID: courseID, now: now, zone: zone,
            minutes: desiredMinutes, need: boundedNeed)
        let providerStore = ProviderConfigStore.shared
        let selected = providerStore.binding(for: chatID).flatMap {
            providerStore.entry(for: $0.primarySource.preferredReference)
        }
        var plan = try await NivoCoachLessonPrep.prepare(state: snapshot, base: base,
            entry: selected ?? providerStore.nmLatestChatEntry)
        try requireScope(scope)
        let current = try await store.snapshot(ownerKey: scope.ownerKey)
        let currentTrack = try current.track(courseID)
        guard currentTrack.currentUnitID == track.currentUnitID, currentTrack.course.version == track.course.version,
              !currentTrack.paused else { throw NivoLifeError.invalidTransition("stale_plan_course") }
        if NivoCoachDay.key(Self.now(), zone: .current) != plan.localDate ||
            (try? NivoCoachLessonPlanRules.validate(plan, state: current)) == nil {
            plan = try NivoCoachLessonPlanRules.base(current, courseID: courseID, now: Self.now(), zone: .current,
                minutes: desiredMinutes, need: boundedNeed)
            plan.degradeReason = "invalid"
        }
        let data = try JSONEncoder().encode(plan)
        let request = NivoCoachCommand(action: "adopt_plan", operationID: "plan:\(plan.id)",
            expectedRevision: current.revision, targetID: courseID, payload: String(decoding: data, as: UTF8.self))
        let context = NivoCoachCommandContext(ownerKey: scope.ownerKey, generation: generation, isHost: true)
        _ = try await store.execute(request, context: context)
        try requireScope(scope)
    }

    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    /// 本地按钮与模型共用同一个事务入口，排队期间不得借用恢复后的新账户代次。
    @discardableResult
    func command(_ action: String, targetID: String, scope: NivoLifeScope,
                 text: String = "", payload: [String: String] = [:]) async throws -> NivoCoachCommandResult {
        try requireScope(scope)
        let ownerKey = scope.ownerKey
        let generation = try await NivoCoachV2Store.shared.access(ownerKey: ownerKey)
        try requireScope(scope)
        if action == "advance" {
            // 原文可能在另一页面被改动；推进前重新核对证据，再读取对应版本。
            try await NivoCoachReconciliation.reconcileAll(scope: scope, generation: generation)
            try requireScope(scope)
        }
        var snapshot = try await NivoCoachV2Store.shared.snapshot(ownerKey: ownerKey)
        if ["start_lesson", "start_today"].contains(action), let topic = snapshot.topics.first(where: { $0.id == targetID }),
           !topic.chatSessionID.isEmpty {
            try requireScope(scope)
            if let failure = try await NivoCoachArchiveRecovery.retry(chatID: topic.chatSessionID,
                scope: scope, generation: generation) { throw NivoCoachConversationError.archive(failure) }
            // 归档会推进版本，开始新课必须重新读取同一账户的最新快照。
            snapshot = try await NivoCoachV2Store.shared.snapshot(ownerKey: ownerKey)
        }
        try requireScope(scope)
        let data = try JSONEncoder().encode(payload)
        let request = NivoCoachCommand(action: action, operationID: UUID().uuidString,
                                       expectedRevision: snapshot.revision, targetID: targetID,
                                       text: text, payload: String(decoding: data, as: UTF8.self))
        let context = NivoCoachCommandContext(ownerKey: ownerKey, generation: generation, isHost: true)
        let result = try await NivoCoachV2Store.shared.execute(request, context: context)
        try requireScope(scope)
        NotificationCenter.default.post(name: .nivoCoachStateChanged, object: ownerKey)
        return result
    }

    private func selectTopic(courseID: String, unitID: String, scope: NivoLifeScope) async throws -> NivoCoachTopic {
        try requireScope(scope)
        let ownerKey = scope.ownerKey
        let snapshot = try await NivoCoachV2Store.shared.snapshot(ownerKey: ownerKey)
        try requireScope(scope)
        guard let track = snapshot.tracks.first(where: { $0.id == courseID }), !track.paused,
              !track.course.needsCriteriaReview,
              track.currentUnitID == unitID,
              let unit = track.course.units.first(where: { $0.id == unitID }), !unit.needsCriteriaReview else {
            throw NivoLifeError.invalidField("course_review")
        }
        if let existing = NivoCoachSkillProfile.topic(snapshot, courseID: courseID) {
            return existing
        }
        let created = try await command("start_topic", targetID: courseID, scope: scope,
                                        text: unit.focus, payload: ["unitId": unitID, "title": unit.title])
        let current = try await NivoCoachV2Store.shared.snapshot(ownerKey: ownerKey)
        try requireScope(scope)
        guard let topic = current.topics.first(where: { $0.id == created.targetID }) else { throw NivoLifeError.notFound("coach_topic") }
        return topic
    }

    private func ensureConversation(topic: NivoCoachTopic, scope: NivoLifeScope, generation: UUID) async throws -> String {
        let ownerKey = scope.ownerKey
        let identifier = topic.chatSessionID.isEmpty
            ? NivoCoachConversationIdentity.conversation(owner: ownerKey, topicID: topic.id) : topic.chatSessionID
        try requireScope(scope)
        guard NanoMuseSync.shared.shows(identifier) else { throw NivoLifeError.accountChanged }
        let existence = try await ChatStore.shared.nmCoachSources(chatSessionID: identifier, identifiers: [])
        try requireScope(scope)
        if existence.sessionExists {
            guard let saved = await ChatStore.shared.getSession(identifier) else { throw NivoLifeError.corruptStore }
            try requireScope(scope)
            guard saved.source == NivoCoachConversationIdentity.source else { throw NivoCoachConversationError.identityConflict }
            try NanoMuseAccountData.shared.claim(identifier, owner: ownerKey)
            try await restoreBinding(identifier, scope: scope)
            return identifier
        }
        if !topic.chatSessionID.isEmpty {
            try requireScope(scope)
            try await NivoCoachV2Store.shared.invalidateConversation(chatSessionID: identifier, reason: "conversation_deleted", ownerKey: ownerKey, generation: generation)
            throw NivoCoachConversationError.deleted
        }
        let request = try creation(topic: topic, identifier: identifier, ownerKey: ownerKey)
        try NanoMuseAccountData.shared.claim(identifier, owner: ownerKey)
        _ = try await ChatStore.shared.nmEnsureCoachConversation(request)
        // 创建期间即使账号切换，所有权仍落到进入时捕获的账号，不让新账号认领。
        try NanoMuseAccountData.shared.claim(identifier, owner: ownerKey)
        try requireScope(scope)
        try await restoreBinding(identifier, scope: scope)
        return identifier
    }

    private func creation(topic: NivoCoachTopic, identifier: String, ownerKey: String) throws -> NivoCoachChatCreation {
        let providers = ProviderConfigStore.shared
        let group = providers.defaultPrimaryGroupId.flatMap { providers.group(for: $0) }
        let groupEntry = group.flatMap { ModelGroupRouter.resolve(group: $0, sessionId: identifier, store: providers) }
            .flatMap { providers.entry(for: $0) }
        let entry = groupEntry ?? providers.nmLatestChatEntry
        guard let entry else { throw ModelUnavailable() }
        let source: SessionModelSource
        if groupEntry != nil, let group { source = .group(groupId: group.id, resolvedEntryId: entry.id) }
        else { source = .directEntry(modelEntryId: entry.id, compositeKey: entry.id) }
        let binding = SessionModelBinding(sessionId: identifier, primarySource: source, subModelSource: nil)
        let data = try JSONEncoder().encode(binding)
        return NivoCoachChatCreation(id: identifier, title: topic.title, modelID: entry.model.id,
                                     modelBinding: String(decoding: data, as: UTF8.self),
                                     folderID: NivoCoachConversationIdentity.folder(owner: ownerKey),
                                     folderName: AppLocalized("Daily practice"),
                                     memoryEnabled: UserDefaults.standard.object(forKey: "memory.global.enabled") as? Bool ?? true)
    }

    private func requireOwner(_ ownerKey: String) throws {
        guard NivoLifeModel.shared.isReady, NivoLifeModel.shared.ownerKey == ownerKey,
              NanoMuseAccountData.shared.current == ownerKey else { throw NivoLifeError.accountChanged }
    }

    private func requireScope(_ scope: NivoLifeScope) throws {
        guard NivoLifeModel.shared.accessScope == scope else { throw NivoLifeError.accountChanged }
        try requireOwner(scope.ownerKey)
    }

    /// 会话事务中的绑定可在重试时恢复到提供商缓存，避免创建中断后丢失模型选择。
    private func restoreBinding(_ identifier: String, scope: NivoLifeScope) async throws {
        try requireScope(scope)
        guard ProviderConfigStore.shared.binding(for: identifier) == nil else { return }
        let extras = await ChatStore.shared.getSessionExtras(identifier)
        try requireScope(scope)
        if let encoded = extras.modelBinding, let data = encoded.data(using: .utf8),
           let binding = try? JSONDecoder().decode(SessionModelBinding.self, from: data) {
            ProviderConfigStore.shared.setBinding(binding, for: identifier)
        }
    }

    private struct ModelUnavailable: LocalizedError {
        var errorDescription: String? { AppLocalized("No model configured. Add a provider in Settings.") }
    }
}
