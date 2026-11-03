//
//  NanoMuseReplyActions.swift
//  nanoMuse
//
//  The row under a finished reply, as in the Android build (ui/chat/NmReplyActions.kt): the
//  turn's time, then bookmark, copy, read aloud or stop, answer again (the latest reply), branch
//  from here, and share as a picture or as text. It sits in the reply's footer cell
//  (CollectionViewMessageListV3), which has the chat's view model in its environment.
//

import CryptoKit
import SwiftUI
import UIKit

/// A message's identity that survives a reload: a ChatMessage's own id is minted again every
/// time the chat is read back, so bookmarks and turn times key on the role and the text.
enum NanoMuseMessageKey {
    /// What a message says: the person's words, or the reply's text blocks in order.
    static func text(of message: ChatMessage) -> String {
        guard message.role == .assistant else { return message.content }
        return message.blocks.filter { block in
            if case .text = block.kind { return true }
            return false
        }.map(\.content).joined(separator: "\n\n")
    }

    static func of(_ message: ChatMessage) -> String {
        let digest = SHA256.hash(data: Data(text(of: message).utf8)).map { String(format: "%02x", $0) }.joined()
        return (message.role == .user ? "u:" : "a:") + digest.prefix(16)
    }
}

/// How long each turn took, measured on this phone from the send to the end of the reply and
/// kept by chat under `nanomuse.turn_times.<session>`. A reply measured nowhere shows no time.
@MainActor
enum NanoMuseTurnTimes {
    private static let prefix = "nanomuse.turn_times."
    private static let keep = 300
    private static var started: [ObjectIdentifier: Date] = [:]

    static func began(_ vm: AIChatViewModel) {
        started[ObjectIdentifier(vm)] = Date()
    }

    static func ended(_ vm: AIChatViewModel) {
        guard let start = started.removeValue(forKey: ObjectIdentifier(vm)),
              let reply = vm.messages.last(where: { $0.role == .assistant }),
              !NanoMuseMessageKey.text(of: reply).isEmpty else { return }
        let key = prefix + vm.nmSessionKey
        var times = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        times[NanoMuseMessageKey.of(reply)] = Date().timeIntervalSince(start)
        if times.count > keep {
            for stale in times.keys.sorted().prefix(times.count - keep) { times.removeValue(forKey: stale) }
        }
        UserDefaults.standard.set(times, forKey: key)
    }

    static func elapsed(_ reply: ChatMessage, session: String) -> TimeInterval? {
        (UserDefaults.standard.dictionary(forKey: prefix + session) as? [String: Double])?[NanoMuseMessageKey.of(reply)]
    }

    static func format(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        f.zeroFormattingBehavior = .dropLeading
        return f.string(from: max(1, seconds.rounded())) ?? "\(Int(seconds))s"
    }
}

/// "Branch from here": a new chat holding the conversation up to the end of a reply's turn, so a
/// side topic can be followed without touching the original. The stored rows are copied as they
/// are, tool calls and results included, so the model sees the same history.
enum NanoMuseChatBranch {
    /// The new chat's id; nil when the chat is not saved yet or there is nothing to copy.
    static func create(session: String, messages: [ChatMessage], reply: ChatMessage, title: String) async -> String? {
        let store = ChatStore.shared
        guard let source = await store.getSession(session),
              let at = messages.firstIndex(where: { $0.id == reply.id }) else { return nil }
        let turns = messages[...at].filter { $0.role == .user && !$0.isQueued }.count
        let rows = await store.loadMessages(sessionId: session)
        var seen = 0
        var cut = rows.count
        for (i, row) in rows.enumerated() where row.role == .user && !row.isToolResultOnly {
            if seen == turns {
                cut = i
                break
            }
            seen += 1
        }
        let kept = rows.prefix(cut)
        guard !kept.isEmpty else { return nil }
        let branch = await store.createSession(modelId: source.modelId, title: title)
        for row in kept {
            await store.appendMessage(RawMessage(
                id: UUID().uuidString,
                sessionId: branch.id,
                role: row.role,
                parts: row.parts,
                createdAt: row.createdAt,
                tokenUsage: nil,
                reasoningContent: row.reasoningContent,
                streamInterruptCount: row.streamInterruptCount
            ))
        }
        NotificationCenter.default.post(name: .sessionDidUpdate, object: nil)
        return branch.id
    }
}

