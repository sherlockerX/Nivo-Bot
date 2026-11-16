import SwiftUI

/// 对齐安卓CoachSceneArt的能力场景，静态原生矢量不依赖图片下载或常驻动画。
struct NivoCoachSceneArt: View {
    let kind: NivoCoachKind
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            var scaled = context
            scaled.scaleBy(x: size.width / 320, y: size.height / 150)
            let ink = colorScheme == .dark ? Color(red: 0.831, green: 0.843, blue: 0.835) : Color(red: 0.208, green: 0.275, blue: 0.247)
            NivoCoachScenePainter(context: scaled, ink: ink, accent: accent).draw(kind)
        }
        .aspectRatio(320.0 / 150, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var accent: Color {
        switch kind {
        case .judgment: return Color(red: 0.447, green: 0.616, blue: 0.514)
        case .perspectives: return Color(red: 0.675, green: 0.529, blue: 0.443)
        case .english: return Color(red: 0.482, green: 0.620, blue: 0.694)
        case .expression: return Color(red: 0.639, green: 0.549, blue: 0.667)
        case .leadership: return Color(red: 0.714, green: 0.608, blue: 0.388)
        case .execution: return Color(red: 0.510, green: 0.616, blue: 0.549)
        case .custom: return Color(red: 0.510, green: 0.592, blue: 0.678)
        }
    }
}

/// 统一320×150坐标，文字由外层SwiftUI排版，避免字体放大后被画布裁切。
private struct NivoCoachScenePainter {
    let context: GraphicsContext
    let ink: Color
    let accent: Color

    /// 场景由课程类型稳定选择，不根据标题猜测用户人格或心理状态。
    func draw(_ kind: NivoCoachKind) {
        circle(238, 72, 65, accent.opacity(0.10))
        ellipse(18, 119, 285, 24, accent.opacity(0.10))
        switch kind {
        case .judgment: bamboo()
        case .perspectives: debate()
        case .english: exchange()
        case .expression: stage()
        case .leadership: workshop()
        case .execution: trail()
        case .custom: compass()
        }
    }

    private func bamboo() {
        let stems: [(CGFloat, CGFloat)] = [(44, 40), (83, 14), (243, 27), (281, 48)]
        for (index, stem) in stems.enumerated() {
            let (x, top) = stem
            let color = accent.opacity(index.isMultiple(of: 2) ? 0.6 : 1)
            line(x, 130, x + 8, top, color, width: 7)
            for y in [CGFloat(58), 86, 114] {
                line(x - 3, y, x + 10, y - 1, ink.opacity(0.35), width: 1.5)
                leaf(x + 5, y - 3, index.isMultiple(of: 2) ? 22 : -22, color)
                leaf(x + 6, y - 2, index.isMultiple(of: 2) ? -16 : 17, color)
            }
        }
        circle(161, 48, 23, accent.opacity(0.13))
        line(121, 121, 201, 121, ink, width: 3)
        line(132, 122, 128, 137, ink, width: 3)
        line(190, 122, 194, 137, ink, width: 3)
        var book = Path()
        book.move(to: CGPoint(x: 139, y: 105))
        book.addQuadCurve(to: CGPoint(x: 161, y: 108), control: CGPoint(x: 151, y: 100))
        book.addQuadCurve(to: CGPoint(x: 184, y: 105), control: CGPoint(x: 172, y: 100))
        book.addLine(to: CGPoint(x: 183, y: 119))
        book.addQuadCurve(to: CGPoint(x: 161, y: 120), control: CGPoint(x: 169, y: 114))
        book.addQuadCurve(to: CGPoint(x: 139, y: 118), control: CGPoint(x: 150, y: 114))
        book.closeSubpath()
        context.fill(book, with: .color(ink.opacity(0.7)))
    }

    private func debate() {
        person(73, 59, accent)
        person(244, 59, accent.opacity(0.65))
        ellipse(94, 97, 134, 29, accent.opacity(0.5))
        line(123, 122, 117, 142, ink, width: 3)
        line(200, 122, 206, 142, ink, width: 3)
        bubble(91, 20, 58, accent, left: true)
        bubble(176, 12, 61, ink.opacity(0.65), left: false)
        line(111, 88, 140, 101, ink, width: 3)
        line(209, 88, 184, 101, ink, width: 3)
    }

    private func exchange() {
        roundRect(45, 20, 230, 102, 28, accent.opacity(0.12))
        person(103, 65, accent)
        person(215, 65, accent.opacity(0.5))
        bubble(125, 23, 57, accent, left: true)
        context.stroke(Path(ellipseIn: CGRect(x: 234, y: 31, width: 46, height: 46)), with: .color(ink.opacity(0.45)), lineWidth: 1.8)
        context.stroke(Path(ellipseIn: CGRect(x: 247, y: 31, width: 20, height: 46)), with: .color(ink.opacity(0.45)), lineWidth: 1.4)
        line(234, 54, 280, 54, ink.opacity(0.45), width: 1.4)
    }

