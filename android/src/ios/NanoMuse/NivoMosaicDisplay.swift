import SwiftUI
import UIKit

/// 每日碎片所有日期、形状和心情展示共享的本地化映射。
enum NivoMosaicDisplay {
    static func scope(_ value: NivoMosaicScope) -> String {
        switch value {
        case .day: return AppLocalized("Day")
        case .week: return AppLocalized("Week")
        case .month: return AppLocalized("Month")
        case .quarter: return AppLocalized("Quarter")
        case .year: return AppLocalized("Year")
        }
    }

    static func title(scope: NivoMosaicScope, anchor: Date) -> String {
        let range = NivoMosaicCalendar.range(scope: scope, anchor: anchor)
        let start = NivoLifeDay.date(range.startDay)
        switch scope {
        case .day: return start.formatted(date: .abbreviated, time: .omitted)
        case .week: return String(format: AppLocalized("Week of %@"), start.formatted(date: .abbreviated, time: .omitted))
        case .month: return start.formatted(.dateTime.year().month(.wide))
        case .quarter:
            return String(format: AppLocalized("Q%d %d"), (Calendar.current.component(.month, from: anchor) - 1) / 3 + 1,
                          Calendar.current.component(.year, from: anchor))
        case .year: return start.formatted(.dateTime.year())
        }
    }

    static func mood(_ mood: NivoMosaicMood) -> String { ["😄", "🙂", "😐", "😕", "😣"][mood.rawValue - 1] }

    static func moodName(_ mood: NivoMosaicMood) -> String {
        switch mood {
        case .great: return AppLocalized("Great")
        case .good: return AppLocalized("Good")
        case .neutral: return AppLocalized("Neutral")
        case .low: return AppLocalized("Low")
        case .bad: return AppLocalized("Difficult")
        }
    }

    static func duration(_ ms: Int64) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = ms < 60_000 ? [.second] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: Double(ms) / 1_000) ?? "0"
    }

    static func shape(_ id: String) -> String {
        switch id {
        case "square": return AppLocalized("Square")
        case "circle": return AppLocalized("Circle")
        case "hexagon": return AppLocalized("Hexagon")
        case "triangle": return AppLocalized("Triangle")
        case "heart": return AppLocalized("Heart")
        case "blob1", "blob2", "blob3": return AppLocalized("Organic")
        default: return AppLocalized("Rounded")
        }
    }

    static func shapeSymbol(_ id: String) -> String {
        switch id {
        case "square": return "square"
        case "circle": return "circle"
        case "hexagon": return "hexagon"
        case "triangle": return "triangle"
        case "heart": return "heart"
        case "blob1", "blob2", "blob3": return "seal"
        default: return "app"
        }
    }

    static func form(_ value: NivoMosaicForm) -> String {
        switch value {
        case .heart: return AppLocalized("Heart")
        case .diamond: return AppLocalized("Diamond")
        case .flower: return AppLocalized("Flower")
        case .triangle: return AppLocalized("Triangle")
        case .ring: return AppLocalized("Ring")
        case .star: return AppLocalized("Star")
        case .jigsaw: return AppLocalized("Jigsaw")
        case .cross: return AppLocalized("Cross")
        }
    }
}

/// 原图从应用私有目录异步读取，裁切只调整可见视口。
struct NivoMosaicPhoto: View {
    let path: String
    var crop: NivoMosaicCrop
    let access: NivoLifeScope
    var thumbnail = true
    @State private var image: UIImage?
    @State private var hasFailed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                NanoMuseTones.canvas
                if let image {
                    let scale = max(geometry.size.width / max(1, image.size.width), geometry.size.height / max(1, image.size.height)) * crop.zoom
                    let width = image.size.width * scale
                    let height = image.size.height * scale
                    Image(uiImage: image).resizable().frame(width: width, height: height)
                        .position(x: geometry.size.width / 2 + (0.5 - crop.focusX) * max(0, width - geometry.size.width),
                                  y: geometry.size.height / 2 + (0.5 - crop.focusY) * max(0, height - geometry.size.height))
                } else if hasFailed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else { ProgressView() }
            }.clipped()
        }
        .accessibilityLabel(AppLocalized("Attached photo"))
        .task(id: access.ownerKey + ":" + String(access.generation) + ":" + path) {
            image = nil
            hasFailed = false
            do {
                let data = try await NivoMosaicMediaStore.shared.imageData(path: path, scope: access, thumbnail: thumbnail)
                guard !Task.isCancelled else { return }
                image = UIImage(data: data)
                hasFailed = image == nil
            } catch { if !Task.isCancelled { hasFailed = true } }
        }
    }
}

/// 一天的拼图和习惯空位；每条记录在下方列表也有可访问的完整入口。
struct NivoMosaicDayCanvas: View {
    let day: Int64
    let entries: [NivoMosaicEntry]
    let habits: [NivoMosaicHabit]
    let marks: [NivoMosaicHabitDay]
    let form: String?
    let access: NivoLifeScope
    let onEntry: (NivoMosaicEntry) -> Void
    let onHabit: (NivoMosaicHabit) -> Void
    let onEmpty: () -> Void
    private var unfilled: [NivoMosaicHabit] { habits.filter { habit in !entries.contains(where: { $0.habitID == habit.id }) } }

