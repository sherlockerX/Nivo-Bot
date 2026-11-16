import SwiftUI

/// Android Coach v2 的课程地图和课次归档入口。旧版成长卡片仍保留在“历史训练”页。
struct NivoCoachV2Room: View {
    var chrome: NanoMuseRoomChrome
    var onOpenSession: (String) -> Void
    var onOpenLegacy: () -> Void
    var onCreateCourse: () -> Void
    var onManageDraft: (String) -> Void
    var onReviewCourse: (String) -> Void
    @ObservedObject private var life = NivoLifeModel.shared
    @ObservedObject private var coach = NivoCoachV2ViewModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var page = "map"
    @State private var selectedLesson: NivoCoachSheetTarget<NivoCoachSession>?
    @State private var selectedCourse: NivoCoachSheetTarget<NivoCoachCourse>?
    @State private var selectedDraft: NivoCoachSheetTarget<NivoCoachDraft>?
    @State private var showsCalendar = false
    @State private var calendarScope: NivoLifeScope?
    @State private var pendingCalendarLesson: NivoCoachSheetTarget<NivoCoachSession>?
    @State private var pendingNavigation: NivoCoachPageNavigation?
    @State private var pendingScope: NivoLifeScope?

    var body: some View {
        VStack(spacing: 0) {
            NanoMuseRoomHeader(chrome: chrome) {
                ViewThatFits(in: .horizontal) {
                  HStack(spacing: 8) {
                    NanoMuseRoundButton(symbol: "map", label: AppLocalized("Coach")) { page = "map" }
                    NanoMuseRoundButton(symbol: "clock", label: AppLocalized("Lesson archive")) { page = "archive" }
                    NanoMuseRoundButton(symbol: "checklist", label: AppLocalized("Real-world actions")) { page = "actions" }
                    NanoMuseRoundButton(symbol: "plus", label: AppLocalized("Build the course with AI"), action: onCreateCourse)
                    Menu {
                        additionalPages
                    } label: { NanoMuseRoundDisc(symbol: "ellipsis") }
                        .accessibilityLabel(AppLocalized("More"))
                  }
                  Menu {
                      Button(AppLocalized("Coach")) { page = "map" }
                      Button(AppLocalized("Lesson archive")) { page = "archive" }
                      Button(AppLocalized("Real-world actions")) { page = "actions" }
                      Button(AppLocalized("Build the course with AI"), action: onCreateCourse)
                      additionalPages
                  } label: { NanoMuseRoundDisc(symbol: "ellipsis") }
                      .accessibilityLabel(AppLocalized("More"))
                }
            }
            if !life.isReady || !coach.hasLoaded {
                if let error = life.isReady ? coach.loadError : life.errorMessage {
                    loadingFailure(error).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let error = coach.loadError { loadingFailure(error) }
                        if coach.isMutating {
                            HStack { ProgressView(); Text(AppLocalized("Opening practice")) }.font(.subheadline)
                        }
                        if page == "archive" {
                            sessionArchive
                            topicArchive
                        } else if page == "actions" {
                            actionArchive
                        } else if page == "courses" {
                            courseLibrary
                        } else if coach.state.tracks.isEmpty {
                            header
                            NanoMuseEmptyState(symbol: "map", title: AppLocalized("No Coach courses yet"), message: AppLocalized("Ask the main chat to explore a goal and build a course. The course stays a draft until you confirm it."))
                                .frame(minHeight: 220)
                        } else {
                            header
                            LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 280), spacing: 14)], alignment: .leading, spacing: 14) {
                                ForEach(coach.state.tracks) { track in courseCard(track) }
                            }
                        }
                    }.frame(maxWidth: 920).padding(16).padding(.bottom, 30)
                        .frame(maxWidth: .infinity)
                }.refreshable { await reload() }
            }
        }
        .background(ChatColors.background.ignoresSafeArea())
        .task(id: life.accessScope) { await reload() }
        .nmOnChange(of: scenePhase) { phase in if phase == .active { Task { await reload() } } }
        .onReceive(NotificationCenter.default.publisher(for: .nivoCoachStateChanged)) { _ in
            Task { await coach.reload(ownerKey: life.ownerKey) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nivoCoachSourcesChanged)
            .receive(on: RunLoop.main).debounce(for: .milliseconds(200), scheduler: RunLoop.main)) { _ in
            Task { await coach.reload(ownerKey: life.ownerKey) }
        }
        .nmOnChange(of: life.accessScope) { _ in
            selectedLesson = nil; selectedCourse = nil; selectedDraft = nil
            showsCalendar = false; calendarScope = nil
            pendingCalendarLesson = nil; pendingNavigation = nil; pendingScope = nil
        }
        .sheet(isPresented: $showsCalendar, onDismiss: {
            if let target = pendingCalendarLesson, life.accessScope == target.scope { selectedLesson = target }
            pendingCalendarLesson = nil
            calendarScope = nil
        }) {
            if let scope = calendarScope {
                NivoCoachCalendarView(sessions: coach.state.sessions) { lesson in
                    guard life.accessScope == scope else { return }
                    pendingCalendarLesson = NivoCoachSheetTarget(item: lesson, scope: scope)
                    showsCalendar = false
                }
            }
        }
        .sheet(item: $selectedDraft, onDismiss: finishNavigation) { target in
            NivoCoachDraftDetail(draft: target.item) {
                queue(.draft(target.item.id), scope: target.scope)
                selectedDraft = nil
            }
        }
        .sheet(item: $selectedLesson, onDismiss: finishNavigation) { target in
            NivoCoachLessonDetail(lessonID: target.item.id, state: coach.state, onOpenChat: { id, messageID in
                queue(.chat(id, messageID), scope: target.scope); selectedLesson = nil
            }, loadError: coach.loadError, onRetry: { Task { await reload() } })
        }
        .sheet(item: $selectedCourse, onDismiss: finishNavigation) { target in
            let track = coach.state.tracks.first { $0.id == target.item.id }
            NivoCoachCourseDetail(course: track?.course ?? target.item, demonstrated: track?.demonstrated ?? [], onStart: { unit in
                queue(.unit(course: target.item.id, unit: unit.id), scope: target.scope)
                selectedCourse = nil
            }, onReview: {
                queue(.review(target.item.id), scope: target.scope)
                selectedCourse = nil
            })
        }
        .alert(AppLocalized("Error"), isPresented: Binding(get: { coach.errorMessage != nil }, set: { if !$0 { coach.errorMessage = nil } })) {
            Button(AppLocalized("Close")) { coach.errorMessage = nil }
        } message: { Text(coach.errorMessage ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalized("Coach")).font(.largeTitle.weight(.bold))
            Text(AppLocalized("One ability at a time. Learn the mechanism, practise it, then verify it in a new situation."))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var additionalPages: some View {
        Button(AppLocalized("Training calendar")) {
            calendarScope = life.accessScope
            showsCalendar = calendarScope != nil
        }
        Button(AppLocalized("Courses")) { page = "courses" }
        Button(AppLocalized("Legacy training"), action: onOpenLegacy)
        Button(AppLocalized("Refresh")) { Task { await reload() } }
    }

    private func courseCard(_ track: NivoCoachTrack) -> some View {
        let displayedScope = life.accessScope
        return VStack(alignment: .leading, spacing: 10) {
            Button { selectedCourse = sheetTarget(track.course, scope: displayedScope) } label: { NivoCoachSceneArt(kind: track.course.kind) }
                .buttonStyle(.plain).accessibilityLabel(track.course.title)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Button { selectedCourse = sheetTarget(track.course, scope: displayedScope) } label: { Text(track.course.title).font(.headline) }.buttonStyle(.plain)
                    Text(track.course.place).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if track.paused { Label(AppLocalized("Paused"), systemImage: "pause.fill").font(.caption).foregroundStyle(.secondary) }
            }
            let position = (track.course.units.firstIndex { $0.id == track.currentUnitID } ?? 0) + 1
            Text(String(format: AppLocalized("Unit %@ of %d"), String(position), track.course.units.count)).font(.caption).foregroundStyle(.secondary)
            let completed = track.course.units.filter { track.demonstrated.contains($0.id) }.count
            ProgressView(value: Double(completed), total: Double(max(1, track.course.units.count)))
                .tint(NanoMuseTones.action)
                .accessibilityLabel(AppLocalized("Learning evidence"))
                .accessibilityValue(String(format: AppLocalized("%1$d of %2$d units demonstrated"), completed, track.course.units.count))
            Text(String(format: AppLocalized("%1$d of %2$d units demonstrated"), completed, track.course.units.count))
                .font(.caption).foregroundStyle(.secondary)
            if let unit = track.course.units.first(where: { $0.id == track.currentUnitID }) {
                Text(unit.title).font(.subheadline.weight(.medium))
                Text(unit.focus).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
            if track.course.needsCriteriaReview || track.course.units.contains(where: \.needsCriteriaReview) {
                Label(AppLocalized("Course criteria need review before training"), systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            ViewThatFits(in: .horizontal) {
                HStack { courseActions(track) }
                VStack(alignment: .leading) { courseActions(track) }
            }.disabled(coach.isMutating)
            if canAdvance(track) {
                Button(AppLocalized("Move to the next unit")) {
                    guard let scope = displayedScope, life.accessScope == scope else { return }
                    Task { await coach.advance(courseID: track.id, unitID: track.currentUnitID, scope: scope) }
                }.buttonStyle(.bordered).disabled(coach.isMutating)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// 只有当前单元已有证据且课程还有下一单元时才提供显式推进入口。
    private func canAdvance(_ track: NivoCoachTrack) -> Bool {
        guard !track.paused, !track.course.needsCriteriaReview,
              !track.course.units.contains(where: \.needsCriteriaReview),
              track.demonstrated.contains(track.currentUnitID),
              let index = track.course.units.firstIndex(where: { $0.id == track.currentUnitID }) else { return false }
        return index + 1 < track.course.units.count
    }

    @ViewBuilder
    private func courseActions(_ track: NivoCoachTrack) -> some View {
        let displayedScope = life.accessScope
        Button(track.paused ? AppLocalized("Resume") : AppLocalized("Pause")) {
            guard let scope = displayedScope, life.accessScope == scope else { return }
            Task {
                guard life.accessScope == scope else { return }
                await coach.pause(courseID: track.id, paused: !track.paused, scope: scope)
            }
        }.buttonStyle(.bordered)
        if track.course.needsCriteriaReview || track.course.units.contains(where: \.needsCriteriaReview) {
            Button(AppLocalized("Review requirements with AI")) {
                guard let scope = displayedScope, life.accessScope == scope else { return }
                onReviewCourse(track.id)
            }.buttonStyle(.borderedProminent)
        } else {
            Button(AppLocalized("Start unit")) {
                if let scope = displayedScope { startUnit(courseID: track.id, unitID: track.currentUnitID, scope: scope) }
            }.buttonStyle(.borderedProminent).disabled(track.paused)
        }
    }

    private func loadingFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.secondary)
            Button(AppLocalized("Retry")) { Task { await reload() } }
                .buttonStyle(.bordered).disabled(coach.isLoading || life.isBusy)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reload() async {
        if !life.isReady { await life.activate() }
        await coach.reload(ownerKey: life.ownerKey)
    }

    /// 点击时捕获账户代次，排队后的任务不能借用新账户的同名内置课程。
    private func startUnit(courseID: String, unitID: String, scope: NivoLifeScope) {
        guard life.accessScope == scope else { return }
        Task {
            guard life.accessScope == scope else { return }
            await coach.start(courseID: courseID, unitID: unitID, scope: scope, openChat: onOpenSession)
        }
    }

    /// 详情页退出之后才打开对话或开始新课，避免同时撤销内外两层弹窗。
    private func queue(_ action: NivoCoachPageNavigation, scope: NivoLifeScope) {
        guard life.accessScope == scope else { return }
        pendingScope = scope
        pendingNavigation = action
    }

    /// 只有已载入的本账户投影才可打开详情，冻结恢复时不新建选择。
    private func sheetTarget<Item: Identifiable>(_ item: Item, scope: NivoLifeScope?) -> NivoCoachSheetTarget<Item>? {
        guard coach.hasLoaded, let scope, life.accessScope == scope else { return nil }
        return NivoCoachSheetTarget(item: item, scope: scope)
    }

    private func finishNavigation() {
        defer { pendingNavigation = nil; pendingScope = nil }
        guard let action = pendingNavigation, let scope = pendingScope, life.accessScope == scope else { return }
        switch action {
        case .chat(let identifier, let messageID):
            if let messageID {
                NivoCoachSourceNavigation.shared.enqueue(chatID: identifier, messageID: messageID, scope: scope)
            }
            onOpenSession(identifier)
        case .draft(let identifier): onManageDraft(identifier)
        case .review(let identifier): onReviewCourse(identifier)
        case .unit(let course, let unit): startUnit(courseID: course, unitID: unit, scope: scope)
        }
    }

    private var sessionArchive: some View {
        let displayedScope = life.accessScope
        return LazyVStack(alignment: .leading, spacing: 8) {
            Text(AppLocalized("Lesson archive")).font(.headline)
            ForEach(Array(coach.state.sessions.reversed())) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 2) { Text(session.course.title).font(.subheadline.weight(.semibold)); Text(NivoCoachDisplay.status(session.status)).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button(AppLocalized("Open")) { selectedLesson = sheetTarget(session, scope: displayedScope) }.buttonStyle(.bordered)
                }.padding(12).background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var topicArchive: some View {
        let displayedScope = life.accessScope
        return LazyVStack(alignment: .leading, spacing: 8) {
            Text(AppLocalized("Continuing cases")).font(.headline)
            ForEach(coach.state.topics) { topic in
                Button {
                    guard let scope = displayedScope, life.accessScope == scope else { return }
                    if !topic.chatSessionID.isEmpty { onOpenSession(topic.chatSessionID) }
                } label: {
                    Label(topic.title, systemImage: topic.status == "active" ? "bubble.left.and.bubble.right" : "archivebox")
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }.buttonStyle(.plain).disabled(topic.chatSessionID.isEmpty)
            }
        }
    }

    private var actionArchive: some View {
        let displayedScope = life.accessScope
        return LazyVStack(alignment: .leading, spacing: 12) {
            Text(AppLocalized("Real-world actions")).font(.title2.weight(.bold))
            if coach.state.actions.isEmpty { Text(AppLocalized("No actions yet")).foregroundStyle(.secondary) }
            ForEach(coach.state.actions.reversed()) { action in
                VStack(alignment: .leading, spacing: 8) {
                    Text(action.plan).font(.body)
                    Text(NivoCoachDisplay.status(action.status)).font(.caption).foregroundStyle(.secondary)
                    if let lesson = coach.state.sessions.first(where: { $0.id == action.sessionID }) {
                        Button(AppLocalized("Open")) { selectedLesson = sheetTarget(lesson, scope: displayedScope) }.buttonStyle(.bordered)
                    }
                    ForEach(action.reports) { Text($0.text).font(.subheadline).textSelection(.enabled) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    private var courseLibrary: some View {
        let displayedScope = life.accessScope
        return LazyVStack(alignment: .leading, spacing: 12) {
            Text(AppLocalized("Courses")).font(.title2.weight(.bold))
            Button(AppLocalized("Build the course with AI"), action: onCreateCourse).buttonStyle(.borderedProminent)
            ForEach(coach.state.tracks) { track in
                Button { selectedCourse = sheetTarget(track.course, scope: displayedScope) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.course.title).font(.headline)
                            Text(track.course.place).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.padding(14).background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            }
            Text(AppLocalized("Course drafts")).font(.headline)
            ForEach(coach.state.drafts.filter { $0.activatedCourseID == nil }) { draft in
                Button { selectedDraft = sheetTarget(draft, scope: displayedScope) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(draft.course?.title ?? draft.text).lineLimit(3)
                        Text(draft.status == "proposed" ? AppLocalized("Awaiting your confirmation") : AppLocalized("Course draft"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            }
        }
    }
}

/// 弹层退出后的明确意图，账户凭证单独保留，不从新页面补取。
private enum NivoCoachPageNavigation {
    case chat(String, String?), draft(String), review(String), unit(course: String, unit: String)
}
