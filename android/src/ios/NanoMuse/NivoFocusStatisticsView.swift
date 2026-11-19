import SwiftUI

/// 只汇总已结束的真实区间，休息、暂停间隔和删除记录不进入专注统计。
struct NivoFocusStatisticsView: View {
    @ObservedObject var model: NivoLifeModel
    var isCompact = false
    @State private var period = "Day"
    @State private var date = Date()
    @State private var shareBy = NivoFocusShareBy.group
    private let colors: [Color] = [
        Color(red: 0.47, green: 0.61, blue: 0.53), Color(red: 0.51, green: 0.60, blue: 0.67),
        Color(red: 0.70, green: 0.60, blue: 0.47), Color(red: 0.61, green: 0.54, blue: 0.65),
        Color(red: 0.55, green: 0.60, blue: 0.60)
    ]

    private var interval: DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = Calendar.current.firstWeekday
        let component: Calendar.Component = ["Day": .day, "Week": .weekOfYear, "Month": .month, "Year": .year][period] ?? .day
        let selectedDate = isCompact ? Date() : date
        return calendar.dateInterval(of: component, for: selectedDate)
            ?? DateInterval(start: calendar.startOfDay(for: selectedDate), duration: 86_400)
    }

    private var distribution: NivoFocusDistribution {
        NivoFocusStatistics.distribution(sessions: model.focusSessions, spans: model.focusSpans,
            startMs: Int64(interval.start.timeIntervalSince1970 * 1_000),
            endMs: Int64(interval.end.timeIntervalSince1970 * 1_000), tasks: model.tasks, by: shareBy)
    }

    var body: some View {
        let summary = distribution
        VStack(alignment: .leading, spacing: 16) {
            if isCompact { Text(AppLocalized("Today")).font(.headline) }
            else {
                Picker(AppLocalized("Period"), selection: $period) {
                    ForEach(["Day", "Week", "Month", "Year"], id: \.self) { Text(AppLocalized(String.LocalizationValue(stringLiteral: $0))).tag($0) }
                }.pickerStyle(.segmented)
                DatePicker(AppLocalized("Date"), selection: $date, displayedComponents: .date)
            }
            Text(NivoFocusFormat.clock(summary.totalMs)).font(.largeTitle.weight(.semibold)).monospacedDigit()
            Text(AppLocalized("Finished focus time")).font(.subheadline).foregroundStyle(.secondary)
            if !isCompact {
                LabeledContent(AppLocalized("Sessions"), value: summary.sessionCount.formatted())
                Picker(AppLocalized("Statistics"), selection: $shareBy) {
                    Text(AppLocalized("Groups")).tag(NivoFocusShareBy.group)
                    Text(AppLocalized("Tags")).tag(NivoFocusShareBy.tag)
                }.pickerStyle(.segmented)
                if summary.groups.isEmpty {
                    Text(AppLocalized("No focus records yet")).foregroundStyle(.secondary)
                } else {
                    chart(summary)
                    ForEach(Array(summary.groups.enumerated()), id: \.element.id) { index, group in
                        groupRow(group, total: summary.totalMs, color: colors[index % colors.count])
                    }
                }
                Text(AppLocalized("Breaks and unfinished sessions are excluded. Time across midnight is split by day."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 22))
    }

    private func chart(_ summary: NivoFocusDistribution) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(0, min(size.width, size.height) / 2 - 18)
            var angle = -90.0
            for (index, group) in summary.groups.enumerated() {
                let next = angle + Double(group.durationMs) / Double(summary.totalMs) * 360
                var path = Path()
                path.addArc(center: center, radius: radius, startAngle: .degrees(angle), endAngle: .degrees(next), clockwise: false)
                context.stroke(path, with: .color(colors[index % colors.count]), lineWidth: 24)
                angle = next
            }
        }
        .frame(height: 190)
        // 图例提供完整文本，VoiceOver无需重复朗读不含交互的装饰图形。
        .accessibilityHidden(true)
    }

    private func groupRow(_ group: NivoFocusGroupTotal, total: Int64, color: Color) -> some View {
        let fraction = Double(group.durationMs) / Double(max(1, total))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
                Text(group.group.isEmpty ? (shareBy == .tag ? AppLocalized("Untagged") : AppLocalized("Ungrouped")) : group.group)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(NivoFocusFormat.clock(group.durationMs)).monospacedDigit()
                    Text(fraction.formatted(.percent.precision(.fractionLength(1))))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.font(.subheadline)
            ProgressView(value: fraction).tint(color).accessibilityHidden(true)
        }.accessibilityElement(children: .combine)
    }
}