    var body: some View {
        let selected = form.flatMap(NivoMosaicForm.init(rawValue:)) ?? NivoMosaicForm.auto(day: day)
        let slots = selected.slots(count: entries.count + unfilled.count)
        let minX = slots.map(\.x).min() ?? 0
        let maxX = slots.map(\.x).max() ?? 0
        let minY = slots.map(\.y).min() ?? 0
        let maxY = slots.map(\.y).max() ?? 0
        GeometryReader { geometry in
            let side = min(65, min(geometry.size.width / (maxX - minX + 1.5), geometry.size.height / (maxY - minY + 1.5)))
            ZStack {
                ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                    tile(index: index).frame(width: side * 0.9, height: side * 0.9)
                        .position(x: geometry.size.width / 2 + (slot.x - (minX + maxX) / 2) * side,
                                  y: geometry.size.height / 2 + (slot.y - (minY + maxY) / 2) * side)
                }
            }
        }.frame(height: 280).padding(.vertical, 6)
    }

    @ViewBuilder
    private func tile(index: Int) -> some View {
        if index < entries.count {
            let entry = entries[index]
            Button { onEntry(entry) } label: {
                ZStack {
                    NanoMuseTones.action.opacity(0.14)
                    if let path = entry.mediaPath { NivoMosaicPhoto(path: path, crop: entry.crop ?? NivoMosaicCrop(), access: access) }
                    else {
                        VStack(spacing: 2) {
                            if let mood = entry.mood { Text(NivoMosaicDisplay.mood(mood)) }
                            Text(entry.text).font(.caption2).lineLimit(2).padding(.horizontal, 5)
                        }
                    }
                }.clipShape(NivoMosaicTileShape(kind: entry.shape ?? "rounded"))
            }.buttonStyle(.plain).accessibilityLabel(entry.text.isEmpty ? AppLocalized("Fragment") : entry.text)
        } else if index - entries.count < unfilled.count {
            let habit = unfilled[index - entries.count]
            let isDone = marks.contains { $0.habitID == habit.id && $0.day == day && $0.status == .done }
            Button { onHabit(habit) } label: {
                ZStack {
                    NanoMuseTones.action.opacity(isDone ? 0.20 : 0.06)
                    VStack(spacing: 3) {
                        Image(systemName: isDone ? "checkmark" : "repeat")
                        Text(habit.title).font(.caption2).lineLimit(1)
                    }.padding(5)
                }.clipShape(NivoMosaicTileShape(kind: habit.shape ?? "rounded"))
            }.buttonStyle(.plain).accessibilityLabel(habit.title)
        } else {
            Button(action: onEmpty) {
                NivoMosaicTileShape(kind: "rounded").stroke(NanoMuseTones.action.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .overlay { Image(systemName: "plus").font(.caption).foregroundStyle(.secondary) }
            }.buttonStyle(.plain).accessibilityLabel(AppLocalized("Add a fragment"))
                .disabled(day > NivoLifeDay.value())
        }
    }
}

/// 跨周月季年的日期汇总只读取已保存记录；草稿和习惯勾选不伪造日记天数。
struct NivoMosaicPeriodGrid: View {
    let range: NivoMosaicRange
    let snapshot: NivoMosaicState?
    let access: NivoLifeScope?
    let onDay: (Int64) -> Void

    var body: some View {
        let records = snapshot?.entries.filter { $0.deletedAt == nil && $0.day >= range.startDay && $0.day <= range.endDay } ?? []
        let grouped = Dictionary(grouping: records, by: \.day)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(String(format: AppLocalized("%d fragments"), records.count), systemImage: "square.grid.2x2")
                Spacer()
                Text(String(format: AppLocalized("%d days with records"), grouped.count)).foregroundStyle(.secondary)
            }.font(.subheadline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 10) {
                ForEach(Array(range.startDay...range.endDay), id: \.self) { day in
                    let rows = grouped[day] ?? []
                    let date = NivoLifeDay.date(day)
                    Button { onDay(day) } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10).fill(NanoMuseTones.action.opacity(rows.isEmpty ? 0.05 : 0.20))
                                if !rows.isEmpty { Image(systemName: "checkmark").font(.caption).foregroundStyle(NanoMuseTones.action) }
                                else if day <= NivoLifeDay.value() { Circle().stroke(.secondary.opacity(0.4), lineWidth: 1).frame(width: 9, height: 9) }
                            }.frame(height: 38)
                            Text(Calendar.current.component(.day, from: date) == 1 ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(.dateTime.day()))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }.buttonStyle(.plain)
                        .accessibilityLabel(date.formatted(date: .complete, time: .omitted) + ", " + String(format: AppLocalized("%d fragments"), rows.count))
                }
            }
        }.padding(14).background(NanoMuseTones.surface, in: RoundedRectangle(cornerRadius: 18))
    }
}
