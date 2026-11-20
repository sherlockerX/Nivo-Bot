import SwiftUI

/// 教练、专注和待办的紧凑页头，与Android的CoachHeader、FocusHeader、TodoHeader一致：
/// 左侧打开抽屉，中间是页标题，右侧是本页入口。这些页面的入口较多，不放大头像，
/// 避免右侧按钮压到头像上。
struct NivoCompactRoomHeader<Trailing: View>: View {
    var title: String
    var onMenu: () -> Void
    /// 点标题回到本页首屏；为空时标题只作展示。
    var onTitle: (() -> Void)? = nil
    var horizontalPadding: CGFloat = 16
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, onMenu: @escaping () -> Void, onTitle: (() -> Void)? = nil,
         horizontalPadding: CGFloat = 16, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.onMenu = onMenu
        self.onTitle = onTitle
        self.horizontalPadding = horizontalPadding
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            NanoMuseRoundButton(symbol: "line.3.horizontal", label: AppLocalized("Chats and settings"), action: onMenu)
            titleView
                .layoutPriority(1)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var titleView: some View {
        let text = Text(title)
            .font(.title2.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityAddTraits(.isHeader)
        if let onTitle {
            Button(action: onTitle) { text }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
        } else {
            text
        }
    }
}
