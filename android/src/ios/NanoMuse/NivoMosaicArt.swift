import SwiftUI

/// 与安卓MosaicForm相同的八种日布局，日期轮换和历史图案保持稳定。
enum NivoMosaicForm: String, CaseIterable, Codable, Sendable {
    case heart, diamond, flower, triangle, ring, star, jigsaw, cross

    /// 使用相同SplitMix64洗牌；负epoch day采用向下整除，不受平台余数规则影响。
    static func auto(day: Int64) -> NivoMosaicForm {
        let size: Int64 = 8
        let block = day >= 0 ? day / size : (day + 1) / size - 1
        let position = Int((day % size + size) % size)
        var order = blockOrder(block)
        if order[0] == blockOrder(block - 1).last { order.swapAt(0, 1) }
        return allCases[order[position]]
    }

    /// 少量记录采用紧凑布局，满后切换较大布局；更多记录仍可从下方列表打开。
    func slots(count: Int) -> [CGPoint] {
        let small = smallSlots
        return count <= small.count ? small : largeSlots
    }

    private var smallSlots: [CGPoint] {
        switch self {
        case .heart: return Self.rows([[-1, 1], [-1.5, -0.5, 0.5, 1.5], [-1, 0, 1], [-0.5, 0.5], [0]])
        case .diamond: return Self.rows([[0], [-0.5, 0.5], [-1, 0, 1], [-0.5, 0.5], [0]])
        case .flower: return [.zero] + Self.ring(6, radius: 1.25)
        case .triangle: return Self.rows([[0], [-0.5, 0.5], [-1, 0, 1], [-1.5, -0.5, 0.5, 1.5]])
        case .ring: return Self.ring(8, radius: 1.41)
        case .star: return [.zero] + Self.ring(5, radius: 1) + Self.ring(5, radius: 2)
        case .jigsaw: return Self.points([(0, -2), (-1, -1), (0, -1), (1, -1), (-1, 0), (0, 0), (1, 0), (2, 0), (-1, 1), (0, 1), (1, 1)])
        case .cross: return Self.points([(0, -2), (0, -1), (-2, 0), (-1, 0), (0, 0), (1, 0), (2, 0), (0, 1), (0, 2)])
        }
    }

    private var largeSlots: [CGPoint] {
        switch self {
        case .heart: return Self.rows([[-2, -1, 1, 2], [-2.5, -1.5, -0.5, 0.5, 1.5, 2.5], [-2, -1, 0, 1, 2], [-1.5, -0.5, 0.5, 1.5], [-1, 0, 1], [-0.5, 0.5], [0]])
        case .diamond: return Self.rows([[0], [-0.5, 0.5], [-1, 0, 1], [-1.5, -0.5, 0.5, 1.5], [-1, 0, 1], [-0.5, 0.5], [0]])
        case .flower: return [.zero] + Self.ring(6, radius: 1.1) + Self.ring(12, radius: 2.2)
        case .triangle: return Self.rows([[0], [-0.5, 0.5], [-1, 0, 1], [-1.5, -0.5, 0.5, 1.5], [-2, -1, 0, 1, 2], [-2.5, -1.5, -0.5, 0.5, 1.5, 2.5]])
        case .ring: return Self.ring(16, radius: 2.77)
        case .star: return [.zero] + Self.ring(5, radius: 1) + Self.ring(5, radius: 1.6, offset: 36) + Self.ring(5, radius: 2) + Self.ring(5, radius: 3)
        case .jigsaw: return Self.points([(0, -2.5), (-1.5, -1.5), (-0.5, -1.5), (0.5, -1.5), (1.5, -1.5), (-1.5, -0.5), (-0.5, -0.5), (0.5, -0.5), (1.5, -0.5), (2.5, 0), (-1.5, 0.5), (-0.5, 0.5), (0.5, 0.5), (1.5, 0.5), (-1.5, 1.5), (-0.5, 1.5), (0.5, 1.5), (1.5, 1.5)])
        case .cross: return Self.points([(0, -4), (0, -3), (0, -2), (0, -1), (-4, 0), (-3, 0), (-2, 0), (-1, 0), (0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (0, 1), (0, 2), (0, 3), (0, 4)])
        }
    }

    private static func rows(_ rows: [[Double]]) -> [CGPoint] {
        rows.enumerated().flatMap { row, values in values.map { CGPoint(x: $0, y: Double(row) * 0.866) } }
    }

    private static func points(_ values: [(Double, Double)]) -> [CGPoint] { values.map { CGPoint(x: $0.0, y: $0.1) } }

    private static func ring(_ count: Int, radius: Double, offset: Double = 0) -> [CGPoint] {
        (0..<count).map { index in
            let angle = -Double.pi / 2 + offset * .pi / 180 + 2 * .pi * Double(index) / Double(count)
            return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
        }
    }

    private static func blockOrder(_ block: Int64) -> [Int] {
        var order = Array(0..<8)
        var state = UInt64(bitPattern: block)
        for index in stride(from: 7, through: 1, by: -1) {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            value ^= value >> 31
            let position = Int((value >> 1) % UInt64(index + 1))
            order.swapAt(index, position)
        }
        return order
    }
}

/// 原生矢量裁切形状，未知旧值回退为圆角方形，不使用远程图片资源。
struct NivoMosaicTileShape: Shape {
    var kind: String

    func path(in rect: CGRect) -> Path {
        switch kind {
        case "square": return Path(rect)
        case "circle": return Path(ellipseIn: rect)
        case "hexagon": return polygon(sides: 6, in: rect)
        case "triangle": return polygon(sides: 3, in: rect)
        case "heart": return heart(in: rect)
        case "blob1", "blob2", "blob3": return blob(in: rect)
        default: return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.25)
        }
    }

    private func polygon(sides: Int, in rect: CGRect) -> Path {
        Path { path in
            for index in 0..<sides {
                let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(sides)
                let point = CGPoint(x: rect.midX + cos(angle) * rect.width / 2, y: rect.midY + sin(angle) * rect.height / 2)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }

    private func heart(in rect: CGRect) -> Path {
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        return Path { path in
            path.move(to: point(0.5, 0.94))
            path.addCurve(to: point(0.06, 0.3), control1: point(0.22, 0.73), control2: point(-0.04, 0.52))
            path.addCurve(to: point(0.5, 0.2), control1: point(0.15, 0.02), control2: point(0.4, 0.03))
            path.addCurve(to: point(0.94, 0.3), control1: point(0.6, 0.03), control2: point(0.85, 0.02))
            path.addCurve(to: point(0.5, 0.94), control1: point(1.04, 0.52), control2: point(0.78, 0.73))
            path.closeSubpath()
        }
    }

    private func blob(in rect: CGRect) -> Path {
        let phase = kind == "blob2" ? 0.8 : kind == "blob3" ? 1.6 : 0.0
        return Path { path in
            for index in 0..<72 {
                let angle = Double(index) * .pi / 36
                let radius = 0.43 + sin(3 * angle + phase) * 0.045 + cos(2 * angle - phase) * 0.025
                let point = CGPoint(x: rect.midX + cos(angle) * rect.width * radius, y: rect.midY + sin(angle) * rect.height * radius)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }
}
