import SwiftUI

/// 全局静音窗口跟随当前账户，取消编辑不会改变正在使用的设置。
struct NivoRoutineQuietHoursView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isEnabled: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var failure: String?
    private let generation: UInt64

    init() {
        generation = NanoMuseAccountData.shared.generation
        let value = NanoMuseScheduler.shared.notificationSettings.quietHours
        _isEnabled = State(initialValue: value != "off")
        let times = value.split(separator: "-").compactMap { NivoRoutineTime.parse(String($0)) }
        _start = State(initialValue: Self.date(times.first ?? NivoRoutineTime(hour: 1, minute: 0)))
        _end = State(initialValue: Self.date(times.last ?? NivoRoutineTime(hour: 8, minute: 0)))
    }

    var body: some View {
        Form {
            if let failure { Text(failure).foregroundStyle(.red) }
            Section {
                Toggle(AppLocalized("Quiet hours"), isOn: $isEnabled)
                if isEnabled {
                    DatePicker(AppLocalized("Start"), selection: $start, displayedComponents: .hourAndMinute)
                    DatePicker(AppLocalized("End"), selection: $end, displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text(AppLocalized("Reminders and results arrive without sound during quiet hours."))
            }
        }
        .navigationTitle(AppLocalized("Quiet hours"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(NanoMuseTones.action)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Save")) { save() } } }
        .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in dismiss() }
    }

    private func save() {
        do {
            guard generation == NanoMuseAccountData.shared.generation else { throw NivoLifeError.accountChanged }
            try NanoMuseScheduler.shared.setQuietHours(isEnabled ? Self.time(start) + "-" + Self.time(end) : "off")
            dismiss()
        } catch { failure = NivoLifeModel.message(error) }
    }

    private static func time(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return NivoRoutineTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0).text
    }

    private static func date(_ time: NivoRoutineTime) -> Date {
        Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
    }
}
