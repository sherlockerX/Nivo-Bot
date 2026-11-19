import SwiftUI
import UserNotifications

/// 每个账户可安排一条本机提醒，到达后打开专注页面，由用户开始计时。
@MainActor
struct NivoFocusReminderView: View {
    @ObservedObject var model: NivoLifeModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let access: NivoLifeScope
    @State private var scheduledDate: Date?
    @State private var selectedDate = Date.now.addingTimeInterval(3_600)
    @State private var isBusy = true
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let scheduledDate {
                        Text(scheduledDate.formatted(date: .abbreviated, time: .shortened))
                            .accessibilityLabel(AppLocalized("Scheduled focus reminder") + " " +
                                                scheduledDate.formatted(date: .abbreviated, time: .shortened))
                        Button(AppLocalized("Cancel reminder"), role: .destructive) { cancel() }
                    }
                    DatePicker(AppLocalized("Remind me at"), selection: $selectedDate,
                               in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    Text(AppLocalized("The reminder opens Focus. Start the timer when you are ready."))
                }
                if let message { Text(message).foregroundStyle(.red) }
            }
            .disabled(isBusy)
            .navigationTitle(AppLocalized("Focus reminder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Close")) { dismiss() }.disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Save")) { Task { await schedule() } }.disabled(isBusy)
                }
            }
            .interactiveDismissDisabled(isBusy)
            .task { await load() }
            .nmOnChange(of: scenePhase) { phase in
                if phase == .active, !isBusy { Task { await load() } }
            }
            .nmOnChange(of: model.accessScope) { scope in
                if scope != access { dismiss() }
            }
        }
    }

    private var identifier: String {
        "nivo.focus.reminder." + NivoFocusPreferences.ownerHash(access.ownerKey)
    }

    private func load() async {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        defer { isBusy = false }
        guard !Task.isCancelled, model.accessScope == access else { return }
        let request = requests.first { $0.identifier == identifier }
        scheduledDate = (request?.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
        if let scheduledDate { selectedDate = scheduledDate }
    }

    private func schedule() async {
        guard !isBusy, model.accessScope == access else { return }
        isBusy = true
        defer { isBusy = false }
        message = nil
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await hasPermission(center)
            guard model.accessScope == access else { return }
            guard granted else {
                message = AppLocalized("Allow notifications for this app in iOS Settings to schedule a reminder.")
                return
            }
            let components = Calendar.current.dateComponents(
                [.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: selectedDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            guard let date = trigger.nextTriggerDate(), date > .now else {
                message = AppLocalized("Choose a future time for the reminder.")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = AppLocalized("Focus reminder")
            content.body = AppLocalized("Open Focus when you are ready to start.")
            content.sound = .default
            content.userInfo = ["nivoRoom": "focus"]
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            guard model.accessScope == access else {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                return
            }
            scheduledDate = date
        } catch {
            guard model.accessScope == access else { return }
            message = AppLocalized("Could not schedule the focus reminder.")
        }
    }

    private func hasPermission(_ center: UNUserNotificationCenter) async throws -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return try await center.requestAuthorization(options: [.alert, .sound])
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    private func cancel() {
        guard model.accessScope == access else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        scheduledDate = nil
        message = nil
    }
}
