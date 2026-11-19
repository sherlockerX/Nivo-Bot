import Foundation

/// 教案引用必须能逐字匹配同课程的有效用户原话。
struct NivoCoachPlanBasis: Codable, Equatable, Sendable {
    var sessionId: String
    var turnId: String
    var quote: String
}

/// 材料的来源声明是教案的一部分。
struct NivoCoachPlanMaterial: Codable, Equatable, Sendable {
    var title: String
    var origin: String
}

/// 已采用的计划保留宿主身份、采用时的课程版本及备课的质量记录。
struct NivoCoachLessonPlan: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var courseId: String
    var unitId: String
    var courseVersion: String
    var localDate: String
    var zoneId: String
    var minutes: Int
    var need: String
    var nextKind: String
    var task: String
    var reason = ""
    var observe = ""
    var concepts: [String] = []
    var materials: [NivoCoachPlanMaterial] = []
    var hints: [String] = []
    var branches: [String] = []
    var check = ""
    var criteriaIds: [String] = []
    var review = ""
    var coachNotes = ""
    var basis: [NivoCoachPlanBasis] = []
    var source = "base"
    var model = ""
    var degradeReason = ""
    var status = "adopted"
    var createdAt: Int64
    var inputRevision: Int64
    var elapsedMs: Int64 = 0
    var attempts = 0
    var skills: [String] = []

    var teachingContext: [String: Any] {
        ["task": task, "reason": reason, "observe": observe, "concepts": concepts,
         "materials": materials.map { ["title": $0.title, "origin": $0.origin] },
         "hints": hints, "branches": branches, "check": check, "criteriaIds": criteriaIds,
         "review": review, "coachNotes": coachNotes, "source": source, "nextKind": nextKind,
         "minutes": minutes, "learnerNeed": need]
    }
}

/// 模型只填教学内容。身份、训练标准和证据都由宿主校验。
enum NivoCoachLessonPlanRules {
    static let ORIGINS: Set<String> = ["course", "user", "self_authored", "unverified"]

    static func trimmedNeed(_ need: String) -> String {
        String(need.trimmingCharacters(in: .whitespacesAndNewlines).prefix(whileUTF16Fits: 600))
    }

    static func reusable(_ state: NivoCoachState, courseID: String, unitID: String, version: String,
                         day: String, minutes: Int, need: String) -> NivoCoachLessonPlan? {
        state.plans?.last {
            $0.courseId == courseID && $0.unitId == unitID && $0.courseVersion == version &&
                $0.localDate == day && $0.minutes == minutes && $0.need == need && $0.status == "adopted" &&
                (try? validate($0, state: state)) != nil
        }
    }

