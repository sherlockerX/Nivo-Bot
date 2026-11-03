//
//  NanoMuseDrawerSessions.swift
//  nanoMuse
//
//  The drawer's side chats, as in the Android build (ui/home/DrawerSessions.kt): the chats in
//  their groups, each group folding open and shut, then Ungrouped; a chat's long press with the
//  session list's actions; and a selection mode that moves or deletes several chats at once.
//  The drawer around it (NanoMuseShell.swift) holds the header and the bottom strip.
//

import SwiftUI

struct NanoMuseDrawerSessions: View {
    /// The side chats, the search applied.
    var sessions: [ChatSession]
    var query: String
    var currentId: String?
    /// The panel's width, for the long press's preview.
    var width: CGFloat
    @Binding var selecting: Bool
    @Binding var creatingGroup: Bool
    var onOpen: (String) -> Void
    var onPinMain: (String) -> Void
    /// Something changed under the list (a pin, a move, a title): read the chats again.
    var onChanged: () -> Void

    @State private var folders: [ChatFolder] = []
    @State private var collapsed: Set<String> = []
    @State private var selected: Set<String> = []
    /// Deleted here and not yet gone from the list the drawer reads.
    @State private var removed: Set<String> = []
    @State private var moving: Set<String> = []
    @State private var deleting: Set<String> = []
    @State private var editing: ChatSession?
    @State private var editTitle = ""
    @State private var editCategory = ""
    @State private var groupName = ""
    @State private var groupTaken: String?
    @State private var exported: NanoMuseExportFile?

    private static let ungroupedKey = "__ungrouped__"

