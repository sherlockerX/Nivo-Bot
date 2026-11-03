//
//  NanoMuseChatSheets.swift
//  nanoMuse
//
//  The chat's sheets of ours: a reply's steps, the conversation anchors, a reply shared as a
//  picture or as text. The message list's cells are hosted by UIKit and cannot present a sheet
//  that outlives cell reuse, so they ask here, and the chat that is asked shows it from
//  NanoMuseChatHooks: one link on that modifier, none on `AIChatView.body`.
//

import SwiftUI

@MainActor
final class NanoMuseChatSheets: ObservableObject {
    static let shared = NanoMuseChatSheets()

    enum Kind {
        case steps(UUID)
        case anchors
        case shareImage(question: String?, answer: String)
        case shareText(String)
    }

    struct Request: Identifiable {
        let id = UUID()
        /// The chat it is for (`nmSessionKey`); nil for a reply's steps, which go to the chat
        /// that holds the reply (a cell knows its message, not its chat).
        let session: String?
        let kind: Kind
    }

    @Published var request: Request?

    func open(_ kind: Kind, session: String) {
        request = Request(session: session, kind: kind)
    }

    /// The fold line under a reply was tapped.
    func openSteps(_ messageId: UUID) {
        request = Request(session: nil, kind: .steps(messageId))
    }

    private func isFor(_ vm: AIChatViewModel) -> Bool {
        guard let request else { return false }
        if let session = request.session { return session == vm.nmSessionKey }
        if case .steps(let id) = request.kind { return vm.messages.contains { $0.id == id } }
        return false
    }

    /// The request when it is this chat's.
    func binding(for vm: AIChatViewModel) -> Binding<Request?> {
        Binding(
            get: { [weak self] in (self?.isFor(vm) == true) ? self?.request : nil },
            set: { [weak self] value in if value == nil, self?.isFor(vm) == true { self?.request = nil } }
        )
    }
}

/// What a request shows.
struct NanoMuseChatSheetContent: View {
    let request: NanoMuseChatSheets.Request
    let vm: AIChatViewModel

    var body: some View {
        switch request.kind {
        case .steps(let id):
            if let message = vm.messages.first(where: { $0.id == id }) {
                NanoMuseStepsSheet(message: message, vm: vm)
            }
        case .anchors:
            NanoMuseAnchorsSheet(vm: vm)
        case .shareImage(let question, let answer):
            NanoMuseReplyShareSheet(question: question, answer: answer)
        case .shareText(let text):
            NanoMuseShareSheet(items: [text])
        }
    }
}
