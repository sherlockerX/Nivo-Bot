import SwiftUI

/// 月网格显示任务标记；窄屏和大字号使用可滚动日期条，任务列表保持完整阅读宽度。
@MainActor
struct NivoTodoCalendarView<TaskRows: View>: View {
    var tasks: [NivoTodoTask]
    @Binding var selectedDate: Date
    @ViewBuilder var taskRows: ([NivoTodoTask]) -> TaskRows
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .body) private var agendaHeight = 86.0
    @State private var index: NivoTodoCalendarIndex?
    @State private var indexingID = UUID()

    private var calendar: Calendar {
        var calendar = NivoTodoCalendarMonth.calendar(.current)
        calendar.locale = locale
        return calendar
    }
    private var selectedDay: Int64 { NivoLifeDay.value(selectedDate) }
    private var month: NivoTodoCalendarMonth { NivoTodoCalendarMonth(selected: selectedDate, calendar: calendar) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 14) {
                header
                if typeSize >= .xxxLarge { agenda }
                else { ViewThatFits(in: .horizontal) { grid.frame(minWidth: 336); agenda } }
                Button(AppLocalized("Today")) { selectedDate = Date() }
                    .frame(minHeight: 44).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(14).background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 20))
            if let index {
                Text(selectedDate.formatted(date: .complete, time: .omitted)).font(.headline)
                let current = index.byDay[selectedDay] ?? []
                if current.isEmpty {
                    Text(AppLocalized("No planned or due tasks on this day.")).foregroundStyle(.secondary)
                } else { taskRows(current) }
                HStack {
                    Text(AppLocalized("No dates set")).font(.headline)
                    Spacer()
                    Text(index.undated.count.formatted()).foregroundStyle(.secondary)
                }
                taskRows(index.undated)
            } else { ProgressView().frame(maxWidth: .infinity).padding() }
        }
        .task { await rebuild(tasks) }
        .nmOnChange(of: tasks) { updated in Task { await rebuild(updated) } }
        .onDisappear { indexingID = UUID() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel(AppLocalized("Previous month"))
                .disabled(NivoTodoCalendarMonth.moving(selectedDate, months: -1, calendar: calendar) == nil)
            DatePicker(AppLocalized("Calendar"), selection: $selectedDate, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.compact).frame(maxWidth: .infinity)
                .environment(\.calendar, calendar)
            Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .accessibilityLabel(AppLocalized("Next month"))
                .disabled(NivoTodoCalendarMonth.moving(selectedDate, months: 1, calendar: calendar) == nil)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 44), spacing: 4), count: 7), spacing: 6) {
            ForEach(0..<7) { offset in
                Text(calendar.shortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + offset) % 7])
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            ForEach(0..<month.leadingEmptyCells, id: \.self) { _ in Color.clear.frame(height: 48).accessibilityHidden(true) }
            ForEach(month.days, id: \.self) { day in cell(day, isCompact: true) }
        }
    }

    private var agenda: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(month.days, id: \.self) { day in cell(day, isCompact: false).frame(minWidth: 76).id(day) }
                }
            }.frame(height: agendaHeight)
            .onAppear { proxy.scrollTo(selectedDay, anchor: .center) }
            .nmOnChange(of: selectedDay) { day in proxy.scrollTo(day, anchor: .center) }
        }
    }

    private func cell(_ day: Int64, isCompact: Bool) -> some View {
        let date = NivoLifeDay.date(day)
        let count = index?.byDay[day]?.count ?? 0
        let isSelected = day == selectedDay
        let isToday = day == NivoLifeDay.value()
        return Button { selectedDate = date } label: {
            VStack(spacing: 5) {
                if !isCompact { Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.caption) }
                Text(calendar.component(.day, from: date).formatted()).font(.body.weight(isSelected || isToday ? .semibold : .regular))
                Circle().fill(count > 0 ? (isSelected ? Color.white : Color.accentColor) : .clear).frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 48).padding(.horizontal, 4).padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(isToday && !isSelected ? Color.accentColor : .clear))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }.buttonStyle(.plain)
            .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
            .accessibilityValue(AppLocalized("Tasks") + ": " + count.formatted())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func moveMonth(_ offset: Int) {
        if let date = NivoTodoCalendarMonth.moving(selectedDate, months: offset, calendar: calendar) { selectedDate = date }
    }

    /// 索引在后台建立，旧筛选或旧账户的迟到结果不能覆盖新列表。
    @MainActor private func rebuild(_ snapshot: [NivoTodoTask]) async {
        let identifier = UUID()
        indexingID = identifier
        index = nil
        let result = await Task.detached(priority: .userInitiated) { NivoTodoCalendarIndex(tasks: snapshot) }.value
        guard indexingID == identifier, !Task.isCancelled else { return }
        index = result
    }
}
