//
//  NanoMuseAnchors.swift
//  nanoMuse
//
//  Conversation anchors, as in the Android build (chat/MessageAnchorStore.kt and
//  ui/chat/MessageAnchorsSheet.kt): bookmarks on messages, kept on this phone only, by chat and
//  message id; and one sheet with the questions of the chat, the bookmarks and a search of the
//  chat, where a tap jumps to the message.
//

import Foundation
import SwiftUI

/// The bookmarked message ids of every chat, in UserDefaults under `nanomuse.anchors.<session>`.
@MainActor
final class NanoMuseAnchorStore: ObservableObject {
    static let shared = NanoMuseAnchorStore()
    private static let prefix = "nanomuse.anchors."

    @Published private(set) var saved: [String: Set<String>] = [:]

    private init() {
        var all: [String: Set<String>] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix(Self.prefix) {
            all[String(key.dropFirst(Self.prefix.count))] = Set(value as? [String] ?? [])
        }
        saved = all
    }

    func isSaved(_ messageId: String, in session: String) -> Bool { saved[session]?.contains(messageId) == true }

    func toggle(_ messageId: String, in session: String) {
        var ids = saved[session] ?? []
        if ids.contains(messageId) { ids.remove(messageId) } else { ids.insert(messageId) }
        saved[session] = ids
        if ids.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.prefix + session)
        } else {
            UserDefaults.standard.set(Array(ids).sorted(), forKey: Self.prefix + session)
        }
    }
}

extension Notification.Name {
    /// A message picked in the anchors sheet: `object` is its id. The message list that holds it
    /// puts its row at the top (CollectionViewMessageListV3).
    static let nanoMuseJumpToMessage = Notification.Name("nanoMuse.jumpToMessage")
}

/// One line in the anchors sheet.
struct NanoMuseAnchorEntry: Identifiable {
    let id: UUID
    let key: String
    let isQuestion: Bool
    let preview: String
    let saved: Bool

    /// The questions of the chat (and what is bookmarked), the bookmarks alone, or with a search
    /// every message that holds the words; the preview starts a little before the match.
    static func entries(_ messages: [ChatMessage], saved: Set<String>, query: String, savedOnly: Bool) -> [NanoMuseAnchorEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return messages.compactMap { message in
            guard message.role == .user || message.role == .assistant, !message.isQueued, message.nmRoutine == nil else { return nil }
            let text = NanoMuseMessageKey.text(of: message)
            let key = NanoMuseMessageKey.of(message)
            let marked = saved.contains(key)
            let wanted = savedOnly ? marked : (!needle.isEmpty || message.role == .user || marked)
            guard wanted else { return nil }
            var preview = text
            if !needle.isEmpty {
                guard let hit = text.range(of: needle, options: .caseInsensitive) else { return nil }
                let start = text.index(hit.lowerBound, offsetBy: -35, limitedBy: text.startIndex) ?? text.startIndex
                preview = (start > text.startIndex ? "…" : "") + String(text[start...])
            }
            let flat = preview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return NanoMuseAnchorEntry(id: message.id, key: key, isQuestion: message.role == .user,
                                       preview: String(flat.prefix(220)), saved: marked)
        }
    }
}

/// Conversation anchors: the chat's questions or its bookmarks, a search of the whole chat, and
/// a tap that jumps to the message.
struct NanoMuseAnchorsSheet: View {
    @ObservedObject var vm: AIChatViewModel
    @ObservedObject private var store = NanoMuseAnchorStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var savedOnly = false

    var body: some View {
        let session = vm.nmSessionKey
        let entries = NanoMuseAnchorEntry.entries(vm.messages, saved: store.saved[session] ?? [], query: query, savedOnly: savedOnly)
        NavigationStack {
            List {
                Section {
                    Picker("", selection: $savedOnly) {
                        Text(AppLocalized("Questions")).tag(false)
                        Text(AppLocalized("Bookmarks")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section {
                    if entries.isEmpty {
                        Text(AppLocalized("No matching messages")).foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        HStack(spacing: 8) {
                            Button {
                                dismiss()
                                // after the sheet has gone, so the list is on screen to scroll
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    NotificationCenter.default.post(name: .nanoMuseJumpToMessage, object: entry.id)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.isQuestion ? AppLocalized("You") : AppLocalized("Reply"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(entry.preview.isEmpty ? "…" : entry.preview)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            NanoMuseAnchorButton(session: session, messageId: entry.key)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(AppLocalized("Search this conversation")))
            .navigationTitle(AppLocalized("Conversation anchors"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { dismiss() } } }
        }
    }
}

/// The bookmark button under a reply and in the anchors sheet: one look for both.
struct NanoMuseAnchorButton: View {
    var session: String
    var messageId: String
    @ObservedObject private var store = NanoMuseAnchorStore.shared

    var body: some View {
        let on = store.isSaved(messageId, in: session)
        Button { store.toggle(messageId, in: session) } label: {
            Image(systemName: on ? "bookmark.fill" : "bookmark")
                .font(.system(size: 15))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? NanoMuseTones.action : Color.secondary)
        .accessibilityLabel(Text(on ? AppLocalized("Remove bookmark") : AppLocalized("Add bookmark")))
    }
}
