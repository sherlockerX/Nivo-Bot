import SwiftUI

/// 执行步骤默认收拢为一行；运行中展示当前步骤，点击后在独立面板查看完整过程。
enum NanoMuseSteps {
    static let key = "nanomuse.show_steps"
    static let defaultValue = false

    static func storedValue(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    /// Whether to leave this block out of the chat.
    static func hidden(_ kind: AssistantBlockKind, active: Bool, showSteps: Bool) -> Bool {
        guard !showSteps else { return false }
        switch kind {
        case .shellTool, .fileReadTool, .fileWriteTool, .fileEditTool, .browserTool, .readImageTool, .memoryTool, .thinking:
            return true
        case .text, .info:
            return false
        }
    }

    /// Blocks that belong in the collection-view snapshot. Filtering before cells are restored
    /// keeps a persisted "off" authoritative across chat resets and process launches.
    static func visibleBlocks(
        _ blocks: [AssistantBlock],
        active: Bool,
        showSteps: Bool
    ) -> [AssistantBlock] {
        blocks.filter { !hidden($0.kind, active: active, showSteps: showSteps) }
    }

    /// The first hidden block of a reply: its cell draws the fold line in its place, the other
    /// hidden blocks get no cell.
    static func foldAnchor(_ blocks: [AssistantBlock], active: Bool, showSteps: Bool) -> UUID? {
        blocks.first { hidden($0.kind, active: active, showSteps: showSteps) }?.id
    }

    /// The blocks the collection view gives a cell: the visible ones, and the fold's anchor where
    /// the steps began.
    static func cellBlocks(_ blocks: [AssistantBlock], active: Bool, showSteps: Bool) -> [AssistantBlock] {
        let anchor = foldAnchor(blocks, active: active, showSteps: showSteps)
        return blocks.filter { $0.id == anchor || !hidden($0.kind, active: active, showSteps: showSteps) }
    }

    /// The steps of a reply, the thinking and the tool calls, in order.
    static func steps(of blocks: [AssistantBlock]) -> [AssistantBlock] {
        blocks.filter { hidden($0.kind, active: false, showSteps: false) }
    }

    /// 步骤里的工具调用数（思考不计入）。
    static func toolCount(_ steps: [AssistantBlock]) -> Int {
        steps.filter { block in
            if case .thinking = block.kind { return false }
            return true
        }.count
    }

    /// 过程标题：只有思考时写"正在思考 / 思考过程"，用过工具时写"思考与执行中 / 思考与执行过程"。
    static func title(tools: Int, active: Bool) -> String {
        switch (tools > 0, active) {
        case (true, true): return AppLocalized("Thinking and working")
        case (true, false): return AppLocalized("Thinking and execution")
        case (false, true): return AppLocalized("Thinking now")
        case (false, false): return AppLocalized("Thought process")
        }
    }

    /// "1个工具 / N个工具"。
    static func toolCountLabel(_ tools: Int) -> String {
        tools == 1 ? AppLocalized("1 tool") : String(format: AppLocalized("%d tools"), tools)
    }

    /// 仅取最后一个步骤的简短说明，不在聊天中重复整段工具输出。
    static func currentStep(_ block: AssistantBlock) -> String? {
        let source = block.kind == .thinking ? block.content : (block.toolSummary ?? block.toolDescription)
        let line = source.split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? nil : String(line.prefix(120))
    }
}

private struct NanoMuseStepsUnfoldedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Inside the steps sheet: every block draws itself, the fold set aside.
    var nmStepsUnfolded: Bool {
        get { self[NanoMuseStepsUnfoldedKey.self] }
        set { self[NanoMuseStepsUnfoldedKey.self] = newValue }
    }
}

/// The settings row for it, under Settings → Chat.
struct NanoMuseStepsSection: View {
    @AppStorage(NanoMuseSteps.key) private var showSteps: Bool = NanoMuseSteps.defaultValue

    var body: some View {
        Section {
            Toggle(AppLocalized("Show the agent's steps"), isOn: $showSteps)
        } header: {
            Text(AppLocalized("Steps"))
        } footer: {
            Text(AppLocalized("Show each step in the chat, or fold them into a summary with the current step. Tap the summary to see the full process. This device only."))
        }
    }
}

/// 回答上方的过程摘要，与Android一致：与回答同一左边线、按内容宽度显示的细描边小卡片，
/// 图标、标题、工具数和箭头；执行中第二行显示当前步骤。点按在步骤面板查看全部过程。
struct NanoMuseStepsFold: View {
    @ObservedObject var message: ChatMessage
    @Environment(\.colorScheme) private var colorScheme
    var active = false

