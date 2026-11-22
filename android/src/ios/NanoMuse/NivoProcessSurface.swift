import SwiftUI

/// 思考和执行区域的明暗配色，与Android使用相同的色值。
struct NivoProcessPalette {
    let background: Color
    let foreground: Color
    let border: Color

    /// 跟随应用的配色环境，避免深色模式中出现刺眼的浅色底。
    init(_ colorScheme: ColorScheme) {
        if colorScheme == .dark {
            background = Color(red: 27 / 255, green: 45 / 255, blue: 65 / 255)
            foreground = Color(red: 193 / 255, green: 216 / 255, blue: 240 / 255)
            border = Color(red: 52 / 255, green: 80 / 255, blue: 109 / 255)
        } else {
            background = Color(red: 237 / 255, green: 245 / 255, blue: 255 / 255)
            foreground = Color(red: 50 / 255, green: 88 / 255, blue: 121 / 255)
            border = Color(red: 213 / 255, green: 230 / 255, blue: 247 / 255)
        }
    }
}

/// 摘要使用胶囊背景，长详情使用大圆角；修饰器不改变内容的结构身份。
struct NivoProcessSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var isExpanded = false

    /// 背景与描边不接收手势，保留原有折叠、滚动及工具按钮操作。
    func body(content: Content) -> some View {
        let palette = NivoProcessPalette(colorScheme)
        // 辅助功能大字号可能产生多行，避免椭圆两端裁掉行首文字。
        let radius: CGFloat = isExpanded || dynamicTypeSize.isAccessibilitySize ? 20 : 1_000
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .foregroundStyle(palette.foreground)
            .background(shape.fill(palette.background))
            .clipShape(shape)
            .overlay(shape.strokeBorder(palette.border, lineWidth: 1).allowsHitTesting(false))
    }
}
