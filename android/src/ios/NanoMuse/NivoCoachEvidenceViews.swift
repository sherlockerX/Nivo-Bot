import SwiftUI

/// 三类进度直接采用教学规则的结果，结束一节课本身不点亮任何证据。
struct NivoCoachProgressSection: View {
    let progress: NivoCoachTopicProgress

    var body: some View {
        Section(AppLocalized("Learning evidence")) {
            row(AppLocalized("Understanding evidence"), supported: progress.hasUnderstanding)
            row(AppLocalized("Application evidence"), supported: progress.hasApplication)
            row(AppLocalized("Delayed review"), supported: progress.hasDelayedReview)
        }
    }

    private func row(_ title: String, supported: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: supported ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(supported ? Color.accentColor : Color.primary)
            Text(supported ? AppLocalized("Evidence recorded") : AppLocalized("Still needs evidence"))
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

/// 每项标准列出原话和评价，缺证据、存在异议和来源失效分别可见。
struct NivoCoachEvidenceSection: View {
    let lesson: NivoCoachSession
    var onOpenChat: (String, String?) -> Void

    var body: some View {
        ForEach(lesson.course.units.first(where: { $0.id == lesson.unitID })?.criteria ?? [], id: \.id) { criterion in
            Section {
                let items = lesson.evidence.filter { $0.criterionID == criterion.id }
                if items.isEmpty { Text(AppLocalized("Still needs evidence")).foregroundStyle(.secondary) }
                ForEach(Array(items.enumerated()), id: \.offset) { _, evidence in evidenceRow(evidence) }
            } header: { Text(criterion.description).textCase(nil) }
        }
    }

    private func evidenceRow(_ evidence: NivoCoachEvidence) -> some View {
        let turn = lesson.turns.first { $0.id == evidence.turnID }
        let invalid = turn == nil || turn?.sourceInvalidated == true
        // 旧协议的原评价保留为历史记录；新版达标证据须通过当前领域校验。
        let disputed = evidence.disputed || invalid ||
            (lesson.teachingProtocol == "topic-v3" && (try? NivoCoachTeaching.validate(evidence, session: lesson)) == nil)
        return VStack(alignment: .leading, spacing: 8) {
            Label(disputed ? AppLocalized("Under review") : (evidence.met ? AppLocalized("Evidence recorded") : AppLocalized("Still needs evidence")),
                  systemImage: disputed ? "exclamationmark.circle" : (evidence.met ? "checkmark.circle" : "circle"))
                .font(.subheadline.weight(.medium))
            Text(evidence.quote).textSelection(.enabled)
            Text(evidence.reason).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            NivoCoachSourceLink(chatID: turn?.originChatSessionID ?? lesson.chatSessionID,
                                messageID: turn?.originMessageID ?? "", isInvalidated: invalid, onOpen: onOpenChat)
        }.padding(.vertical, 4)
    }
}

/// 摘要与其来源版本、更正和未解决假设一起保存，不能只展示一段脱离证据的结论。
struct NivoCoachLessonSummarySection: View {
    let lesson: NivoCoachSession
    var onOpenChat: (String, String?) -> Void

    var body: some View {
        if let summary = lesson.lessonSummary {
            Section(AppLocalized("Lesson summary")) {
                Text(String(format: AppLocalized("Course version: %1$@; source revision: %2$@"),
                            summary.courseVersion, String(summary.sourceRevision))).font(.caption).foregroundStyle(.secondary)
                if summary.sourceInvalidated {
                    Label(AppLocalized("This summary has invalid sources and cannot support current conclusions."),
                          systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                }
                if !summary.text.isEmpty { Text(summary.text).textSelection(.enabled) }
                sources(summary.sources, title: AppLocalized("Sources"), invalidated: summary.sourceInvalidated)
                sources(summary.corrections, title: AppLocalized("Corrections"), invalidated: summary.sourceInvalidated)
                sources(summary.unresolvedHypotheses, title: AppLocalized("Unresolved hypotheses"), invalidated: summary.sourceInvalidated)
            }
        } else if !lesson.summary.isEmpty {
            Section(AppLocalized("Lesson summary")) { Text(lesson.summary).textSelection(.enabled) }
        }
    }

    @ViewBuilder private func sources(_ sources: [NivoCoachSummarySource], title: String, invalidated: Bool) -> some View {
        if !sources.isEmpty {
            DisclosureGroup(title) {
                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                    let turn = lesson.turns.first { $0.id == source.turnID }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.quote).textSelection(.enabled)
                        NivoCoachSourceLink(chatID: turn?.originChatSessionID ?? lesson.chatSessionID, messageID: source.messageID,
                            isInvalidated: invalidated || turn == nil || turn?.sourceInvalidated == true || turn?.originMessageID != source.messageID,
                            onOpen: onOpenChat)
                    }.padding(.vertical, 4)
                }
            }
        }
    }
}