    static func base(_ state: NivoCoachState, courseID: String, now: Int64, zone: TimeZone,
                     minutes: Int, need: String) throws -> NivoCoachLessonPlan {
        let track = try state.track(courseID)
        guard let unit = track.course.units.first(where: { $0.id == track.currentUnitID }) else {
            throw NivoLifeError.notFound("coach_unit")
        }
        let next = NivoCoachSkillProfile.nextStep(state, courseID: courseID, now: now)
        var plan = NivoCoachLessonPlan(courseId: courseID, unitId: unit.id, courseVersion: track.course.version,
            localDate: NivoCoachDay.key(now, zone: zone), zoneId: zone.identifier, minutes: minutes,
            need: trimmedNeed(need), nextKind: next.kind, task: unit.focus.prefix(whileUTF16Fits: 1_200),
            createdAt: now, inputRevision: state.revision)
        plan.observe = unit.criteria.map(\.description).joined(separator: "\n").prefix(whileUTF16Fits: 1_200)
        plan.check = unit.criteria.first { NivoCoachPolicy.dimension($0) == "application" }?
            .description.prefix(whileUTF16Fits: 600) ?? ""
        if !unit.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            plan.materials = [NivoCoachPlanMaterial(title: unit.source.prefix(whileUTF16Fits: 300), origin: "course")]
        }
        plan.criteriaIds = unit.criteria.map(\.id)
        if let evidence = next.basis, let lesson = state.sessions.first(where: { $0.id == evidence.sessionId }),
           let turn = lesson.turns.first(where: { $0.id == evidence.turnId && !$0.sourceInvalidated }),
           turn.text.contains(evidence.quote), !evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            plan.basis = [NivoCoachPlanBasis(sessionId: evidence.sessionId, turnId: evidence.turnId,
                quote: evidence.quote.prefix(whileUTF16Fits: 300))]
        }
        return plan
    }

    static func validate(_ plan: NivoCoachLessonPlan, state: NivoCoachState) throws {
        let track = try state.track(plan.courseId)
        guard track.course.version == plan.courseVersion, track.currentUnitID == plan.unitId,
              let unit = track.course.units.first(where: { $0.id == plan.unitId }) else {
            throw NivoLifeError.invalidField("stale_plan_course")
        }
        guard (3...120).contains(plan.minutes),
              plan.localDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              hasText(plan.task, limit: 1_200), !plan.criteriaIds.isEmpty,
              Set(plan.criteriaIds).isSubset(of: Set(unit.criteria.map(\.id))) else {
            throw NivoLifeError.invalidField("plan_task_or_criteria")
        }
        try validateContent(plan)
        try validateBasis(plan, state: state)
    }

    private static func validateContent(_ plan: NivoCoachLessonPlan) throws {
        if plan.source != "base" {
            guard [plan.reason, plan.observe, plan.check].allSatisfy({ hasText($0, limit: 1_200) }),
                  !plan.hints.isEmpty, !plan.branches.isEmpty else { throw NivoLifeError.invalidField("plan_fields_missing") }
        }
        guard [plan.concepts, plan.hints, plan.branches].allSatisfy({ list in
            list.count <= 8 && list.allSatisfy { hasText($0, limit: 600) }
        }), plan.materials.count <= 8, plan.materials.allSatisfy({
            ORIGINS.contains($0.origin) && hasText($0.title, limit: 300)
        }), [plan.reason, plan.observe, plan.check, plan.review].allSatisfy({ $0.utf16.count <= 1_200 }),
            plan.coachNotes.utf16.count <= 4_000, plan.need.utf16.count <= 600 else {
            throw NivoLifeError.invalidField("plan_content")
        }
    }

    private static func validateBasis(_ plan: NivoCoachLessonPlan, state: NivoCoachState) throws {
        guard plan.basis.count <= 6 else { throw NivoLifeError.invalidField("plan_basis_count") }
        for basis in plan.basis {
            guard let lesson = state.sessions.first(where: { $0.id == basis.sessionId && $0.course.id == plan.courseId }),
                  let turn = lesson.turns.first(where: { $0.id == basis.turnId && $0.role == "user" && !$0.sourceInvalidated }),
                  !basis.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  turn.text.contains(basis.quote) else { throw NivoLifeError.invalidField("plan_basis_quote") }
        }
    }

    private static func hasText(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= limit
    }

    static func parse(_ text: String, base: NivoCoachLessonPlan) throws -> NivoCoachLessonPlan {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw NivoLifeError.invalidField("plan_not_json")
        }
        let data = Data(text[start...end].utf8)
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NivoLifeError.invalidField("plan_not_json")
        }
        func string(_ name: String) -> String { (fields[name] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func strings(_ name: String) -> [String] {
            (fields[name] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var plan = base
        plan.task = string("task")
        plan.reason = string("reason")
        plan.observe = string("observe")
        plan.concepts = strings("concepts")
        plan.hints = strings("hints")
        plan.branches = strings("branches")
        plan.check = string("check")
        plan.criteriaIds = strings("criteriaIds")
        plan.review = string("review")
        plan.coachNotes = string("coachNotes")
        plan.materials = (fields["materials"] as? [[String: String]] ?? []).compactMap { item in
            guard let title = item["title"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let origin = item["origin"] ?? ""
            return NivoCoachPlanMaterial(title: title.prefix(whileUTF16Fits: 300),
                origin: ORIGINS.contains(origin) ? origin : "unverified")
        }
        plan.basis = (fields["basis"] as? [[String: String]] ?? []).map { item in
            NivoCoachPlanBasis(sessionId: item["sessionId"] ?? "", turnId: item["turnId"] ?? "", quote: item["quote"] ?? "")
        }
        plan.source = "prep_agent"
        return plan
    }
}

private extension String {
    /// 截断时保留完整字符，同时与Android按UTF-16执行的长度边界一致。
    func prefix(whileUTF16Fits limit: Int) -> String {
        var count = 0
        return String(prefix { character in
            count += String(character).utf16.count
            return count <= limit
        })
    }
}
