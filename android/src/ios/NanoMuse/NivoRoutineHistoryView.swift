import SwiftUI

/// 定时任务的实时运行记录，展开可看完整结果，再进入该次运行对应的对话。
struct NivoRoutineHistoryView: View {
    let routineID: String
    @ObservedObject private var scheduler = NanoMuseScheduler.shared
    @Environment(\.dismiss) private var dismiss
    @State private var expanded = Set<String>()

    var body: some View {
        NavigationStack {
            List {
                if let routine = scheduler.routine(id: routineID) {
                    Section {
                        Text(routine.label).font(.headline)
                        Text(routine.cadence).foregroundStyle(.secondary)
                        if let pending = routine.pendingRun {
                            Label(AppLocalized("Queued"), systemImage: "clock")
                            Text(pending.queuedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        }
                    }
                    if routine.runs.isEmpty { Text(AppLocalized("No run records yet")) }
                    ForEach(Array(routine.runs.enumerated()), id: \.offset) { index, run in
                        record(run, key: run.id ?? "legacy-\(index)")
                    }
                } else { Text(AppLocalized("This item no longer exists. Reload the list.")) }
            }
            .navigationTitle(AppLocalized("Run records"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { dismiss() } } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in dismiss() }
    }

    private func record(_ run: NanoMuseRoutine.Run, key: String) -> some View {
        Section {
            HStack {
                Image(systemName: run.verifiedOutcome == "unknown" ? "questionmark.circle" : (run.ok ? "checkmark.circle" : "clock.badge.exclamationmark"))
                    .foregroundStyle(run.ok && run.verifiedOutcome != "unknown" ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.at.formatted(date: .abbreviated, time: .shortened))
                    Text(status(run)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let duration = run.duration {
                    Text(NanoMuseTurnTimes.format(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let note = run.note, !note.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            if let error = run.deliveryError {
                Label(AppLocalized("The result could not be saved to the conversation. The run will not be repeated."), systemImage: "exclamationmark.bubble")
                    .font(.callout).foregroundStyle(.secondary)
                Text(error).font(.caption).textSelection(.enabled)
            }
            if let exitCode = run.exitCode { LabeledContent(AppLocalized("Exit code"), value: String(exitCode)) }
            if run.isDebug == true { Text(AppLocalized("Debug run")).font(.caption).foregroundStyle(.secondary) }
            if let result = run.result, !result.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { expanded.contains(key) },
                    set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } }
                )) { Text(result).textSelection(.enabled) } label: { Text(AppLocalized("Result")) }
            }
            if run.resultTruncated == true {
                Text(AppLocalized(run.exitCode == nil ? "This is a saved preview. Open the conversation for the full result." : "The script output exceeded the saved preview limit."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let stdout = run.stdoutPreview, !stdout.isEmpty, stdout != run.result {
                DisclosureGroup(AppLocalized("Saved script output")) {
                    Text(stdout).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
            if let sessionID = run.sessionId, NanoMuseAccountData.shared.shows(sessionID) {
                Button {
                    dismiss()
                    NotificationCenter.default.post(name: .nanoMuseOpenChat, object: sessionID)
                } label: { Label(AppLocalized("Open conversation"), systemImage: "bubble.left") }
            }
        }
    }

    private func status(_ run: NanoMuseRoutine.Run) -> String {
        if run.verifiedOutcome == "unknown" { return AppLocalized("Outcome not verified") }
        switch run.status {
        case "running": return AppLocalized(scheduler.running.contains(routineID) ? "Running" : "Interrupted")
        case "interrupted": return AppLocalized("Interrupted")
        default: return AppLocalized(run.ok ? "Completed" : "Failed")
        }
    }
}
