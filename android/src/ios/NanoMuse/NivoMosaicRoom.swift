import SwiftUI

/// 每日碎片用同一份日记录展示日、周、月、季、年视图，子功能集中在右上角。
struct NivoMosaicRoom: View {
    var chrome: NanoMuseRoomChrome
    @ObservedObject private var life = NivoLifeModel.shared
    @ObservedObject private var navigation = NivoLifeNavigation.shared
    @StateObject private var model = NivoMosaicViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var scope: NivoMosaicScope = .day
    @State private var anchor = Date()
    @State private var editor: NivoMosaicDraft?
    @State private var editorScope: NivoLifeScope?
    @State private var pendingDraft: NivoMosaicDraft?
    @State private var panel: Panel?
    @State private var deleting: NivoMosaicEntry?
    @State private var reflectionDrain = NivoLifeRequestDrain()

    private enum Panel: String, Identifiable { case calendar, habits, drafts, bin, form; var id: String { rawValue } }
    private var range: NivoMosaicRange { NivoMosaicCalendar.range(scope: scope, anchor: anchor) }
    private var entries: [NivoMosaicEntry] {
        model.entries.filter { $0.day >= range.startDay && $0.day <= range.endDay }.sorted { ($0.day, $0.createdAt) > ($1.day, $1.createdAt) }
    }

