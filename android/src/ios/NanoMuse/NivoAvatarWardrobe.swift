import SwiftUI
import UIKit

/// 形象文件事务在工作线程执行，账户切换等待事务结束后才搬移目录。
@MainActor
final class NivoAvatarWardrobe: ObservableObject {
    static let shared = NivoAvatarWardrobe()
    @Published private(set) var pets: [NivoAvatarWardrobeFiles.Pet] = []
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var isBusy = false
    @Published var error: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let files = NivoAvatarWardrobeFiles(root: NanoMuseFaceStore.directory)

    /// 账户生命周期先清空可见数据，然后等待已开始的文件操作。
    func prepareAccountChange() async {
        pets = []
        thumbnails = [:]
        if isBusy { await withCheckedContinuation { waiters.append($0) } }
    }

    /// 页面进入时修复中断并读取缩略图，失败保留磁盘原件。
    func reload() async {
        do { try await operate(reloadsFace: false) { files in try files.recover() } }
        catch { self.error = NivoLifeModel.message(error) }
    }

    /// 生成或同步的新形象先编码，再通过可回滚事务安装。
    func replace(stills: [NanoMuseMood: UIImage], faceID: String? = nil,
                 description: String, style: String, sync: Bool = true) async throws {
        guard let idle = stills[.idle] else { throw NivoLifeError.invalidField("avatar_idle") }
        var values: [String: Data] = [:]
        for (mood, image) in stills {
            guard let data = NanoMuseFaceStore.square(image, side: 512).pngData() else {
                throw NivoLifeError.invalidField("avatar_image")
            }
            values[mood.rawValue + ".png"] = data
        }
        let digest = NanoMuseFaceStore.faceId(of: NanoMuseFaceStore.encodeStill(NanoMuseFaceStore.square(idle, side: 512)) ?? Data())
        let metadata = NanoMuseFaceStore.Meta(description: description, style: style,
            createdAt: Date().timeIntervalSince1970, faceId: faceID ?? digest)
        values["meta.json"] = try JSONEncoder().encode(metadata)
        let payload = values
        try await operate { files in try files.replace(with: payload) }
        if sync { NanoMuseProfileSync.shared.faceChanged() }
    }

    /// 远端表情形象同样保留之前的自绘形象。
    func replace(emoji: NanoMuseEmojiLook) async throws {
        let data = try JSONEncoder().encode(emoji)
        try await operate { files in try files.replace(with: ["emoji.json": data]) }
    }

    /// 穿回已存形象或内置形象，只修改当前账户的本地文件。
    func wear(_ identifier: String, sync: Bool = true) async throws {
        try await operate { files in try files.wear(identifier) }
        if sync { NanoMuseProfileSync.shared.faceChanged() }
    }

    /// 删除需要由界面确认，仅删除衣柜副本。
    func remove(_ identifier: String) async throws {
        try await operate { files in try files.remove(identifier) }
    }

    private func operate(reloadsFace: Bool = true, _ operation: @escaping @Sendable (NivoAvatarWardrobeFiles) throws -> Void) async throws {
        guard !isBusy, !NanoMuseAccountData.shared.isChangingAccount else { throw NivoPersonalBackupError.busy }
        let generation = NanoMuseAccountData.shared.generation
        let owner = NanoMuseAccountData.shared.current
        isBusy = true
        error = nil
        if reloadsFace { NanoMuseAvatarMotion.shared.cancel() }
        defer {
            isBusy = false
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
        let storage = files
        let result = try await Task.detached {
            let wasInterrupted = FileManager.default.fileExists(atPath: storage.root.appendingPathComponent(".wardrobe-rollback").path)
            try operation(storage)
            let pets = try storage.list()
            let images = try Dictionary(uniqueKeysWithValues: pets.map { ($0.id, try storage.thumbnail($0.id)) })
            return (pets, images, wasInterrupted)
        }.value
        guard NanoMuseAccountData.shared.current == owner, NanoMuseAccountData.shared.generation == generation,
              !NanoMuseAccountData.shared.isChangingAccount else { throw NivoLifeError.accountChanged }
        if reloadsFace || result.2 { NanoMuseFaceStore.shared.reload() }
        pets = result.0
        thumbnails = result.1.compactMapValues { UIImage(data: $0) }
    }
}

/// 衣柜使用系统列表、选择标记和删除确认，与现有形象工坊共用页面层级。
struct NivoAvatarWardrobeView: View {
    @ObservedObject private var wardrobe = NivoAvatarWardrobe.shared
    @ObservedObject private var studio = NanoMuseAvatarStudioModel.shared
    @ObservedObject private var faces = NanoMuseFaceStore.shared
    @State private var deleting: NivoAvatarWardrobeFiles.Pet?

    var body: some View {
        List {
            Button { wear("dragon") } label: {
                HStack {
                    if let image = NanoMuseFaceStore.dragon(.idle) {
                        Image(uiImage: image).resizable().scaledToFit().frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Image(systemName: "sparkles").frame(width: 48, height: 48)
                    }
                    Text(AppLocalized("Shiqi"))
                    Spacer()
                    if faces.source == .dragon { Image(systemName: "checkmark") }
                }
            }
            ForEach(wardrobe.pets) { pet in
                Button { wear(pet.id) } label: {
                    HStack(spacing: 12) {
                        if let image = wardrobe.thumbnails[pet.id] {
                            Image(uiImage: image).resizable().scaledToFit().frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        Text(pet.description.isEmpty ? AppLocalized("Saved face") : pet.description)
                            .foregroundStyle(.primary)
                    }
                }
                .swipeActions { Button(AppLocalized("Delete"), role: .destructive) { deleting = pet } }
            }
            if wardrobe.isBusy { ProgressView() }
            if let error = wardrobe.error { Text(error).foregroundStyle(.red) }
        }
        .disabled(wardrobe.isBusy || studio.isBusy)
        .navigationTitle(AppLocalized("Avatar wardrobe"))
        .task { await wardrobe.reload() }
        .confirmationDialog(AppLocalized("Delete this saved face?"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            if let pet = deleting {
                Button(AppLocalized("Delete"), role: .destructive) {
                    Task { do { try await wardrobe.remove(pet.id) } catch { wardrobe.error = NivoLifeModel.message(error) } }
                }
            }
        }
    }

    private func wear(_ identifier: String) {
        Task {
            do { try await wardrobe.wear(identifier) }
            catch { wardrobe.error = NivoLifeModel.message(error) }
        }
    }
}