    private func stage() {
        ellipse(61, 113, 196, 23, accent.opacity(0.35))
        person(154, 47, accent)
        line(194, 77, 194, 119, ink, width: 2.5)
        line(187, 69, 201, 75, ink, width: 5)
        bubble(190, 18, 64, accent, left: true)
        for x in [CGFloat(73), 245] {
            circle(x, 117, 10, ink.opacity(0.5))
            ellipse(x - 20, 129, 40, 18, ink.opacity(0.25))
        }
    }

    private func workshop() {
        roundRect(96, 13, 132, 75, 8, ink.opacity(0.12))
        for index in 0..<3 { roundRect(111 + CGFloat(index) * 36, 28, 26, 22, 3, accent.opacity(0.5 + Double(index) * 0.15)) }
        line(117, 67, 201, 67, ink.opacity(0.5), width: 2)
        person(68, 70, accent)
        person(253, 70, accent.opacity(0.6))
        line(111, 108, 218, 108, ink, width: 5)
        line(121, 111, 117, 139, ink, width: 3)
        line(207, 111, 211, 139, ink, width: 3)
    }

    private func trail() {
        var path = Path()
        path.move(to: CGPoint(x: 60, y: 139))
        path.addCurve(to: CGPoint(x: 196, y: 68), control1: CGPoint(x: 67, y: 97), control2: CGPoint(x: 221, y: 107))
        path.addQuadCurve(to: CGPoint(x: 246, y: 25), control: CGPoint(x: 174, y: 38))
        context.stroke(path, with: .color(accent.opacity(0.25)), style: StrokeStyle(lineWidth: 20, lineCap: .round))
        context.stroke(path, with: .color(accent.opacity(0.6)), lineWidth: 2)
        for point in [CGPoint(x: 92, y: 111), CGPoint(x: 171, y: 91), CGPoint(x: 211, y: 42)] { circle(point.x, point.y, 4, ink) }
        line(248, 20, 248, 52, ink, width: 2.5)
        polygon([CGPoint(x: 249, y: 20), CGPoint(x: 275, y: 25), CGPoint(x: 249, y: 35)], accent)
        leaf(53, 97, 22, accent)
        leaf(279, 116, -26, accent)
    }

    private func compass() {
        circle(160, 75, 49, accent.opacity(0.18))
        context.stroke(Path(ellipseIn: CGRect(x: 120, y: 35, width: 80, height: 80)), with: .color(ink.opacity(0.7)), lineWidth: 2)
        polygon([CGPoint(x: 180, y: 43), CGPoint(x: 167, y: 81), CGPoint(x: 140, y: 107), CGPoint(x: 153, y: 69)], accent)
        circle(160, 75, 4, ink)
        for point in [CGPoint(x: 111, y: 75), CGPoint(x: 209, y: 75), CGPoint(x: 160, y: 26), CGPoint(x: 160, y: 124)] { circle(point.x, point.y, 2, ink) }
    }

    private func person(_ x: CGFloat, _ y: CGFloat, _ color: Color) {
        circle(x, y, 11, ink)
        roundRect(x - 18, y + 17, 36, 45, 14, color)
        line(x - 10, y + 60, x - 14, 140, ink, width: 3)
        line(x + 10, y + 60, x + 14, 140, ink, width: 3)
    }

    private func bubble(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ color: Color, left: Bool) {
        roundRect(x, y, width, 29, 10, color.opacity(0.2))
        let tail = left ? x + 10 : x + width - 15
        polygon([CGPoint(x: tail, y: y + 24), CGPoint(x: tail, y: y + 38), CGPoint(x: tail + 12, y: y + 27)], color.opacity(0.2))
        for index in 0..<3 { circle(x + 17 + CGFloat(index) * 12, y + 14, 2.2, color) }
    }

    private func leaf(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: x, y: y))
        path.addQuadCurve(to: CGPoint(x: x + width, y: y - 21), control: CGPoint(x: x + width * 0.3, y: y - 18))
        path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x + width * 0.8, y: y - 2))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    private func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat, _ color: Color) {
        ellipse(x - radius, y - radius, radius * 2, radius * 2, color)
    }

    private func ellipse(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: Color) {
        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: width, height: height)), with: .color(color))
    }

    private func roundRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat, _ color: Color) {
        context.fill(Path(roundedRect: CGRect(x: x, y: y, width: width, height: height), cornerRadius: radius), with: .color(color))
    }

    private func polygon(_ points: [CGPoint], _ color: Color) {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    private func line(_ x: CGFloat, _ y: CGFloat, _ endX: CGFloat, _ endY: CGFloat, _ color: Color, width: CGFloat) {
        var path = Path()
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: endX, y: endY))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}
