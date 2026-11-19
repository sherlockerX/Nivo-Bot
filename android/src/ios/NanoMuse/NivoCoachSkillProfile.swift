import Foundation

/// 把日期键固定在训练开始时的本地日期，旧记录则按开始时间推算。
enum NivoCoachDay {
    static func key(_ milliseconds: Int64, zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func key(_ session: NivoCoachSession, zone: TimeZone = .current) -> String? {
        if let stored = session.localDate, !stored.isEmpty { return stored }
        return session.startedAt > 0 ? key(session.startedAt, zone: zone) : nil
    }
}

/// 同一天继续，跨天的未完成课由用户决定是否封存。
enum NivoCoachTodayState: String, Sendable {
    case notStarted, inProgress, earlierUnfinished, done
}

/// 提供今日卡以及进入训练时使用的同一份事实。
struct NivoCoachToday {
    let status: NivoCoachTodayState
    let openLesson: NivoCoachSession?
    let lessons: [NivoCoachSession]
    let plan: NivoCoachLessonPlan?
}

/// 保留行为证据的定位信息，以便从档案回查到原话。
struct NivoCoachEvidenceReference: Codable, Sendable {
    let sessionId: String
    let turnId: String
    let messageId: String
    let chatSessionId: String
    let quote: String
    let reason: String
    let at: Int64
    let support: String
    let context: String
}

/// 每个维度分开显示，避免把练习记录折算成能力分数。
struct NivoCoachPerformanceItem: Identifiable, Sendable {
    let dimension: String
    let status: String
    let evidence: NivoCoachEvidenceReference?
    var dueAt: Int64? = nil
    var id: String { dimension }
}

/// 下次训练的依据与决定。
struct NivoCoachNextStep: Sendable {
    let kind: String
    var basis: NivoCoachEvidenceReference? = nil
}

/// 训练档案与备课共同使用的推导，当前单元的表现不混入旧标准。
enum NivoCoachSkillProfile {
    static let OPEN_STATUSES: Set<String> = ["active", "paused", "waiting_real"]

    static func topic(_ state: NivoCoachState, courseID: String) -> NivoCoachTopic? {
        let candidates = state.topics.filter { $0.courseID == courseID && $0.status == "active" }
        return candidates.last { !$0.chatSessionID.isEmpty } ?? candidates.last
    }

    static func lessons(_ state: NivoCoachState, courseID: String) -> [NivoCoachSession] {
        guard let track = state.tracks.first(where: { $0.id == courseID }) else { return [] }
        return state.sessions.filter {
            $0.course.id == courseID && $0.teachingProtocol == "topic-v3" &&
                $0.course.version == track.course.version && !$0.requiresCourseReview
        }
    }

    static func today(_ state: NivoCoachState, courseID: String, day: String, zone: TimeZone) -> NivoCoachToday {
        let openID = topic(state, courseID: courseID)?.activeSessionID
        let matching = lessons(state, courseID: courseID)
        let open = matching.first { $0.id == openID && OPEN_STATUSES.contains($0.status) }
        let todays = matching.filter { NivoCoachDay.key($0, zone: zone) == day }
        let plan = state.plans?.last { $0.courseId == courseID && $0.localDate == day && $0.status == "adopted" }
        let status: NivoCoachTodayState
        if let open {
            let openDay = NivoCoachDay.key(open, zone: zone)
            status = openDay == nil || openDay == day ? .inProgress : .earlierUnfinished
        } else {
            status = todays.contains { ["complete", "sealed"].contains($0.status) } ? .done : .notStarted
        }
        return NivoCoachToday(status: status, openLesson: open, lessons: todays, plan: plan)
    }

    static func performance(_ state: NivoCoachState, courseID: String, now: Int64) -> [NivoCoachPerformanceItem] {
        guard let track = state.tracks.first(where: { $0.id == courseID }),
              let unit = track.course.units.first(where: { $0.id == track.currentUnitID }) else { return [] }
        let recent = lessons(state, courseID: courseID).filter { $0.unitID == unit.id }
        let dimensions = unit.criteria.map(NivoCoachPolicy.dimension).filter { !$0.isEmpty }
        var seen = Set<String>()
        let items = dimensions.filter { seen.insert($0).inserted }.map { dimension -> NivoCoachPerformanceItem in
            if let valid = latestEvidence(recent, where: { _, turn, _ in turn.dimension == dimension }) {
                return NivoCoachPerformanceItem(dimension: dimension, status: "independent", evidence: valid)
            }
            if let attempt = latestAttempt(recent, dimension: dimension) {
                let reference = ref(attempt.lesson, turn: attempt.turn)
                return NivoCoachPerformanceItem(dimension: dimension,
                    status: attempt.turn.support == "hinted" ? "hinted" : "attempted", evidence: reference)
            }
            return NivoCoachPerformanceItem(dimension: dimension, status: "none", evidence: nil)
        }
        return items + [delayed(recent, state: state, dimensions: dimensions, now: now)]
    }

