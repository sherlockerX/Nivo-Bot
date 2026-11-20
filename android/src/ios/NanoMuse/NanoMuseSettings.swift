//
//  NanoMuseSettings.swift
//  nanoMuse
//
//  Settings as Muse cards, in Android's order: the model, the agent, the
//  phone, the app, about. Reached from the drawer, the ••• menus and the
//  agent page; the classic layout's Settings sheet has it as its first row.
//  Also the "All routines" page. Android: ui/settings/SettingsScreen.kt.
//

import SwiftUI
import UIKit

// MARK: - Settings home

struct NanoMuseSettingsHomeView: View {
    /// Open the upstream Settings sheet (every OpenMinis page is there); nil when already inside it.
    var onAllSettings: (() -> Void)? = nil

    @ObservedObject private var store = ProviderConfigStore.shared

    // 个人构建只提供本机功能、用户自己的API和MCP；内置账号、中继与iCloud入口已移除。
    var body: some View {
        NanoMusePage(title: AppLocalized("Settings")) {
            modelCard
            agentCard
            phoneCard
            appCard
            aboutCard
            if let onAllSettings {
                NanoMuseCard {
                    NanoMuseActionRow(title: AppLocalized("All settings"), action: onAllSettings)
                }
                NanoMuseCaption(text: AppLocalized("Providers, model groups, skills, appearance and the rest of the OpenMinis settings."))
            }
        }
    }

    // MARK: Card 1 — the model

    /// The chat slot's line, `<provider> · <model>`, under the card's title.
    private var chatLine: String? {
        _ = store.modelGroups
        _ = store.instances
        return NanoMuseModelSlots.line(.chat)
    }

