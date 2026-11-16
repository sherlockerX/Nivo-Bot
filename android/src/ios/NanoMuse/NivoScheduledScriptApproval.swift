import SwiftUI
import UIKit

/// 脚本没有可证明的只读边界，须确认完整快照；授权按账户、任务和内容摘要保存。
@MainActor
final class NivoScheduledScriptApproval {
    static let shared = NivoScheduledScriptApproval()

    private struct Request {
        let id: UUID
        let taskID: String
        let label: String
        let version: NivoScheduledScriptVersion
        let generation: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var requests: [Request] = []
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var presentationTask: Task<Void, Never>?
    private var controller: UIViewController?
    private var presentedID: UUID?
    private var file: URL { NanoMuseDirs.root.appendingPathComponent("routine-script-approvals.json") }

    /// 同一内容及参数可由用户记住；正文、参数或账户一变就重新确认。
    func authorize(taskID: String, label: String, version: NivoScheduledScriptVersion, generation: UInt64) async throws {
        try requireCurrent(generation)
        if try grants()[taskID] == version.digest { return }
        let id = UUID()
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                requests.append(Request(id: id, taskID: taskID, label: label, version: version,
                    generation: generation, continuation: continuation))
                timers[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finish(id, allowed: false)
                }
                presentNext()
            }
        } onCancel: { Task { @MainActor in self.finish(id, allowed: false) } }
        try requireCurrent(generation)
        guard accepted else { throw NivoLifeError.invalidField("SCRIPT_APPROVAL_DENIED") }
    }

    /// 撤销任务的固定版本授权，随后每次运行重新显示确认。
    func revoke(taskID: String) throws {
        var saved = try grants()
        saved.removeValue(forKey: taskID)
        try save(saved)
    }

    private func answer(_ request: Request, allowed: Bool, remember: Bool) -> String? {
        guard requests.contains(where: { $0.id == request.id }) else { return nil }
        do {
            try requireCurrent(request.generation)
            if allowed, remember {
                var saved = try grants()
                saved[request.taskID] = request.version.digest
                try save(saved)
            }
            finish(request.id, allowed: allowed)
            return nil
        } catch { return error.localizedDescription }
    }

    private func finish(_ id: UUID, allowed: Bool) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        let request = requests.remove(at: index)
        timers.removeValue(forKey: id)?.cancel()
        request.continuation.resume(returning: allowed)
        guard presentedID == id else { presentNext(); return }
        presentedID = nil
        let previous = controller
        controller = nil
        previous?.dismiss(animated: true) { [weak self] in self?.presentNext() }
    }

    /// 直接从当前最上层页面呈现，编辑页或历史页已打开时也能看到审批。
    private func presentNext() {
        guard controller == nil, presentationTask == nil, !requests.isEmpty else { return }
        presentationTask = Task { [weak self] in
            defer { self?.presentationTask = nil }
            while let self, let request = self.requests.first, self.controller == nil {
                if let top = self.topController(), !top.isBeingPresented, !top.isBeingDismissed {
                    let view = NivoScheduledScriptApprovalView(label: request.label, version: request.version) { allow, remember in
                        self.answer(request, allowed: allow, remember: remember)
                    }
                    let host = UIHostingController(rootView: view)
                    host.isModalInPresentation = true
                    host.sheetPresentationController?.detents = [.medium(), .large()]
                    self.controller = host
                    self.presentedID = request.id
                    top.present(host, animated: true)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
        }
    }

    private func topController() -> UIViewController? {
        guard UIApplication.shared.applicationState == .active,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top.viewIfLoaded?.window == nil ? nil : top
    }

    private func requireCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation()
        let account = NanoMuseAccountData.shared
        guard account.generation == generation, account.isReady, !account.isChangingAccount,
              !NivoPersonalBackupAccess.isBusy else { throw NivoLifeError.accountChanged }
    }

    private func grants() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? .max) <= 200_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
        guard saved.count <= 1_000, saved.values.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return saved
    }

    private func save(_ grants: [String: String]) throws {
        guard grants.count <= 1_000 else { throw NivoLifeError.invalidField("script_approvals") }
        try JSONEncoder().encode(grants).write(to: file, options: .atomic)
    }
}

/// 审批页展示实际被冻结的版本，确认按钮固定在底部，不被长代码推到屏幕之外。
private struct NivoScheduledScriptApprovalView: View {
    let label: String
    let version: NivoScheduledScriptVersion
    let answer: (Bool, Bool) -> String?
    @State private var remember = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section {
                        Text(label).font(.headline)
                        Text(version.script.guestPath).font(.footnote.monospaced()).textSelection(.enabled)
                        Text(AppLocalized("Review this script before allowing it to run. It may change files or use the network."))
                    }
                    if !version.script.arguments.isEmpty {
                        Section(AppLocalized("Arguments")) {
                            ForEach(Array(version.script.arguments.enumerated()), id: \.offset) { _, argument in
                                Text(argument.isEmpty ? "\"\"" : argument).font(.footnote.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                    Section {
                        DisclosureGroup(AppLocalized("Script content")) {
                            Text(version.body).font(.footnote.monospaced()).textSelection(.enabled)
                        }
                        Toggle(AppLocalized("Remember this version for this task"), isOn: $remember)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                HStack {
                    Button(AppLocalized("Deny"), role: .cancel) { error = answer(false, false) }.buttonStyle(.bordered)
                    Spacer()
                    Button(AppLocalized(remember ? "Allow this version" : "Allow once")) { error = answer(true, remember) }.buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .tint(NanoMuseTones.action)
            .navigationTitle(AppLocalized("Run script"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