    /// Pinned chats first, then the most recent.
    private var ordered: [ChatSession] {
        sessions.filter { !removed.contains($0.id) }.sorted { a, b in
            switch (a.pinnedAt, b.pinnedAt) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.updatedAt > b.updatedAt
            }
        }
    }

    /// Pinned groups first, then by name.
    private var orderedFolders: [ChatFolder] {
        folders.sorted { a, b in
            switch (a.pinnedAt, b.pinnedAt) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    var body: some View {
        let known = Set(folders.map(\.id))
        let groups = Dictionary(grouping: ordered) { s in s.folderId.flatMap { known.contains($0) ? $0 : nil } ?? Self.ungroupedKey }
        let ungrouped = groups[Self.ungroupedKey] ?? []
        VStack(spacing: 0) {
            if selecting { selectionBar }
            if ordered.isEmpty && folders.isEmpty && query.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(orderedFolders) { folder in
                        let members = groups[folder.id] ?? []
                        if query.isEmpty || !members.isEmpty {
                            header(folder.id, folder.name, members)
                            if !collapsed.contains(folder.id) || !query.isEmpty {
                                ForEach(members) { item($0, filed: true) }
                            }
                        }
                    }
                    header(Self.ungroupedKey, AppLocalized("Ungrouped"), ungrouped)
                    if !collapsed.contains(Self.ungroupedKey) || !query.isEmpty {
                        ForEach(ungrouped) { item($0, filed: false) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .alert(AppLocalized("Edit Title & Category"), isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                    TextField(AppLocalized("Title"), text: $editTitle)
                    TextField(AppLocalized("Category"), text: $editCategory)
                    Button(AppLocalized("Cancel"), role: .cancel) { editing = nil }
                    Button(AppLocalized("Save")) { saveEdit() }
                }
                .alert(AppLocalized("Delete"), isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
                    Button(AppLocalized("Cancel"), role: .cancel) { deleting = [] }
                    Button(AppLocalized("Delete"), role: .destructive) { deleteNow() }
                } message: {
                    Text(deleting.count == 1
                         ? AppLocalized("The chat and its messages are removed from this device. With sync on, the other devices remove it too.")
                         : String(format: AppLocalized("Delete %d conversations?"), deleting.count))
                }
            }
        }
        .alert(AppLocalized("New Group"), isPresented: $creatingGroup) {
            TextField(AppLocalized("Group name"), text: $groupName)
            Button(AppLocalized("Cancel"), role: .cancel) { groupName = "" }
            Button(AppLocalized("Create")) { createGroup() }
        }
        .alert(String(format: AppLocalized("“%@” already exists"), groupTaken ?? ""), isPresented: Binding(get: { groupTaken != nil }, set: { if !$0 { groupTaken = nil } })) {
            Button(AppLocalized("OK"), role: .cancel) { groupTaken = nil }
        }
        .sheet(isPresented: Binding(get: { !moving.isEmpty }, set: { if !$0 { moving = [] } })) {
            NanoMuseGroupPickerSheet(
                folders: orderedFolders,
                counts: groups.mapValues(\.count),
                anyFiled: ordered.contains { s in moving.contains(s.id) && s.folderId.map { known.contains($0) } == true }
            ) { choice in move(moving, to: choice) }
        }
        .sheet(item: $exported) { file in NanoMuseShareSheet(items: [file.url]) }
        .onAppear { loadFolders() }
        .nmOnChange(of: sessions) { list in
            loadFolders()
            let ids = Set(list.map(\.id))
            selected.formIntersection(ids)
            removed.formIntersection(ids)
        }
        .nmOnChange(of: selecting) { on in
            if !on { selected = [] }
        }
    }

    // MARK: Parts

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(AppLocalized("Start a side chat"))
                .font(.body.weight(.medium))
            Text(AppLocalized("Side chats are an optional way to keep conversations organised by topic."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// "3 selected" with Select All, then Cancel · Move to Group · Delete.
    private var selectionBar: some View {
        let all = Set(ordered.map(\.id))
        let allSelected = !all.isEmpty && all.isSubset(of: selected)
        return VStack(spacing: 6) {
            HStack {
                Text(String(format: AppLocalized("%d selected"), selected.count)).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Button(allSelected ? AppLocalized("Deselect All") : AppLocalized("Select All")) { selected = allSelected ? [] : all }
                    .disabled(all.isEmpty)
            }
            HStack {
                Button(AppLocalized("Cancel")) { selecting = false }
                Spacer(minLength: 8)
                Button(AppLocalized("Move to Group")) { moving = selected }
                    .disabled(selected.isEmpty)
                Spacer(minLength: 8)
                Button(AppLocalized("Delete"), role: .destructive) { deleting = selected }
                    .disabled(selected.isEmpty)
            }
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
        .tint(NanoMuseTones.action)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// A group's line: open or shut on a tap, its count, and in selection mode a tick for all of it.
    private func header(_ key: String, _ name: String, _ members: [ChatSession]) -> some View {
        let ids = Set(members.map(\.id))
        let allIn = !ids.isEmpty && ids.isSubset(of: selected)
        let open = !collapsed.contains(key) || !query.isEmpty
        return HStack(spacing: 8) {
            Button {
                if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                    Text(verbatim: "\(name) (\(members.count))")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            if selecting {
                Button {
                    if allIn { selected.subtract(ids) } else { selected.formUnion(ids) }
                } label: {
                    Image(systemName: allIn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(allIn ? NanoMuseTones.action : Color.secondary)
                }
                .disabled(ids.isEmpty)
                .accessibilityLabel(Text(AppLocalized("Select All")))
            }
        }
        .buttonStyle(.borderless)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func item(_ session: ChatSession, filed: Bool) -> some View {
        let row = Button {
            if selecting {
                if selected.contains(session.id) { selected.remove(session.id) } else { selected.insert(session.id) }
            } else {
                onOpen(session.id)
            }
        } label: {
            HStack(spacing: 10) {
                if selecting {
                    Image(systemName: selected.contains(session.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(selected.contains(session.id) ? NanoMuseTones.action : Color.secondary)
                }
                rowContent(session)
            }
        }
        .listRowBackground(session.id == currentId && !selecting ? NanoMuseTones.fill : Color.clear)
        if selecting {
            row
        } else {
            row.contextMenu {
                menu(session, filed: filed)
            } preview: {
                // The default preview lifts the List cell, which the system lays out wider than
                // the drawer; the drawer then clips it at its edge and the chat shows through. An
                // explicit preview does not: the system sets it 16 pt in from the edge.
                rowContent(session)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(width: width - 32, alignment: .leading)
                    .background(NanoMuseTones.surface)
            }
        }
    }

    private func rowContent(_ session: ChatSession) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text((session.title?.isEmpty == false ? session.title : nil) ?? AppLocalized("New chat"))
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                // C8: a chat that arrived through sync is an ordinary chat in this list; the
                // device shows under each of its bubbles ("From Pixel 8"), not here.
                if let last = session.lastMessage, !last.isEmpty {
                    Text(last)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Text(NanoMuseDrawer.when(session.updatedAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    /// The session list's actions on one chat, in the Android build's order.
    @ViewBuilder
    private func menu(_ session: ChatSession, filed: Bool) -> some View {
        Button { onPinMain(session.id) } label: {
            Label(AppLocalized("Make this the main chat"), systemImage: "house")
        }
        Button { run { _ = await ChatStore.shared.toggleSessionPin(session.id) } } label: {
            Label(session.isPinned ? AppLocalized("Unpin") : AppLocalized("Pin"), systemImage: session.isPinned ? "pin.slash" : "pin")
        }
        Menu {
            Button { export(session, json: true) } label: { Label(AppLocalized("JSON"), systemImage: "doc.text") }
            Button { export(session, json: false) } label: { Label(AppLocalized("Plain Text"), systemImage: "text.alignleft") }
        } label: {
            Label(AppLocalized("Export"), systemImage: "square.and.arrow.up")
        }
        Button {
            editTitle = session.title ?? ""
            editCategory = session.category ?? ""
            editing = session
        } label: {
            Label(AppLocalized("Edit Title & Category"), systemImage: "square.and.pencil")
        }
        Button { run { _ = try? await AIChatViewModel.regenerateSessionTitle(sessionId: session.id) } } label: {
            Label(AppLocalized("Regenerate Title"), systemImage: "arrow.triangle.2.circlepath")
        }
        Button { run { _ = await SessionForkManager.shared.duplicateSession(sessionId: session.id) } } label: {
            Label(AppLocalized("Duplicate"), systemImage: "doc.on.doc")
        }
        Button { moving = [session.id] } label: {
            Label(filed ? AppLocalized("Change Group") : AppLocalized("Move to Group"), systemImage: filed ? "folder.badge.gearshape" : "folder")
        }
        Button {
            selected = [session.id]
            selecting = true
        } label: {
            Label(AppLocalized("Select"), systemImage: "checkmark.circle")
        }
        Divider()
        Button(role: .destructive) { deleting = [session.id] } label: {
            Label(AppLocalized("Delete"), systemImage: "trash")
        }
    }

    // MARK: Actions

    private func loadFolders() {
        Task { @MainActor in folders = await ChatStore.shared.listFolders() }
    }

    /// One change to the store, then the list and the groups read again.
    private func run(_ work: @escaping () async -> Void) {
        Task { @MainActor in
            await work()
            loadFolders()
            onChanged()
        }
    }

    private func saveEdit() {
        guard let session = editing else { return }
        editing = nil
        let title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = editCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        run { await ChatStore.shared.updateSessionTitle(session.id, title: title, category: category.isEmpty ? nil : category) }
    }

    private func createGroup() {
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        groupName = ""
        guard !name.isEmpty else { return }
        Task { @MainActor in
            if await ChatStore.shared.findFolderByName(name) != nil {
                groupTaken = name
                return
            }
            _ = await ChatStore.shared.createFolder(name: name)
            loadFolders()
        }
    }

    private func move(_ ids: Set<String>, to choice: NanoMuseGroupPickerSheet.Choice) {
        moving = []
        selecting = false
        let list = Array(ids)
        run {
            switch choice {
            case .folder(let id):
                await ChatStore.shared.setFolder(id, forSessions: list)
            case .ungrouped:
                await ChatStore.shared.setFolder(nil, forSessions: list)
            case .create(let name):
                var folder = await ChatStore.shared.findFolderByName(name)
                if folder == nil { folder = await ChatStore.shared.createFolder(name: name) }
                if let folder { await ChatStore.shared.setFolder(folder.id, forSessions: list) }
            }
        }
    }

    private func deleteNow() {
        let ids = deleting
        deleting = []
        selecting = false
        removed.formUnion(ids)
        for id in ids { NanoMuseChatDelete.delete(id) }
    }

    /// The chat as a JSON or text file, handed to the share sheet.
    private func export(_ session: ChatSession, json: Bool) {
        Task { @MainActor in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nanomuse-export-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = String((session.title ?? "chat").prefix(60)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let url = dir.appendingPathComponent(name + (json ? ".json" : ".txt"))
            do {
                try await ContentView.nmExport([session], json: json, to: url)
                exported = NanoMuseExportFile(url: url)
            } catch {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }
}

/// An exported chat waiting for the share sheet.
struct NanoMuseExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Where the chats go: an existing group, a new one, or out of their group.
struct NanoMuseGroupPickerSheet: View {
    enum Choice {
        case folder(String)
        case ungrouped
        case create(String)
    }

    var folders: [ChatFolder]
    var counts: [String: Int]
    /// One of the chats is in a group: Remove from Group is offered.
    var anyFiled: Bool
    var onChoose: (Choice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                if !folders.isEmpty {
                    Section {
                        ForEach(folders) { folder in
                            Button { onChoose(.folder(folder.id)) } label: {
                                HStack {
                                    Label(folder.name, systemImage: "folder")
                                    Spacer(minLength: 8)
                                    Text(verbatim: "\(counts[folder.id] ?? 0)").foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
                Section {
                    HStack {
                        TextField(AppLocalized("Group name"), text: $name)
                        Button(AppLocalized("Create")) { onChoose(.create(name.trimmingCharacters(in: .whitespacesAndNewlines))) }
                            .buttonStyle(.borderless)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text(AppLocalized("New Group"))
                }
                if anyFiled {
                    Section {
                        Button(AppLocalized("Remove from Group"), role: .destructive) { onChoose(.ungrouped) }
                    }
                }
            }
            .navigationTitle(AppLocalized("Move to Group"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Cancel")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
