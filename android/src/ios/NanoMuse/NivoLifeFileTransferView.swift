import SwiftUI
import UniformTypeIdentifiers

/// 系统文件面板接收已经校验的JSON，不需要照片或网络权限。
struct NivoJSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= NivoTodoBackupCodec.maximumBytes else {
            throw NivoLifeError.invalidField("backup_size")
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// 任务支持双向文件迁移；专注沿用安卓的记录导出入口。
enum NivoLifeFileKind { case tasks, focus }

/// 文件选择、校验、明确确认和提交分开，取消操作不改变任务。
struct NivoLifeFileTransferView: View {
    let kind: NivoLifeFileKind
    let scope: NivoLifeScope
    @ObservedObject private var model = NivoLifeModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var document: NivoJSONFile?
    @State private var pendingImport: Data?
    @State private var importedTaskCount = 0
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { await prepareExport() }
                    } label: {
                        Label(AppLocalized(kind == .tasks ? "Export tasks" : "Export focus records"), systemImage: "square.and.arrow.up")
                    }
                    if kind == .tasks {
                        Button { isImporting = true } label: {
                            Label(AppLocalized("Import tasks"), systemImage: "square.and.arrow.down")
                        }
                    }
                } footer: {
                    Text(AppLocalized(kind == .tasks
                        ? "Import adds missing tasks and keeps tasks already on this device. Fragment links are restored only when the original fragment exists."
                        : "Export measured focus sessions and time spans. Exporting does not stop the current timer."))
                }
                if let pendingImport {
                    Section {
                        Text(String(format: AppLocalized("%d tasks ready to review"), importedTaskCount))
                        Button(AppLocalized("Import tasks")) { Task { await importTasks(pendingImport) } }
                            .buttonStyle(.borderedProminent)
                        Button(AppLocalized("Cancel"), role: .cancel) { self.pendingImport = nil }
                    }
                }
                if isWorking { ProgressView().accessibilityLabel(AppLocalized("Saving…")) }
                if let message { Section { Text(message).foregroundStyle(.secondary) } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .disabled(isWorking)
            .navigationTitle(AppLocalized(kind == .tasks ? "Task backup" : "Export focus records"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppLocalized("Done")) { dismiss() }.disabled(isWorking) } }
        }
        .interactiveDismissDisabled(isWorking)
        .fileExporter(isPresented: $isExporting, document: document, contentType: .json,
                      defaultFilename: kind == .tasks ? "nivo-tasks" : "nivo-focus") { result in
            document = nil
            guard model.accessScope == scope else { return }
            if case .failure(let failure) = result { error = NivoLifeModel.message(failure) }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json, .plainText, .data]) { result in
            switch result {
            case .success(let url): Task { await prepareImport(url) }
            case .failure(let failure): error = NivoLifeModel.message(failure)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nanoMuseAccountSwitched)) { _ in
            pendingImport = nil
            document = nil
            isImporting = false
            isExporting = false
            dismiss()
        }
    }

    @MainActor private func prepareExport() async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let selected = kind
            let data = try await model.performToolResult(scope: scope) { repository, captured, clock in
                if selected == .tasks { return try await repository.exportTasks(scope: captured, clock: clock) }
                return try await repository.exportFocus(scope: captured, clock: clock)
            }
            guard model.accessScope == scope else { return }
            document = NivoJSONFile(data: data)
            isExporting = true
        } catch { self.error = NivoLifeModel.message(error) }
    }

    @MainActor private func prepareImport(_ url: URL) async {
        guard !isWorking, model.accessScope == scope else { return }
        isWorking = true
        error = nil
        message = nil
        pendingImport = nil
        defer { isWorking = false }
        do {
            let owner = scope.ownerKey
            let clock = NivoLifeClock.sample()
            let today = NivoLifeDay.value()
            let prepared = try await Task.detached {
                let data = try Self.readFile(url)
                let decoded = try NivoTodoBackupCodec.decode(data, owner: owner, now: clock.wallMs, today: today)
                return (data, decoded.tasks.count)
            }.value
            guard model.accessScope == scope else { return }
            pendingImport = prepared.0
            importedTaskCount = prepared.1
        } catch { self.error = NivoLifeModel.message(error) }
    }

    @MainActor private func importTasks(_ data: Data) async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let today = NivoLifeDay.value()
            let result = try await model.performToolResult(scope: scope) { repository, captured, clock in
                try await repository.importTasks(data, scope: captured, now: clock.wallMs, today: today)
            }
            guard model.accessScope == scope else { return }
            pendingImport = nil
            message = String(format: AppLocalized("%d tasks imported, %d kept on this device, %d missing fragment links skipped."),
                             result.imported, result.keptLocal, result.missingEntries)
            NotificationCenter.default.post(name: .nivoMosaicStateChanged, object: scope.ownerKey)
        } catch { self.error = NivoLifeModel.message(error) }
    }

    /// 有界读取不信任文件提供者报告的大小，不能一次分配任意大的数据。
    nonisolated private static func readFile(_ url: URL) throws -> Data {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= NivoTodoBackupCodec.maximumBytes {
            let next = try handle.read(upToCount: min(65_536, NivoTodoBackupCodec.maximumBytes + 1 - data.count)) ?? Data()
            if next.isEmpty { return data }
            data.append(next)
        }
        throw NivoLifeError.invalidField("backup_size")
    }
}
