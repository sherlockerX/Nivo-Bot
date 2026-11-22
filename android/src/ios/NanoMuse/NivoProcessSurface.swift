import SwiftUI

/// 思考和执行区域的配色。过程是回答的附属信息：弱化的系统次级文字和细描边，
/// 只有进行中的图标用强调色，不再用整块浅蓝底和正文争夺注意力。与Android取色规则一致。
struct NivoProcessPalette {
    let background: Color
    let foreground: Color
    let border: Color
    let accent: Color

    /// 使用系统语义色，深浅模式自动适配；参数保留给已有调用处。
    init(_ colorScheme: ColorScheme) {
        background = .clear
        foreground = Color(uiColor: .secondaryLabel)
        border = Color(uiColor: .separator)
        accent = .accentColor
    }
}

/// 过程标题使用内容宽度的细描边小卡片，与回答气泡同一左边线；修饰器不改变内容的结构身份。
struct NivoProcessSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    /// 旧调用处仍会传入展开状态；新样式展开与收起使用同一圆角。
    var isExpanded = false

    /// 描边不接收手势，保留原有折叠、滚动及工具按钮操作。
    func body(content: Content) -> some View {
        let palette = NivoProcessPalette(colorScheme)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .contentShape(shape)
            .overlay(shape.strokeBorder(palette.border, lineWidth: 1).allowsHitTesting(false))
    }
}
