//
//  NanoMuseBackgroundSettings.swift
//  nanoMuse
//
//  Two settings pages Android has and the shell was missing:
//  "Background & notifications" (what the phone lets the agent do while the
//  app is away, with the way to the system switches) and "Hands" (what Hands
//  are, and why the switch is not on iPhone). Android: ui/settings/
//  BackgroundScreen.kt and HandsScreen.kt.
//

import SwiftUI
import UIKit
import UserNotifications

// MARK: - Background & notifications

/// 展示本机通知与后台刷新权限，不提供已移除的远程设备入口。
struct NanoMuseBackgroundView: View {
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var refresh: UIBackgroundRefreshStatus = .available
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NanoMusePage(title: AppLocalized("Background & notifications")) {
            notificationsCard
            backgroundCard
            NanoMuseCaption(text: AppLocalized("iOS pauses apps that are not on screen. With Background App Refresh on, iOS can wake the app for a moment around a routine's due time to post the reminder; the routine itself still waits for you to open the app."))
        }
        .task { await read() }
        .nmOnChange(of: scenePhase) { phase in
            // Back from the system Settings: the switches may have moved.
            if phase == .active { Task { @MainActor in await read() } }
        }
    }

    // MARK: Notifications

    private var notificationsCard: some View {
        NanoMuseCard {
            switch notifications {
            case .authorized, .provisional, .ephemeral:
                NanoMuseRowLabel(title: AppLocalized("Notifications"), value: AppLocalized("Allowed"), chevron: false)
            case .notDetermined:
                NanoMuseActionRow(title: AppLocalized("Notifications"), value: AppLocalized("Not asked yet")) {
                    requestNotifications()
                }
            case .denied:
                NanoMuseActionRow(title: AppLocalized("Notifications"), value: AppLocalized("Off")) {
                    openSystemSettings()
                }
            @unknown default:
                NanoMuseRowLabel(title: AppLocalized("Notifications"), value: "…", chevron: false)
            }
            if notifications == .denied {
                NanoMuseRowDivider()
                NanoMuseActionRow(title: AppLocalized("Open Settings"), titleColor: NanoMuseTones.action, chevron: false) {
                    openSystemSettings()
                }
            }
        }
    }

    // MARK: Background refresh

    private var backgroundCard: some View {
        NanoMuseCard {
            switch refresh {
            case .available:
                NanoMuseRowLabel(title: AppLocalized("Background App Refresh"), value: AppLocalized("On"), chevron: false)
            case .denied:
                NanoMuseActionRow(title: AppLocalized("Background App Refresh"), value: AppLocalized("Off")) {
                    openSystemSettings()
                }
            case .restricted:
                NanoMuseRowLabel(title: AppLocalized("Background App Refresh"), value: AppLocalized("Restricted"), chevron: false)
            @unknown default:
                NanoMuseRowLabel(title: AppLocalized("Background App Refresh"), value: "…", chevron: false)
            }
            if refresh == .denied {
                NanoMuseRowDivider()
                NanoMuseActionRow(title: AppLocalized("Open Settings"), titleColor: NanoMuseTones.action, chevron: false) {
                    openSystemSettings()
                }
            }
        }
    }

    // MARK: State

    @MainActor
    private func read() async {
        refresh = UIApplication.shared.backgroundRefreshStatus
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func requestNotifications() {
        Task { @MainActor in
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await read()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

// MARK: - Hands

/// 说明iOS内的操作范围，不把旧中继的远程能力当作本机功能。
struct NanoMuseHandsView: View {
    var body: some View {
        NanoMusePage(title: AppLocalized("Hands")) {
            NanoMuseCard {
                NanoMuseRowLabel(title: AppLocalized("On this iPhone"), value: AppLocalized("Not on iPhone"), chevron: false)
                NanoMuseRowDivider()
                paragraph(AppLocalized("iOS does not let one app operate another, so there is no switch here: the agent can only act inside nanoMuse. It can open pages in the in-app browser, keep its files and run its routines; other apps on this phone are out of its reach by design."))
            }
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
    }
}
