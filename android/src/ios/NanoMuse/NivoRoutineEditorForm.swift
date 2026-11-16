import SwiftUI

/// 与安卓一致的多时点、星期、日期窗口和对话方式，保留iOS原生表单交互。
struct NivoRoutineEditorForm: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var models = ProviderConfigStore.shared
    @State private var routine: NanoMuseRoutine
    @State private var schedule: NivoRoutineSchedule
    @State private var execution: NivoRoutineExecution
    @State private var notification: NivoRoutineNotificationOptions
    @State private var modelSelection = ""
    @State private var sessions: [ChatSession] = []
    @State private var messages: [RawMessage] = []
    @State private var failure: String?
    @State private var confirmRerun = false
    @State private var isSaving = false
    @State private var savingTask: Task<Void, Never>?
    @State private var scriptMode: Bool
    @State private var script: NivoRoutineScript
    private let isNew: Bool
    private let accountGeneration: UInt64

    /// 初次打开只生成表单草稿；按取消不会留下一条已启用的空任务。
    init(routine: NanoMuseRoutine) {
        _routine = State(initialValue: routine)
        _scriptMode = State(initialValue: routine.script != nil)
        _script = State(initialValue: routine.script ?? NivoRoutineScript(id: ""))
        var schedule = routine.schedule ?? NivoRoutineSchedule()
        schedule.times = NivoRoutineScheduleRules.normalizedTimes(routine)
        if schedule.intervalMinutes == nil, let hours = routine.intervalHours { schedule.intervalMinutes = hours * 60 }
        _schedule = State(initialValue: schedule)
        let execution = routine.execution ?? NivoRoutineExecution(target: routine.sessionId == nil ? .newSession : .append)
        _execution = State(initialValue: execution)
        _notification = State(initialValue: execution.notification ?? NivoRoutineNotificationOptions())
        if let kind = execution.modelKind, let id = execution.modelID { _modelSelection = State(initialValue: kind.rawValue + ":" + id) }
        isNew = NanoMuseScheduler.shared.routine(id: routine.id) == nil
        accountGeneration = NanoMuseAccountData.shared.generation
    }

    var body: some View {
        NavigationStack {
            Form {
                if let failure { Section { Text(failure).foregroundStyle(.red).textSelection(.enabled) } }
                Section {
                    TextField(AppLocalized("Name"), text: $routine.label)
                    Toggle(AppLocalized("On"), isOn: $routine.enabled)
                }
                timeSection
                dateSection
                targetSection
                if scriptMode { scriptSection } else { modelSection }
                notificationSection
                failureSection
                if !routine.runs.isEmpty {
                    Section { NavigationLink(AppLocalized("Run records")) { NivoRoutineHistoryView(routineID: routine.id) } }
                }
            }
            .disabled(isSaving)
            .tint(NanoMuseTones.action)
            .navigationTitle(AppLocalized(isNew ? "New routine" : "Edit routine"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { savingTask?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Save")) {
                        if execution.target == .rerun { confirmRerun = true } else { beginSave() }
                    }
                    .disabled(isSaving || (scriptMode ? script.id.isEmpty : (execution.target != .rerun && routine.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)))
                }
            }
            .task { await loadSessions() }
            .task(id: routine.sessionId) { await loadMessages() }
            .onDisappear { savingTask?.cancel() }
            .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in dismiss() }
            .confirmationDialog(AppLocalized("Rerunning replaces replies after the selected message."), isPresented: $confirmRerun, titleVisibility: .visible) {
                Button(AppLocalized("Save"), role: .destructive) { beginSave() }
                Button(AppLocalized("Cancel"), role: .cancel) { }
            }
        }
    }

    private var timeSection: some View {
        Section(AppLocalized("Schedule")) {
            Toggle(AppLocalized("Use an interval"), isOn: Binding(
                get: { schedule.intervalMinutes != nil },
                set: { schedule.intervalMinutes = $0 ? 60 : nil }
            ))
            if schedule.intervalMinutes != nil {
                Stepper(String(format: AppLocalized("Every %d minutes"), schedule.intervalMinutes ?? 60), value: Binding(
                    get: { schedule.intervalMinutes ?? 60 }, set: { schedule.intervalMinutes = $0 }
                ), in: 1...10_080)
            } else {
                ForEach(schedule.times.indices, id: \.self) { index in
                    HStack {
                        DatePicker(AppLocalized("Time"), selection: timeBinding(index), displayedComponents: .hourAndMinute)
                        if schedule.times.count > 1 {
                            Button(role: .destructive) { schedule.times.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel(AppLocalized("Remove time"))
                        }
                    }
                }
                if schedule.times.count < 24 {
                    Button(AppLocalized("Add time")) { schedule.times.append(NivoRoutineTime(hour: 18, minute: 0)) }
                }
                Picker(AppLocalized("Repeat"), selection: $routine.repeatMode) {
                    Text(AppLocalized("Every day")).tag(NanoMuseRoutine.Repeat.daily)
                    Text(AppLocalized("Weekdays")).tag(NanoMuseRoutine.Repeat.weekdays)
                    Text(AppLocalized("Once")).tag(NanoMuseRoutine.Repeat.once)
                    Text(AppLocalized("Custom days")).tag(NanoMuseRoutine.Repeat.custom)
                }
                if routine.repeatMode == .custom { weekdayPicker }
            }
        }
    }

    private var weekdayPicker: some View {
        ForEach(1...7, id: \.self) { day in
            Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: Binding(
                get: { schedule.customDays.contains(day) },
                set: { selected in
                    if selected { schedule.customDays = Array(Set(schedule.customDays + [day])).sorted() }
                    else { schedule.customDays.removeAll { $0 == day } }
                }
            ))
        }
    }

    private var dateSection: some View {
        Section(AppLocalized("Active dates")) {
            Toggle(AppLocalized("Start date"), isOn: Binding(get: { schedule.startDay != nil }, set: { schedule.startDay = $0 ? NivoLifeDay.value() : nil }))
            if schedule.startDay != nil { DatePicker(AppLocalized("Start date"), selection: dayBinding(start: true), displayedComponents: .date) }
            Toggle(AppLocalized("End date"), isOn: Binding(get: { schedule.endDay != nil }, set: { schedule.endDay = $0 ? NivoLifeDay.value() : nil }))
            if schedule.endDay != nil { DatePicker(AppLocalized("End date"), selection: dayBinding(start: false), displayedComponents: .date) }
        }
    }

    private var targetSection: some View {
        Section {
            Toggle(AppLocalized("Run a saved script"), isOn: $scriptMode)
                .nmOnChange(of: scriptMode) { enabled in
                    if enabled, execution.target == .rerun { execution.target = .newSession }
                }
            Picker(AppLocalized("Conversation"), selection: $execution.target) {
                Text(AppLocalized("Dedicated conversation for this task")).tag(NivoRoutineExecution.Target.newSession)
                Text(AppLocalized("Continue a conversation")).tag(NivoRoutineExecution.Target.append)
                if !scriptMode { Text(AppLocalized("Rerun from a message")).tag(NivoRoutineExecution.Target.rerun) }
            }
            if execution.target != .newSession {
                Picker(AppLocalized("Conversation"), selection: Binding(get: { routine.sessionId ?? "" }, set: { routine.sessionId = $0; execution.messageID = nil })) {
                    Text(AppLocalized("Select a conversation")).tag("")
                    ForEach(sessions) { session in Text(session.title ?? AppLocalized("Conversation")).tag(session.id) }
                }
            }
            if execution.target == .rerun {
                Picker(AppLocalized("Message"), selection: Binding(get: { execution.messageID ?? "" }, set: { execution.messageID = $0 })) {
                    Text(AppLocalized("Select a message")).tag("")
                    ForEach(messages, id: \.id) { message in Text(messagePreview(message)).tag(message.id) }
                }
                Text(AppLocalized("Rerunning replaces replies after the selected message.")).font(.footnote).foregroundStyle(.secondary)
            } else if !scriptMode { TextEditor(text: $routine.prompt).frame(minHeight: 110) }
        } header: { Text(AppLocalized("What to do")) } footer: {
            if scriptMode {
                Text(AppLocalized("Scripts run on this device while the app is open. The first run asks you to approve the saved content and arguments."))
            } else {
                Text(AppLocalized("Sent to the agent as a message at the set time, in its own conversation. On the iPhone the run happens when the app is open; at the set time you get a reminder to open it. Nothing runs while the app is asleep."))
            }
        }
    }

    private var scriptSection: some View {
        Section {
            TextField(AppLocalized("Script filename"), text: $script.id)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            ForEach(script.arguments.indices, id: \.self) { index in
                HStack {
                    TextField(AppLocalized("Arguments"), text: $script.arguments[index])
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(role: .destructive) { script.arguments.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .accessibilityLabel(AppLocalized("Remove"))
                }
            }
            if script.arguments.count < 16 {
                Button(AppLocalized("Add argument")) { script.arguments.append("") }
            }
            Toggle(AppLocalized("Require output"), isOn: $script.requireOutput)
            Toggle(AppLocalized("Save stdout in run records"), isOn: $script.logStdout)
            Toggle(AppLocalized("Debug run"), isOn: Binding(get: { routine.debug ?? false }, set: { routine.debug = $0 }))
            if !isNew {
                Button(AppLocalized("Reset script approval")) {
                    do { try NivoScheduledScriptApproval.shared.revoke(taskID: routine.id) }
                    catch { failure = error.localizedDescription }
                }
            }
        } header: { Text(AppLocalized("Script")) } footer: {
            Text(AppLocalized("Use a .sh or .py file in /var/minis/home/bin. Arguments are passed literally. Debug runs send no notification and do not count failures; new script tasks also skip creating a conversation."))
        }
    }

    private var modelSection: some View {
        Section(AppLocalized("Model")) {
            Picker(AppLocalized("Model"), selection: $modelSelection) {
                Text(AppLocalized("Use the conversation or app default")).tag("")
                ForEach(models.modelGroups.filter { group in
                    group.memberEntryIds.contains { id in models.entry(for: id).map { models.nmIsUsableChatEntry($0) } ?? false }
                }) { group in Text(group.name).tag("group:" + group.id) }
                ForEach(models.modelEntries.filter { models.nmIsUsableChatEntry($0) }) { entry in
                    Text(entry.model.displayName).tag("entry:" + entry.id)
                }
            }
        }
    }

    private var failureSection: some View {
        Section {
            Toggle(AppLocalized("Pause after repeated failures"), isOn: $execution.autoDisableOnFailure)
            if execution.autoDisableOnFailure {
                Stepper(String(format: AppLocalized("After %d failures"), execution.failureThreshold), value: $execution.failureThreshold, in: 2...100)
            }
        }
    }

    private var notificationSection: some View {
        Section(AppLocalized("Notifications")) {
            Picker(AppLocalized("Notification policy"), selection: $notification.policy) {
                Text(AppLocalized("Only when the result changes")).tag(NivoRoutineNotificationOptions.Policy.onChange)
                Text(AppLocalized("Always")).tag(NivoRoutineNotificationOptions.Policy.always)
                Text(AppLocalized("Only on failure")).tag(NivoRoutineNotificationOptions.Policy.onFailure)
                Text(AppLocalized("Never")).tag(NivoRoutineNotificationOptions.Policy.never)
            }
            TextField(AppLocalized("Notification title"), text: Binding(
                get: { notification.title ?? "" }, set: { notification.title = $0.isEmpty ? nil : $0 }
            ))
            Toggle(AppLocalized("Silent notifications"), isOn: $notification.isSilent)
        }
    }

    private func timeBinding(_ index: Int) -> Binding<Date> {
        Binding(get: {
            guard schedule.times.indices.contains(index) else { return Date() }
            let time = schedule.times[index]
            return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
        }, set: { value in
            guard schedule.times.indices.contains(index) else { return }
            let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
            schedule.times[index] = NivoRoutineTime(hour: parts.hour ?? 9, minute: parts.minute ?? 0)
        })
    }

    private func dayBinding(start: Bool) -> Binding<Date> {
        Binding(get: { NivoLifeDay.date((start ? schedule.startDay : schedule.endDay) ?? NivoLifeDay.value()) }, set: {
            if start { schedule.startDay = NivoLifeDay.value($0) } else { schedule.endDay = NivoLifeDay.value($0) }
        })
    }

    private func messagePreview(_ message: RawMessage) -> String {
        let text = message.parts.compactMap { part -> String? in if case .text(let text) = part { return text }; return nil }.joined(separator: " ")
        return String(text.prefix(100))
    }

    private func loadSessions() async {
        let rows = await ChatStore.shared.listSessions()
        guard accountGeneration == NanoMuseAccountData.shared.generation else { return }
        sessions = rows.filter { !$0.isRemote && NanoMuseAccountData.shared.shows($0.id) }
    }

    private func loadMessages() async {
        messages = []
        guard let id = routine.sessionId, !id.isEmpty, NanoMuseAccountData.shared.shows(id) else { return }
        let rows = await ChatStore.shared.loadMessages(sessionId: id)
        guard accountGeneration == NanoMuseAccountData.shared.generation, routine.sessionId == id else { return }
        messages = rows.filter(NivoChatBranchRules.isUserTurn)
    }

    private func beginSave() {
        guard !isSaving else { return }
        savingTask = Task { await save() }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try Task.checkCancellation()
            guard accountGeneration == NanoMuseAccountData.shared.generation else { throw NivoLifeError.accountChanged }
            var changed = routine
            schedule.times = Array(Set(schedule.times)).sorted()
            guard let first = schedule.times.first else { throw NivoLifeError.invalidField("times") }
            changed.hour = first.hour
            changed.minute = first.minute
            changed.intervalHours = nil
            changed.schedule = schedule
            let model = modelSelection.split(separator: ":", maxSplits: 1).map(String.init)
            execution.modelKind = model.count == 2 ? NivoRoutineExecution.ModelKind(rawValue: model[0]) : nil
            execution.modelID = model.count == 2 ? model[1] : nil
            execution.notification = notification
            if scriptMode {
                changed.script = script
                changed.prompt = ""
                execution.modelKind = nil
                execution.modelID = nil
            } else { changed.script = nil }
            changed.execution = execution
            if execution.target == .newSession { changed.sessionId = nil }
            if changed.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                changed.label = changed.script?.id ?? String(changed.prompt.prefix(40))
            }
            if changed.enabled { try await NivoRoutineTargetValidation.validate(changed, generation: accountGeneration) }
            guard accountGeneration == NanoMuseAccountData.shared.generation, !Task.isCancelled else { throw NivoLifeError.accountChanged }
            _ = try NanoMuseScheduler.shared.saveRoutine(changed, creating: isNew)
            NanoMuseScheduler.shared.requestNotificationPermission()
            dismiss()
        } catch is CancellationError { return }
        catch { if !Task.isCancelled { failure = NivoLifeModel.message(error) } }
    }
}
