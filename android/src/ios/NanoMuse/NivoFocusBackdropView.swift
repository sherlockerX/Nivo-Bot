import SwiftUI
import PhotosUI
import UIKit

/// 默认景观完全由矢量路径绘制，用户照片只在本机私有目录读取。
struct NivoFocusBackdropView: View {
    var backgroundID: String
    var ownerKey: String
    var thumbnail = false
    @ObservedObject private var life = NivoLifeModel.shared
    @State private var image: UIImage?
    private var loadIdentity: String { ownerKey + ":" + backgroundID + ":" + String(life.accessScope?.generation ?? 0) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                NivoFocusLandscape()
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            }
        }
        .accessibilityHidden(true)
        .task(id: loadIdentity) {
            image = nil
            guard !backgroundID.isEmpty, let scope = life.accessScope, scope.ownerKey == ownerKey,
                  let data = try? await NivoFocusBackgroundStore.shared.imageData(id: backgroundID, scope: scope, thumbnail: thumbnail),
                  !Task.isCancelled, life.accessScope == scope else { return }
            image = UIImage(data: data)
        }
    }
}

/// 山峦和湖面提供低刺激背景，配色在照片导入前也能清楚衬托时钟。
private struct NivoFocusLandscape: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 0.17, green: 0.29, blue: 0.32),
                                        Color(red: 0.52, green: 0.65, blue: 0.61)],
                               startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(red: 0.95, green: 0.88, blue: 0.68).opacity(0.8))
                    .frame(width: width * 0.16, height: width * 0.16)
                    .position(x: width * 0.72, y: height * 0.28)
                ForEach(0..<3) { layer in
                    Path { path in
                        let base = height * (0.52 + Double(layer) * 0.12)
                        path.move(to: CGPoint(x: 0, y: base))
                        path.addCurve(to: CGPoint(x: width, y: base + height * 0.09),
                                      control1: CGPoint(x: width * 0.35, y: base - height * 0.22),
                                      control2: CGPoint(x: width * 0.55, y: base + height * 0.18))
                        path.addLine(to: CGPoint(x: width, y: height))
                        path.addLine(to: CGPoint(x: 0, y: height))
                        path.closeSubpath()
                    }.fill(Color(red: 0.13, green: 0.30, blue: 0.29).opacity(0.25 + Double(layer) * 0.14))
                }
            }
        }
    }
}

/// 原生照片选择器无需整库权限，多图导入可逐张显示成功或失败。
struct NivoFocusBackgroundPicker: View {
    var scope: NivoLifeScope
    @Binding var selectedID: String
    @Environment(\.dismiss) private var dismiss
    @State private var backgrounds: [NivoFocusBackground] = []
    @State private var picks: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var deleting: NivoFocusBackground?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(AppLocalized("Choose a background before each session. Photos stay on this device."))
                        .font(.subheadline).foregroundStyle(.secondary)
                    PhotosPicker(selection: $picks, maxSelectionCount: max(1, 24 - backgrounds.count), matching: .images) {
                        Label(AppLocalized("Import backgrounds"), systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity).padding(12)
                    }.buttonStyle(.borderedProminent).disabled(isImporting || backgrounds.count >= 24)
                    if isImporting { ProgressView(AppLocalized("Importing backgrounds")) }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.subheadline) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 14) {
                        tile(id: "", title: AppLocalized("Quiet landscape"))
                        ForEach(backgrounds) { background in
                            tile(id: background.id, title: background.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .contextMenu { Button(AppLocalized("Delete"), role: .destructive) { deleting = background } }
                        }
                    }
                    Text(AppLocalized("Up to 24 backgrounds. Touch and hold a photo to delete it."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
            .navigationTitle(AppLocalized("Focus backgrounds")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { dismiss() } } }
            .task { await reload() }
            .nmOnChange(of: picks) { selection in
                guard !selection.isEmpty, !isImporting else { return }
                Task { await importPhotos(selection) }
            }
            .confirmationDialog(AppLocalized("Delete this background?"), isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible) {
                if let deleting { Button(AppLocalized("Delete"), role: .destructive) { Task { await remove(deleting) } } }
            }
            .interactiveDismissDisabled(isImporting)
            .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in dismiss() }
        }
    }

    private func tile(id: String, title: String) -> some View {
        Button { select(id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                NivoFocusBackdropView(backgroundID: id, ownerKey: scope.ownerKey, thumbnail: true).frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(alignment: .topTrailing) {
                        if selectedID == id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor)
                                .font(.title2).padding(10)
                        }
                    }
                Text(title).font(.caption).foregroundStyle(.primary)
            }
        }.buttonStyle(.plain).accessibilityAddTraits(selectedID == id ? .isSelected : [])
    }

    private func reload() async {
        do { backgrounds = try await NivoFocusBackgroundStore.shared.list(scope: scope) }
        catch { errorMessage = NivoLifeModel.message(error) }
    }

    /// 显式选择才写偏好，载入页面或旧账号迟到回调不能覆盖新账号的选择。
    private func select(_ id: String) {
        guard NivoLifeModel.shared.accessScope == scope else { return }
        NivoFocusPreferences.setBackground(id, owner: scope.ownerKey)
        selectedID = id
    }

    private func importPhotos(_ selection: [PhotosPickerItem]) async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false; picks = [] }
        for item in selection {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw NivoFocusBackgroundError.unreadable
                }
                let imported = try await NivoFocusBackgroundStore.shared.add(data, scope: scope)
                select(imported.id)
            } catch {
                errorMessage = Self.describe(error)
                break
            }
        }
        await reload()
    }

    private func remove(_ item: NivoFocusBackground) async {
        do {
            try await NivoFocusBackgroundStore.shared.remove(item, scope: scope)
            if selectedID == item.id { select("") }
            await reload()
        } catch { errorMessage = Self.describe(error) }
    }

    private static func describe(_ error: Error) -> String {
        switch error as? NivoFocusBackgroundError {
        case .full: return AppLocalized("The background library is full. Delete a photo before importing another.")
        case .tooLarge: return AppLocalized("Choose a photo smaller than 32 MB.")
        case .unreadable: return AppLocalized("This photo could not be opened. Choose another photo.")
        case nil: return NivoLifeModel.message(error)
        }
    }
}