/// 对话记录区分普通讨论、独立验证及现实自述，提示信息只标在需要判断独立性的回合。
struct NivoCoachArchivedTurn: View {
    let turn: NivoCoachTurn
    let lesson: NivoCoachSession
    var onOpenChat: (String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(turn.role == "user" ? AppLocalized("You") : AppLocalized("Coach"),
                  systemImage: turn.role == "user" ? "person" : "sparkle").font(.subheadline.weight(.semibold))
            Text(purpose).font(.caption).foregroundStyle(.secondary)
            if !turn.dimension.isEmpty {
                Text(turn.dimension == "understanding" ? AppLocalized("Understanding evidence") : AppLocalized("Application evidence"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if turn.reviewKind == "delayed" { Text(AppLocalized("Delayed review")).font(.caption) }
            if lesson.teachingProtocol != "topic-v3" || turn.purpose == "attempt" {
                Text(turn.support == "none" ? AppLocalized("Without hints") : AppLocalized("With support"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(turn.text).textSelection(.enabled)
            if turn.context == "reported_real" {
                Text(AppLocalized("This is your report of a real event, not an external verification."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            NivoCoachSourceLink(chatID: turn.originChatSessionID ?? lesson.chatSessionID,
                                messageID: turn.originMessageID, isInvalidated: turn.sourceInvalidated, onOpen: onOpenChat)
        }.padding(.vertical, 6)
    }

    private var purpose: String {
        if turn.context == "reported_real" { return AppLocalized("Report what happened") }
        guard lesson.teachingProtocol == "topic-v3" else { return AppLocalized("Practice records") }
        return ["assessment", "attempt"].contains(turn.purpose) ? AppLocalized("Independent check") : AppLocalized("Discussion")
    }
}

/// 现实行动显示原计划和修订过程，自述不会显示为外部核验。
struct NivoCoachActionsSection: View {
    let actions: [NivoCoachAction]
    let chatID: String
    var onOpenChat: (String, String?) -> Void

    var body: some View {
        if !actions.isEmpty {
            Section(AppLocalized("Real-world actions")) {
                ForEach(actions) { action in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(NivoCoachDisplay.status(action.status)).font(.caption).foregroundStyle(.secondary)
                        Text(action.plan).textSelection(.enabled)
                        ForEach(Array(action.planHistory.enumerated()), id: \.offset) { _, text in
                            Text(text).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        ForEach(action.reports) { report in
                            Text(report.text).textSelection(.enabled)
                            NivoCoachSourceLink(chatID: report.originChatSessionID ?? chatID, messageID: report.originMessageID,
                                                isInvalidated: report.sourceInvalidated, onOpen: onOpenChat)
                        }
                        Text(AppLocalized("This is your report of a real event, not an external verification."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
        }
    }
}

/// 缺少或失效的原消息只保留摘录，有效来源交给账户绑定的消息导航。
struct NivoCoachSourceLink: View {
    let chatID: String
    let messageID: String
    var isInvalidated = false
    var onOpen: (String, String?) -> Void

    var body: some View {
        if isInvalidated {
            Label(AppLocalized("Source changed"), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
        } else if !chatID.isEmpty, !messageID.isEmpty {
            Button(AppLocalized("View original message")) { onOpen(chatID, messageID) }
                .font(.subheadline).frame(minHeight: 44)
        } else {
            Text(AppLocalized("Original message link unavailable. This saved excerpt is still available."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