/// Which reply the row started reading aloud, so its button turns into Stop.
@MainActor
final class NanoMuseReplyReading: ObservableObject {
    static let shared = NanoMuseReplyReading()
    @Published var messageId: UUID?
}

struct NanoMuseReplyActions: View {
    @ObservedObject var message: ChatMessage
    /// The reply still being written: the row waits until it is done.
    var active: Bool
    @EnvironmentObject private var vm: AIChatViewModel
    @ObservedObject private var voice = VoiceOutputState.shared
    @ObservedObject private var reading = NanoMuseReplyReading.shared
    @State private var copied = false
    @State private var branching = false
    @State private var branchFailed = false

    /// A reply with words of its own gets the row. The three helpers are read by the collection
    /// view's snapshot and height estimates too, so they are not tied to the main actor.
    nonisolated static func shows(_ message: ChatMessage) -> Bool {
        message.role == .assistant && !NanoMuseMessageKey.text(of: message).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func visible(_ message: ChatMessage, active: Bool) -> Bool { !active && shows(message) }

    /// The footer's height before it is measured: the row and the time line over it.
    nonisolated static func estimatedHeight(_ message: ChatMessage?) -> CGFloat {
        guard let message, shows(message) else { return 4 }
        return 56
    }

    var body: some View {
        if Self.visible(message, active: active) {
            let session = vm.nmSessionKey
            let markdown = NanoMuseMessageKey.text(of: message)
            let question = self.question
            let latest = vm.messages.last(where: { $0.role == .assistant })?.id == message.id
            let isReading = reading.messageId == message.id && voice.isReadingAloud
            VStack(alignment: .leading, spacing: 0) {
                if let seconds = NanoMuseTurnTimes.elapsed(message, session: session) {
                    Text(String(format: AppLocalized("Turn time %@"), NanoMuseTurnTimes.format(seconds)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    NanoMuseAnchorButton(session: session, messageId: NanoMuseMessageKey.of(message))
                    icon(copied ? "checkmark" : "doc.on.doc", AppLocalized("Copy")) {
                        UIPasteboard.general.string = markdown
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    icon(isReading ? "stop.circle" : "speaker.wave.2", isReading ? AppLocalized("Stop reading") : AppLocalized("Read aloud")) {
                        if isReading {
                            vm.stopSpeech()
                            reading.messageId = nil
                        } else {
                            reading.messageId = message.id
                            vm.readReplyFromStart(message)
                        }
                    }
                    if latest, let question {
                        icon("arrow.clockwise", AppLocalized("Answer again"), enabled: !vm.isProcessing) {
                            vm.retryFromMessage(question.id)
                        }
                    }
                    icon("arrow.triangle.branch", AppLocalized("Branch from here"), enabled: !vm.isProcessing && !branching) {
                        branch(question: question)
                    }
                    Menu {
                        Button {
                            NanoMuseChatSheets.shared.open(.shareImage(question: question?.content, answer: markdown), session: session)
                        } label: {
                            Label(AppLocalized("Share as image"), systemImage: "photo")
                        }
                        Button {
                            NanoMuseChatSheets.shared.open(.shareText(markdown), session: session)
                        } label: {
                            Label(AppLocalized("Share as text"), systemImage: "text.alignleft")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15))
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(AppLocalized("Share")))
                    Spacer(minLength: 0)
                }
                if branchFailed {
                    Text(AppLocalized("Could not make the branch"))
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    /// The person's message this reply answers.
    private var question: ChatMessage? {
        guard let at = vm.messages.firstIndex(where: { $0.id == message.id }), at > 0 else { return nil }
        return vm.messages[..<at].last { $0.role == .user }
    }

    private func icon(_ symbol: String, _ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.secondary.opacity(enabled ? 1 : 0.4))
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }

    /// Named after the question that led here; the chat's own title says little about one turn.
    private func branch(question: ChatMessage?) {
        guard let session = vm.sessionId else {
            branchFailed = true
            return
        }
        branching = true
        branchFailed = false
        let topic = String((question?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        let title = topic.isEmpty ? AppLocalized("Branch") : String(format: AppLocalized("%@ (branch)"), topic)
        let messages = vm.messages
        let reply = message
        Task { @MainActor in
            let made = await NanoMuseChatBranch.create(session: session, messages: messages, reply: reply, title: title)
            branching = false
            if let made {
                NotificationCenter.default.post(name: .nanoMuseOpenChat, object: made)
            } else {
                branchFailed = true
            }
        }
    }
}
