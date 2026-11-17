import SwiftUI

/// 经典聊天布局保留生活模块的可见入口，菜单和深链使用同一个导航队列。
struct NivoClassicModuleMenu: View {
    var body: some View {
        Menu {
            entry("mosaic", title: "Mosaic", symbol: "square.grid.2x2")
            entry("coach", title: "Coach", symbol: "graduationcap")
            entry("ideas", title: "Ideas", symbol: "lightbulb")
            entry("todo", title: "Tasks", symbol: "checklist")
            entry("focus", title: "Focus", symbol: "timer")
            Divider()
            entry("routines", title: "Scheduled tasks", symbol: "clock")
        } label: {
            Image(systemName: "square.grid.2x2")
        }
        .accessibilityLabel(AppLocalized("More"))
    }

    private func entry(_ room: String, title: String.LocalizationValue, symbol: String) -> some View {
        Button { NivoLifeNavigation.shared.open(room) } label: {
            Label(AppLocalized(title), systemImage: symbol)
        }
    }
}