    private var modelCard: some View {
        NanoMuseCard {
            NavigationLink {
                NanoMuseModelsView()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLocalized("Models"))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(chatLine ?? AppLocalized("Add a provider and pick its models"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Text(AppLocalized("Change"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NanoMuseTones.action)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            NanoMuseRowDivider()
            NanoMuseLinkRow(title: AppLocalized("Manage Providers")) { ProviderInstancesView() }
            // Android: Models, Manage providers, Token usage. Pictures and clips are two rows of the Models page.
            NanoMuseRowDivider()
            NanoMuseLinkRow(title: AppLocalized("Token Usage")) { UsageStatsView() }
        }
    }

    // MARK: Card 2 — the agent

    private var agentCard: some View {
        NanoMuseCard {
            Group {
                NanoMuseLinkRow(title: AppLocalized("Soul")) { SoulSettingsView() }
                NanoMuseRowDivider()
                // 设置页本身在sheet里，外层无法再弹出形象工作室，所以在设置的导航栈里直接进入。
                NanoMuseLinkRow(title: AppLocalized("Avatar")) { NanoMuseAvatarStudioView(embedded: true) }
                NanoMuseRowDivider()
                NanoMuseLinkRow(title: AppLocalized("Memory")) { MemoryManagementView() }
                NanoMuseRowDivider()
                NanoMuseLinkRow(title: AppLocalized("System files")) { NanoMuseSystemFilesView() }
                NanoMuseRowDivider()
                NanoMuseLinkRow(title: AppLocalized("Skills")) { SkillsManagementView() }
                NanoMuseRowDivider()
            }
            Group {
                NanoMuseLinkRow(title: AppLocalized("Connectors")) { NanoMuseConnectorsView() }
                NanoMuseRowDivider()
                // Android's Hands row; on iPhone the page explains why the switch is not here.
                NanoMuseLinkRow(title: AppLocalized("Hands"), value: AppLocalized("Not on iPhone")) { NanoMuseHandsView() }
                NanoMuseRowDivider()
                NanoMuseLinkRow(title: AppLocalized("Environment Variables")) { EnvironmentVariablesView() }
            }
        }
    }

    // MARK: Card 3 — the phone

    private var phoneCard: some View {
        NanoMuseCard {
            Group {
                NanoMuseLinkRow(title: AppLocalized("Permissions")) { OffloadPermissionSettingsView() }
                NanoMuseRowDivider()
                // Android: "Background & notifications" — what the phone lets the agent do while the app is away.
                NanoMuseLinkRow(title: AppLocalized("Background & notifications")) { NanoMuseBackgroundView() }
                NanoMuseRowDivider()
                NanoMuseLinkRow(title: AppLocalized("Storage")) { StorageManagementView() }
                NanoMuseRowDivider()
                NanoMuseLinkRow(title: AppLocalized("Shared Folders")) { SharedFoldersSettingsView() }
            }
            Group {
                NanoMuseRowDivider()
                NanoMuseLinkRow(title: AppLocalized("Mount External Folders")) { MountedFoldersSettingsView() }
                // 内置iCloud已移除，本地备份和用户文件夹继续保留。
                NanoMuseRowDivider()
                NanoMuseLinkRow(title: AppLocalized("Backup & Restore")) { BackupAndRestoreView() }
            }
        }
    }

    // MARK: Card 4 — the app

    private var appCard: some View {
        NanoMuseCard {
            NanoMuseLinkRow(title: AppLocalized("Appearance")) { NanoMuseAppearanceView() }
            NanoMuseRowDivider()
            NanoMuseLinkRow(title: AppLocalized("Network")) { NanoMuseNetworkView() }
            NanoMuseRowDivider()
            NanoMuseLinkRow(title: AppLocalized("Logs")) { LogManagementView() }
        }
    }

    // MARK: Card 5 — about

    private var aboutCard: some View {
        NanoMuseCard {
            NanoMuseLinkRow(title: AppLocalized("About Nivo Bot")) { AboutView() }
        }
    }
}

// MARK: - Links

/// The project's public pages.
enum NanoMuseLinks {
    /// The policy on the site (docs/privacy.md is its source), as Android's PRIVACY_URL.
    static let privacy = NivoProduct.privacy
    /// The own-key guide on the site (docs/own-key.md), when the relay sent no address of its own (Android's OWN_KEY_DOCS).
    static let ownKeyDocs = NivoProduct.modelGuide.absoluteString


}

extension NanoMuseFirstRun {
    /// 清除首次使用引导状态，保留已配置的提供商。
    static func reset() {
        for key in ["nanomuse.setup.done", "nanomuse.setup.source_chosen", NanoMuseFirstRun.notificationsKey] { UserDefaults.standard.removeObject(forKey: key) }
    }
}

// MARK: - All routines

/// Every routine on this phone, the goal check-ins and the feed's included: on/off, edit, run now.
struct NanoMuseRoutinesView: View {
    @ObservedObject private var scheduler = NanoMuseScheduler.shared
    @ObservedObject private var goals = NanoMuseGoalStore.shared
    @State private var editing: NanoMuseRoutine?
    @State private var history: NanoMuseRoutine?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                Text(AppLocalized("A routine is a message the agent sends itself at a set time, in its own conversation. On the iPhone it runs only while the app is open: when it comes due while the app is asleep, the phone shows a reminder, and the run happens as soon as you open the app. Nothing runs in the background."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if scheduler.routines.isEmpty {
                Section {
                    Text(AppLocalized("Nothing scheduled yet."))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section(AppLocalized("Routines")) {
                    ForEach(scheduler.routines) { routine in
                        routineRow(routine)
                    }
                }
            }
            Section {
                Button {
                    editing = NanoMuseRoutine(label: "", prompt: "", hour: 9, minute: 0)
                } label: {
                    Label(AppLocalized("New routine"), systemImage: "plus")
                }
                Button {
                    scheduler.requestNotificationPermission()
                } label: {
                    Label(AppLocalized("Allow reminders"), systemImage: "bell")
                }
                NavigationLink { NivoRoutineQuietHoursView() } label: {
                    Label(AppLocalized("Quiet hours"), systemImage: "moon")
                }
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Label(AppLocalized("Background App Refresh in iOS Settings"), systemImage: "arrow.clockwise")
                }
            } footer: {
                Text(AppLocalized("Reminders need notification permission. With Background App Refresh on, iOS can wake the app for a moment around the due time to post the reminder; the routine itself still waits for you to open the app."))
            }
        }
        .navigationTitle(AppLocalized("Scheduled tasks"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { routine in
            NanoMuseRoutineEditor(routine: routine)
        }
        .sheet(item: $history) { routine in NivoRoutineHistoryView(routineID: routine.id) }
        .alert(AppLocalized("Could not save"), isPresented: Binding(
            get: { scheduler.persistenceError != nil }, set: { if !$0 { scheduler.clearPersistenceError() } }
        )) {
            Button(AppLocalized("OK")) { scheduler.clearPersistenceError() }
        } message: { Text(scheduler.persistenceError ?? "") }
    }

    private func label(for routine: NanoMuseRoutine) -> String {
        if let goalId = routine.goalId, let goal = goals.goal(id: goalId) {
            return String(format: AppLocalized("Check-in: %@"), goal.title)
        }
        return routine.label.isEmpty ? AppLocalized("Routine") : routine.label
    }

    private func routineRow(_ routine: NanoMuseRoutine) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label(for: routine)).font(.body.weight(.medium))
                Text(routine.enabled ? routine.cadence : AppLocalized("Off")).font(.caption).foregroundStyle(.secondary)
                if let next = routine.nextDue(after: Date()), routine.enabled {
                    Text(String(format: AppLocalized("next %@"), NanoMuseDay.relative(next))).font(.caption2).foregroundStyle(.tertiary)
                }
                if routine.pendingRun != nil {
                    Text(AppLocalized("Queued")).font(.caption).foregroundStyle(NanoMuseTones.action)
                } else if let last = routine.runs.first, ["running", "interrupted"].contains(last.status ?? "") {
                    Text(AppLocalized(last.status == "running" ? "Running" : "Interrupted"))
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let last = routine.runs.first {
                    Text(String(format: last.ok ? AppLocalized("last run %@") : AppLocalized("last run %@, failed"), NanoMuseDay.relative(last.at)))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if scheduler.running.contains(routine.id) || routine.pendingRun != nil {
                ProgressView()
            } else {
                Toggle("", isOn: Binding(get: { routine.enabled }, set: { scheduler.setEnabled(routine.id, $0) }))
                    .labelsHidden()
                    .tint(NanoMuseTones.action)
                    .accessibilityLabel(Text(label(for: routine)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if scheduler.running.contains(routine.id) || routine.pendingRun != nil { history = routine }
            else { editing = routine }
        }
        .contextMenu {
            Button { history = routine } label: { Label(AppLocalized("Run records"), systemImage: "clock.arrow.circlepath") }
            Button { editing = routine } label: { Label(AppLocalized("Edit"), systemImage: "pencil") }
                .disabled(scheduler.running.contains(routine.id) || routine.pendingRun != nil)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { scheduler.delete(routine.id) } label: { Label(AppLocalized("Delete"), systemImage: "trash") }
            Button { Task { @MainActor in await scheduler.run(routine.id) } } label: { Label(AppLocalized("Run now"), systemImage: "play") }
                .tint(NanoMuseTones.action)
                .disabled(scheduler.running.contains(routine.id) || routine.pendingRun != nil)
        }
        .swipeActions(edge: .leading) {
            Button { history = routine } label: { Label(AppLocalized("Run records"), systemImage: "clock.arrow.circlepath") }
        }
    }
}
