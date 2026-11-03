import SwiftUI

/// "Show the agent's steps": whether a finished reply keeps its thinking and tool capsules (a
/// command run, a file read, a page opened…) in the chat. Off by default, as in the Android
/// build: a finished reply folds them into one line, "Thinking and execution (3 tools)", which
/// opens them in a sheet of their own (NanoMuseStepsSheet). A stored `true` still wins. While a
/// message is still running its steps show either way, since the phone has no status line under
/// the face to say what it is on. This device only (`@AppStorage`).
enum NanoMuseSteps {
    static let key = "nanomuse.show_steps"
    static let defaultValue = false

    static func storedValue(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    /// Whether to leave this block out of the chat.
    static func hidden(_ kind: AssistantBlockKind, active: Bool, showSteps: Bool) -> Bool {
        guard !showSteps, !active else { return false }
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
            Text(AppLocalized("On, every step stays in the chat. Off, a finished reply folds its thinking and tools into one line that opens them in a sheet; a reply still running shows its steps either way. This device only."))
        }
    }
}

/// The fold line where a finished reply's steps were, as in the Android build: "Thinking and
/// execution (3 tools)". A tap opens them in the steps sheet.
struct NanoMuseStepsFold: View {
    @ObservedObject var message: ChatMessage

    var body: some View {
        let tools = NanoMuseSteps.steps(of: message.blocks).filter { block in
            if case .thinking = block.kind { return false }
            return true
        }.count
        Button {
            // The chat that holds this reply shows its steps (NanoMuseChatHooks); a cell has no view model to ask.
            NanoMuseChatSheets.shared.openSteps(message.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                Text(String(format: AppLocalized("Thinking and execution (%d tools)"), tools))
                    .font(.footnote)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The steps of one reply in a sheet of their own, so a long process never pushes the answer
/// down the chat: its own scroll, a jump to the first and the latest step, and a tool's detail
/// on a tap.
struct NanoMuseStepsSheet: View {
    @ObservedObject var message: ChatMessage
    let vm: AIChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var detail: AssistantBlock?
    @State private var highlighted: UUID?

    var body: some View {
        let steps = NanoMuseSteps.steps(of: message.blocks)
        let tools = steps.filter { block in
            if case .thinking = block.kind { return false }
            return true
        }.count
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(steps) { block in
                            AssistantBlockView(
                                block: block,
                                message: message,
                                isActiveMessage: false,
                                browserPool: vm.browserTabPool,
                                toolSnapshots: vm.toolSnapshots,
                                highlightedBlockId: $highlighted,
                                detailBlock: $detail
                            )
                            .id(block.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
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
            .navigationTitle(String(format: AppLocalized("Thinking and execution (%d tools)"), tools))
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
