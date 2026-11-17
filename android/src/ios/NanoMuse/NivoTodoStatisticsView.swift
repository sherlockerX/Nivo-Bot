import SwiftUI

/// 日周月年的完成标签分布，不将任务数量解释为投入时长。
struct NivoTodoStatisticsView: View {
    var tasks: [NivoTodoTask]
    @State private var period = NivoTodoPeriod.week
    @State private var date = Date()
    @State private var selectedTag: String?
    private let colors: [Color] = [.blue, .teal, .orange, .purple, .pink, .indigo, .green]

    private var slices: [NivoTodoTagSlice] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = Calendar.current.firstWeekday
        let interval = calendar.dateInterval(of: period.component, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
        return NivoTodoStatistics.calculate(tasks, startDay: NivoLifeDay.value(interval.start),
                                            endDay: NivoLifeDay.value(interval.end))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker(AppLocalized("Period"), selection: $period) {
                ForEach(NivoTodoPeriod.allCases) { Text(AppLocalized(String.LocalizationValue(stringLiteral: $0.rawValue))).tag($0) }
            }.pickerStyle(.segmented)
            DatePicker(AppLocalized("Date"), selection: $date, displayedComponents: .date)
            if slices.isEmpty {
                Text(AppLocalized("No completed tasks in this period")).foregroundStyle(.secondary).padding(.vertical, 32)
            } else {
                ZStack {
                    Canvas { context, size in
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let radius = min(size.width, size.height) / 2 - 24
                        var angle = -90.0
                        for (index, slice) in slices.enumerated() {
                            let next = angle + slice.percentage * 3.6
                            var path = Path()
                            path.addArc(center: center, radius: radius, startAngle: .degrees(angle),
                                        endAngle: .degrees(next), clockwise: false)
                            context.stroke(path, with: .color(colors[index % colors.count]), lineWidth: 34)
                            angle = next
                        }
                    }
                    VStack {
                        Text("\(Set(slices.flatMap(\.taskIDs)).count)").font(.largeTitle.bold())
                        Text(AppLocalized("Completed")).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(height: 240).accessibilityElement(children: .combine)
                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    Button { selectedTag = selectedTag == slice.tag ? nil : slice.tag } label: {
                        HStack {
                            Circle().fill(colors[index % colors.count]).frame(width: 10, height: 10)
                            Text(slice.tag.isEmpty ? AppLocalized("Untagged") : slice.tag).foregroundStyle(.primary)
                            Spacer()
                            Text((slice.percentage / 100).formatted(.percent.precision(.fractionLength(1))))
                            Image(systemName: "chevron.down").font(.caption)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if selectedTag == slice.tag {
                        ForEach(tasks.filter { slice.taskIDs.contains($0.id) }) { task in
                            Text(task.title).font(.subheadline).padding(.leading, 22)
                        }
                    }
                }
                Text(AppLocalized("Each completed task counts once. Multiple tags share its weight."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}

/// 统计周期使用系统周起点和本地时区。
private enum NivoTodoPeriod: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month", year = "Year"
    var id: String { rawValue }
    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }
}
