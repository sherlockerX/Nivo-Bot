//
//  NanoMuseReplyShare.swift
//  nanoMuse
//
//  A reply as a picture, as in the Android build (ui/chat/NmReplyShare.kt). The preview is the
//  picture: the agent's face and name, the date, the question, the answer and a "Written by AI"
//  line, always on white so it reads the same wherever it is sent. Share hands it to the system
//  sheet, which also saves it to Photos.
//

import SwiftUI
import UIKit

struct NanoMuseReplyShareSheet: View {
    var question: String?
    var answer: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var picture: NanoMuseSharedPicture?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                card
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea())
            .navigationTitle(AppLocalized("Share as image"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(AppLocalized("Close")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Share")) { render() } }
            }
            .alert(AppLocalized("Could not make the image"), isPresented: $failed) {
                Button(AppLocalized("OK"), role: .cancel) {}
            }
        }
        .sheet(item: $picture) { p in NanoMuseShareSheet(items: [p.image]) }
    }

    private var card: some View {
        NanoMuseReplyCard(
            name: NanoMuseHomeView.currentAgentName(),
            face: NanoMuseFaceStore.shared.image(for: .idle),
            date: Date().formatted(date: .long, time: .omitted),
            question: question,
            answer: answer
        )
        .environment(\.colorScheme, .light)
    }

    /// The card as an image, at the screen's scale unless that would make it too large to hold.
    private func render() {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        guard let measured = renderer.uiImage, measured.size.width > 0, measured.size.height > 0 else {
            failed = true
            return
        }
        let points = Double(measured.size.width * measured.size.height)
        let cap = CGFloat((16_000_000 / points).squareRoot())
        renderer.scale = min(displayScale, max(1, cap))
        guard let image = renderer.uiImage else {
            failed = true
            return
        }
        picture = NanoMuseSharedPicture(image: image)
    }
}

/// A picture waiting for the share sheet.
struct NanoMuseSharedPicture: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// The card itself, 360 pt wide: face and name with the date, the question in a bubble on the
/// right, the answer, and the footer.
struct NanoMuseReplyCard: View {
    var name: String
    var face: UIImage?
    var date: String
    var question: String?
    var answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Group {
                    if let face {
                        Image(uiImage: face).resizable().scaledToFill()
                    } else {
                        Color(uiColor: .secondarySystemBackground)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text(date).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let question = question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
                HStack {
                    Spacer(minLength: 40)
                    Text(question)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(NanoMuseTones.bubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.top, 18)
            }
            NanoMuseInlineMarkdown(text: answer)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            Text(AppLocalized("Written by AI"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 22)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(width: 360, alignment: .leading)
        .background(Color.white)
    }
}