    static func nextStep(_ state: NivoCoachState, courseID: String, now: Int64) -> NivoCoachNextStep {
        guard let track = state.tracks.first(where: { $0.id == courseID }) else { return NivoCoachNextStep(kind: "diagnose") }
        let recent = lessons(state, courseID: courseID).filter { $0.unitID == track.currentUnitID }
        if track.demonstrated.contains(track.currentUnitID) { return NivoCoachNextStep(kind: "advance") }
        let sessionIDs = Set(recent.map(\.id))
        if state.actions.contains(where: { sessionIDs.contains($0.sessionID) && ["planned", "deferred"].contains($0.status) }) {
            return NivoCoachNextStep(kind: "real_action")
        }
        let attempt = latestAttempt(recent)
        if let disputed = mostRecentDisputed(recent), disputed.at >= (attempt?.turn.createdAt ?? 0) {
            return NivoCoachNextStep(kind: "disputed", basis: disputed)
        }
        guard let attempt else { return NivoCoachNextStep(kind: "diagnose") }
        let evidence = attempt.lesson.evidence.last { $0.turnID == attempt.turn.id }
        let basis = ref(attempt.lesson, turn: attempt.turn, evidence: evidence)
        guard let evidence, matches(evidence, in: attempt.lesson) else {
            return NivoCoachNextStep(kind: attempt.turn.support == "hinted" ? "independent_first" : "continue", basis: basis)
        }
        let results = performance(state, courseID: courseID, now: now)
        if results.filter({ $0.dimension != "delayed" }).allSatisfy({ $0.status == "independent" }),
           let delayed = results.first(where: { $0.dimension == "delayed" }) {
            if delayed.status == "due" { return NivoCoachNextStep(kind: "delayed_review", basis: basis) }
            if delayed.status == "waiting" { return NivoCoachNextStep(kind: "wait_review", basis: basis) }
        }
        return NivoCoachNextStep(kind: "new_scenario", basis: basis)
    }

    private static func delayed(_ lessons: [NivoCoachSession], state: NivoCoachState,
                                dimensions: [String], now: Int64) -> NivoCoachPerformanceItem {
        if let evidence = latestEvidence(lessons, where: { session, turn, _ in
            NivoCoachTeaching.isValidDelayedReview(turn, session: session, state: state)
        }) {
            return NivoCoachPerformanceItem(dimension: "delayed", status: "independent", evidence: evidence)
        }
        let eligible = lessons.filter { session in
            session.status == "complete" && session.endedAt > 0 &&
                dimensions.contains { NivoCoachTeaching.hasImmediateEvidence(session, dimension: $0) }
        }.map(\.endedAt).min()
        guard let eligible else { return NivoCoachPerformanceItem(dimension: "delayed", status: "none", evidence: nil) }
        let due = eligible + NivoCoachTeaching.MIN_REVIEW_DELAY
        return NivoCoachPerformanceItem(dimension: "delayed", status: now >= due ? "due" : "waiting",
            evidence: nil, dueAt: due)
    }

    private static func matches(_ evidence: NivoCoachEvidence, in session: NivoCoachSession) -> Bool {
        evidence.met && !evidence.disputed && (try? NivoCoachTeaching.validate(evidence, session: session)) != nil
    }

    private static func latestEvidence(_ lessons: [NivoCoachSession],
        where predicate: (NivoCoachSession, NivoCoachTurn, NivoCoachEvidence) -> Bool) -> NivoCoachEvidenceReference? {
        lessons.flatMap { lesson in
            lesson.evidence.compactMap { evidence -> NivoCoachEvidenceReference? in
                guard matches(evidence, in: lesson),
                      let turn = lesson.turns.first(where: { $0.id == evidence.turnID }),
                      predicate(lesson, turn, evidence) else { return nil }
                return ref(lesson, turn: turn, evidence: evidence)
            }
        }.sorted { $0.at < $1.at }.last
    }

    private static func mostRecentDisputed(_ lessons: [NivoCoachSession]) -> NivoCoachEvidenceReference? {
        for lesson in lessons.reversed() {
            if let evidence = lesson.evidence.last(where: \.disputed),
               let turn = lesson.turns.first(where: { $0.id == evidence.turnID }) {
                return ref(lesson, turn: turn, evidence: evidence)
            }
        }
        return nil
    }

    private static func latestAttempt(_ lessons: [NivoCoachSession], dimension: String? = nil)
        -> (lesson: NivoCoachSession, turn: NivoCoachTurn)? {
        lessons.flatMap { lesson in
            lesson.turns.filter { turn in
                turn.role == "user" && turn.purpose == "attempt" && !turn.sourceInvalidated &&
                    (dimension == nil || turn.dimension == dimension)
            }.map { (lesson: lesson, turn: $0) }
        }.sorted { $0.turn.createdAt < $1.turn.createdAt }.last
    }

    private static func ref(_ session: NivoCoachSession, turn: NivoCoachTurn,
                            evidence: NivoCoachEvidence? = nil) -> NivoCoachEvidenceReference {
        NivoCoachEvidenceReference(sessionId: session.id, turnId: turn.id, messageId: turn.originMessageID,
            chatSessionId: session.chatSessionID, quote: evidence?.quote ?? String(turn.text.prefix(300)),
            reason: evidence?.reason ?? "", at: turn.createdAt, support: turn.support, context: turn.context)
    }
}