    var body: some View {
        VStack(spacing: 0) {
            NanoMuseRoomHeader(chrome: chrome) {
                HStack(spacing: 8) {
                    NanoMuseRoundButton(symbol: "calendar", label: AppLocalized("Choose a date")) { panel = .calendar }
                    Menu {
                        Button { panel = .habits } label: { Label(AppLocalized("Habits"), systemImage: "repeat") }
                        Button { panel = .drafts } label: { Label(AppLocalized("Drafts"), systemImage: "square.and.pencil") }
                        Button { panel = .bin } label: { Label(AppLocalized("Recently deleted"), systemImage: "trash") }
                        if scope == .day {
                            Button { panel = .form } label: { Label(AppLocalized("Day shape"), systemImage: "square.grid.3x3") }
                        }
                    } label: { NanoMuseRoundDisc(symbol: "ellipsis") }
                        .accessibilityLabel(AppLocalized("Mosaic views"))
                    NanoMuseRoundButton(symbol: "plus", label: AppLocalized("New fragment")) { openNew() }
                        .disabled(!life.isReady || !life.isMosaicReady)
                }
            }
            Picker(AppLocalized("Time scale"), selection: $scope) {
                ForEach(NivoMosaicScope.allCases, id: \.self) { Text(NivoMosaicDisplay.scope($0)).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.vertical, 10)
            periodHeader
            if !life.isReady || model.snapshot == nil {
                if let error = model.loadError ?? life.errorMessage {
                    VStack(spacing: 16) {
                        Text(error).foregroundStyle(.secondary)
                        Button(AppLocalized("Retry")) { Task { await reload() } }.disabled(life.isBusy || model.isLoading)
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let error = model.loadError {
                            Text(error).foregroundStyle(.secondary)
                            Button(AppLocalized("Retry")) { Task { await reload() } }
                        }
                        if scope == .day { dayContents }
                        else {
                            NivoMosaicPeriodGrid(range: range, snapshot: model.snapshot, access: life.accessScope) { day in
                                anchor = NivoLifeDay.date(day)
                                scope = .day
                            }
                        }
                        ForEach(entries) { entry in entryCard(entry) }
                        if entries.isEmpty && scope != .day {
                            NanoMuseEmptyState(symbol: "calendar", title: AppLocalized("No fragments in this period"),
                                               message: AppLocalized("Saved fragments will appear here by date."))
                        }
                    }.padding(16)
                }.refreshable { await reload() }
            }
        }
        .background(NanoMuseTones.canvas.ignoresSafeArea())
        .task(id: life.accessScope) { await reload() }
        .nmOnChange(of: scenePhase) { if $0 == .active { Task { await reload() } } }
        .nmOnChange(of: navigation.mosaicTarget) { if $0 != nil { Task { await reload() } } }
        .nmOnChange(of: navigation.mosaicReflectionTarget) { if $0 != nil { Task { await reload() } } }
        .onReceive(NotificationCenter.default.publisher(for: .nivoMosaicStateChanged)) { _ in Task { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in
            editor = nil; editorScope = nil; pendingDraft = nil; panel = nil; deleting = nil
        }
        .nmOnChange(of: life.accessScope) { access in
            if access != editorScope { editor = nil; editorScope = nil; pendingDraft = nil; panel = nil; deleting = nil }
        }
        .sheet(item: $editor, onDismiss: { Task { await reload() } }) { draft in
            if let editorScope { NivoMosaicEditor(draft: draft, access: editorScope, model: model) }
        }
        .sheet(item: $panel, onDismiss: openAfterPanel) { selected in panelView(selected) }
        .confirmationDialog(AppLocalized("Move this fragment to recently deleted?"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            if let entry = deleting, let access = life.accessScope {
                Button(AppLocalized("Delete"), role: .destructive) { Task { _ = await model.changeEntry(entry, restore: false, scope: access) } }
            }
        }
        .alert(AppLocalized("Error"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(AppLocalized("Close")) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var periodHeader: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel(AppLocalized("Previous period"))
            Spacer()
            Button { panel = .calendar } label: {
                VStack(spacing: 2) {
                    Text(NivoMosaicDisplay.title(scope: scope, anchor: anchor)).font(.headline)
                    if Calendar.current.isDateInToday(anchor) { Text(AppLocalized("Today")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .accessibilityLabel(AppLocalized("Next period"))
        }.buttonStyle(.plain).padding(.horizontal, 12)
    }

    @ViewBuilder
    private var dayContents: some View {
        if let access = life.accessScope {
            let day = range.startDay
            let dayInfo = model.snapshot?.days.first { $0.day == day }
            NivoMosaicDayCanvas(day: day, entries: entries.sorted { $0.createdAt < $1.createdAt },
                habits: model.habits.filter { NivoMosaicRules.isPlanned($0, day: day) },
                marks: model.snapshot?.habitDays ?? [], form: dayInfo?.form, access: access,
                onEntry: open, onHabit: { openNew(habit: $0) }, onEmpty: { openNew() })
            let pending = model.drafts.filter { $0.day == day }
            if !pending.isEmpty {
                Button { panel = .drafts } label: {
                    Label(String(format: AppLocalized("%d saved drafts"), pending.count), systemImage: "square.and.pencil")
                        .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.bordered)
            }
            let planned = model.habits.filter { NivoMosaicRules.isPlanned($0, day: day) }
            ForEach(planned) { habit in habitRow(habit, day: day, access: access) }
            if entries.isEmpty {
                Text(AppLocalized("Write one thing that happened, what you noticed, or what you want to remember."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button { openNew() } label: {
                Label(AppLocalized("Add a fragment"), systemImage: "plus.circle").frame(maxWidth: .infinity).padding(.vertical, 10)
            }.buttonStyle(.borderedProminent).tint(NanoMuseTones.action).disabled(day > NivoLifeDay.value())
        }
    }

    private func habitRow(_ habit: NivoMosaicHabit, day: Int64, access: NivoLifeScope) -> some View {
        let mark = model.snapshot?.habitDays?.first { $0.habitID == habit.id && $0.day == day }
        return HStack(spacing: 12) {
            Button {
                Task { _ = await model.markHabit(habit, day: day, status: mark?.status == .done ? nil : .done, scope: access) }
            } label: { Image(systemName: mark?.status == .done ? "checkmark.circle.fill" : "circle").font(.title2).frame(width: 44, height: 44) }
                .accessibilityLabel(habit.title + ", " + AppLocalized("Done"))
            VStack(alignment: .leading, spacing: 3) {
                Text(habit.title).font(.subheadline.weight(.medium))
                if mark?.status == .skipped { Text(AppLocalized("Skipped")).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Menu {
                Button(AppLocalized("Add a fragment")) { openNew(habit: habit) }
                Button(AppLocalized("Skip today")) { Task { _ = await model.markHabit(habit, day: day, status: .skipped, scope: access) } }
                if mark != nil { Button(AppLocalized("Clear mark")) { Task { _ = await model.markHabit(habit, day: day, status: nil, scope: access) } } }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
        }
        .buttonStyle(.plain).padding(.horizontal, 10)
        .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 16))
        .disabled(model.isSaving || day > NivoLifeDay.value())
    }

    private func entryCard(_ entry: NivoMosaicEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let mood = entry.mood { Text(NivoMosaicDisplay.mood(mood)).accessibilityLabel(NivoMosaicDisplay.moodName(mood)) }
                Text(NivoLifeDay.date(entry.day).formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                if let habitTitle = entry.habitTitle { Text(habitTitle).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Menu {
                    Button(AppLocalized("Edit")) { open(entry) }
                    Button(AppLocalized("Set as day cover")) { setCover(entry) }
                    Button(AppLocalized("Delete"), role: .destructive) { deleting = entry }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 32) }
            }
            if let path = entry.mediaPath, let access = life.accessScope {
                NivoMosaicPhoto(path: path, crop: entry.crop ?? NivoMosaicCrop(), access: access)
                    .frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            if !entry.text.isEmpty { Text(entry.text).font(.body).textSelection(.enabled) }
            ForEach(entry.taskSnapshots ?? [], id: \.id) { task in
                Label(task.title, systemImage: task.status == .done ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entry.focusSnapshots ?? [], id: \.id) { focus in
                Label(focus.title + " · " + NivoMosaicDisplay.duration(focus.elapsedMs), systemImage: "timer")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func panelView(_ selected: Panel) -> some View {
        if let access = life.accessScope {
            switch selected {
            case .habits: NivoMosaicHabitsView(model: model, access: access)
            case .bin: NivoMosaicBinView(model: model, access: access)
            case .drafts:
                NavigationStack {
                    List {
                        ForEach(model.drafts) { draft in
                            Button {
                                panel = nil
                                editorScope = access
                                pendingDraft = draft
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(draft.text.isEmpty ? AppLocalized("New fragment") : draft.text).lineLimit(2)
                                    Text(NivoLifeDay.date(draft.day).formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if model.drafts.isEmpty { Text(AppLocalized("No saved drafts")).foregroundStyle(.secondary) }
                    }.navigationTitle(AppLocalized("Drafts"))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { panel = nil } } }
                }
            case .calendar:
                NavigationStack {
                    DatePicker(AppLocalized("Choose a date"), selection: $anchor, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical).padding()
                        .navigationTitle(AppLocalized("Choose a date"))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { panel = nil } } }
                }.presentationDetents([.medium, .large])
            case .form:
                NavigationStack {
                    List {
                        Button(AppLocalized("Automatic")) { setForm(nil, access: access) }
                        ForEach(NivoMosaicForm.allCases, id: \.self) { form in
                            Button(NivoMosaicDisplay.form(form)) { setForm(form.rawValue, access: access) }
                        }
                    }.navigationTitle(AppLocalized("Day shape"))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { panel = nil } } }
                }
            }
        }
    }

    private func openNew(habit: NivoMosaicHabit? = nil) {
        guard life.isMosaicReady, let access = life.accessScope else { return }
        let day = scope == .day ? range.startDay : NivoLifeDay.value()
        guard day <= NivoLifeDay.value() else { return }
        editorScope = access
        editor = NivoMosaicDraft(ownerKey: access.ownerKey, id: UUID().uuidString, day: day,
                                 text: "", mood: nil, updatedAt: NivoMosaicViewModel.now,
                                 habitID: habit?.id, shouldMarkHabitDone: habit != nil, shape: habit?.shape ?? "rounded")
    }

    private func open(_ entry: NivoMosaicEntry) {
        editorScope = life.accessScope
        editor = model.drafts.first { $0.entryID == entry.id } ?? NivoMosaicRules.draft(
            from: entry, now: NivoMosaicViewModel.now, habitDays: model.snapshot?.habitDays ?? [])
    }

    /// 等仓库加载成功后再消费详情跳转，失败重试仍保留目标。
    private func reload() async {
        if !life.isReady { await life.activate() }
        await model.load()
        await openRequestedReflection()
        openRequestedFragment()
    }

    /// 草稿由当前仓库重新校验，账户切换、备份恢复或迟到请求均不能打开旧内容。
    private func openRequestedReflection() async {
        await reflectionDrain.run(next: {
            guard editor == nil, panel == nil, model.snapshot != nil,
                  model.loadError == nil, life.accessScope != nil else { return nil }
            return navigation.mosaicReflectionTarget
        }, handle: presentReflection)
    }

    /// 旧读取结束后由消费器继续读取最新目标，旧失败不会覆盖新请求的提示。
    private func presentReflection(_ target: NivoLifeItemTarget) async {
        guard let access = life.accessScope else { return }
        guard target.scope == access else { navigation.handledReflection(target); return }
        do {
            let draft = try await model.openReflection(sessionID: target.id, scope: access)
            guard life.accessScope == access, navigation.mosaicReflectionTarget == target,
                  editor == nil, panel == nil else { return }
            editorScope = access
            anchor = NivoLifeDay.date(draft.day)
            scope = .day
            editor = draft
            navigation.handledReflection(target)
        } catch {
            if life.accessScope == access, navigation.mosaicReflectionTarget == target {
                model.errorMessage = NivoLifeModel.message(error)
            }
            navigation.handledReflection(target)
        }
    }

    private func openRequestedFragment() {
        guard let access = life.accessScope, model.snapshot != nil, model.loadError == nil,
              editor == nil, panel == nil, let target = navigation.takeMosaicTarget() else { return }
        guard target.scope == access, let entry = model.entries.first(where: { $0.id == target.id }) else {
            model.errorMessage = AppLocalized("This item no longer exists. Reload the list.")
            return
        }
        anchor = NivoLifeDay.date(entry.day)
        scope = .day
        open(entry)
    }

    /// 草稿列表退出后再呈现编辑器，避免同时切换两个sheet导致编辑器被丢弃。
    private func openAfterPanel() {
        if let pendingDraft, editorScope == life.accessScope {
            editor = pendingDraft
        }
        pendingDraft = nil
        openRequestedFragment()
        Task { await openRequestedReflection() }
    }

    private func shift(_ amount: Int) { anchor = NivoMosaicCalendar.shifted(scope: scope, anchor: anchor, amount: amount) }

    private func setCover(_ entry: NivoMosaicEntry) {
        guard let access = life.accessScope else { return }
        var info = model.snapshot?.days.first { $0.day == entry.day } ?? NivoMosaicDayInfo(day: entry.day, updatedAt: NivoMosaicViewModel.now)
        info.coverEntryID = entry.id
        Task { _ = await model.saveDay(info, scope: access) }
    }

    private func setForm(_ form: String?, access: NivoLifeScope) {
        var info = model.snapshot?.days.first { $0.day == range.startDay } ?? NivoMosaicDayInfo(day: range.startDay, updatedAt: NivoMosaicViewModel.now)
        info.form = form
        Task { if await model.saveDay(info, scope: access) { panel = nil } }
    }
}