    var body: some View {
        let palette = NivoProcessPalette(colorScheme)
        let steps = NanoMuseSteps.steps(of: message.blocks)
        let tools = NanoMuseSteps.toolCount(steps)
        Button {
            // The chat that holds this reply shows its steps (NanoMuseChatHooks); a cell has no view model to ask.
            NanoMuseChatSheets.shared.openSteps(message.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if active { ProgressView().controlSize(.mini).tint(palette.accent) }
                    else {
                        Image(systemName: tools > 0 ? "checklist" : "lightbulb")
                            .font(.footnote)
                            .foregroundStyle(palette.foreground)
                    }
                    // 大字号时标题可换成两行，工具数保持完整。
                    Text(NanoMuseSteps.title(tools: tools, active: active))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if tools > 0 {
                        Text("· " + NanoMuseSteps.toolCountLabel(tools))
                            .font(.footnote)
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.foreground)
                }
                if active, let latest = steps.last {
                    NanoMuseCurrentStepLine(block: latest)
                        .foregroundStyle(palette.foreground)
                        .padding(.leading, 22)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .modifier(NivoProcessSurface())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(AppLocalized("Show all steps")))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 只观察当前步骤的节流发布，避免完整执行记录每次更新都重排聊天列表。
private struct NanoMuseCurrentStepLine: View {
    @ObservedObject var block: AssistantBlock

    var body: some View {
        if let line = NanoMuseSteps.currentStep(block) {
            Text(line).font(.caption).lineLimit(1)
        }
    }
}

/// The steps of one reply in a sheet of their own, so a long process never pushes the answer
/// down the chat: its own scroll, a jump to the first and the latest step, and a tool's detail
/// on a tap.
struct NanoMuseStepsSheet: View {
    @ObservedObject var message: ChatMessage
    @ObservedObject var vm: AIChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var detail: AssistantBlock?
    @State private var highlighted: UUID?

    var body: some View {
        let steps = NanoMuseSteps.steps(of: message.blocks)
        let tools = NanoMuseSteps.toolCount(steps)
        let isActive = vm.isProcessing && vm.messages.last?.id == message.id
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    // 时间线：每一步左侧一个节点，节点之间用细线相连，不再套整块浅蓝底。
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, block in
                            NanoMuseStepRow(block: block, isFirst: index == 0, isLast: index == steps.count - 1,
                                            isActive: isActive) {
                                AssistantBlockView(
                                    block: block,
                                    message: message,
                                    isActiveMessage: isActive,
                                    onStop: { vm.cancel() },
                                    browserPool: vm.browserTabPool,
                                    toolSnapshots: vm.toolSnapshots,
                                    highlightedBlockId: $highlighted,
                                    detailBlock: $detail
                                )
                            }
                            .id(block.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .environment(\.nmStepsUnfolded, true)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Done")) { dismiss() } }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { if let first = steps.first { withAnimation { proxy.scrollTo(first.id, anchor: .top) } } } label: {
                            Image(systemName: "arrow.up.to.line")
                        }
                        .accessibilityLabel(Text(AppLocalized("First step")))
                        .disabled(steps.isEmpty)
                        Button { if let last = steps.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } } label: {
                            Image(systemName: "arrow.down.to.line")
                        }
                        .accessibilityLabel(Text(AppLocalized("Latest step")))
                        .disabled(steps.isEmpty)
                    }
                }
            }
            .navigationTitle(NanoMuseSteps.title(tools: tools, active: isActive))
            .navigationBarTitleDisplayMode(.inline)
        }
        .environmentObject(vm)
        .sheet(item: $detail) { block in
            ToolLiveSheet(
                toolBlocks: steps.filter { candidate in
                    if case .thinking = candidate.kind { return false }
                    return true
                },
                initialIdx: max(0, steps.filter { candidate in
                    if case .thinking = candidate.kind { return false }
                    return true
                }.firstIndex { $0.id == block.id } ?? 0),
                toolSnapshots: vm.toolSnapshots,
                browserPool: vm.browserTabPool
            )
        }
    }
}

/// 时间线上的一步：左侧节点（思考是灯泡，说明是小圆点，工具按状态显示进行中、完成、失败或取消），
/// 节点上下各一段细线连到相邻步骤；第一步不画上段，最后一步不画下段。
private struct NanoMuseStepRow<Content: View>: View {
    @ObservedObject var block: AssistantBlock
    let isFirst: Bool
    let isLast: Bool
    let isActive: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = NivoProcessPalette(colorScheme)
        HStack(alignment: .top, spacing: 8) {
            node(palette)
                .frame(width: 24, height: 20)
                .padding(.top, 6)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
        }
        .background(alignment: .topLeading) {
            GeometryReader { geometry in
                Path { path in
                    if !isFirst {
                        path.move(to: CGPoint(x: 12, y: 0))
                        path.addLine(to: CGPoint(x: 12, y: 6))
                    }
                    if !isLast {
                        path.move(to: CGPoint(x: 12, y: 26))
                        path.addLine(to: CGPoint(x: 12, y: geometry.size.height))
                    }
                }
                .stroke(palette.border, lineWidth: 1.5)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func node(_ palette: NivoProcessPalette) -> some View {
        switch block.kind {
        case .thinking:
            Image(systemName: "lightbulb").font(.footnote).foregroundStyle(palette.foreground)
        case .text, .info:
            Circle().fill(palette.foreground).frame(width: 7, height: 7)
        default:
            switch block.toolStatus {
            case .running?, .streaming?:
                if isActive { ProgressView().controlSize(.mini).tint(palette.accent) }
                else { Circle().fill(palette.foreground).frame(width: 7, height: 7) }
            case .success?:
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                    .accessibilityLabel(Text(AppLocalized("Step done")))
            case .failed?:
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.red)
                    .accessibilityLabel(Text(AppLocalized("Step failed")))
            case .cancelled?:
                Image(systemName: "minus").font(.caption.weight(.bold)).foregroundStyle(.yellow)
                    .accessibilityLabel(Text(AppLocalized("Step cancelled")))
            case nil:
                Circle().fill(palette.foreground).frame(width: 7, height: 7)
            }
        }
    }
}
