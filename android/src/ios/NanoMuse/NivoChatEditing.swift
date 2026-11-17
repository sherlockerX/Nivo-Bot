import Foundation
import Combine

/// 聊天编辑先完成数据库事务，再发布界面变化或启动新的模型请求。
extension AIChatViewModel {
    /// 优先使用来源ID定位用户回合，旧的未标注界面才按真实用户气泡计数。
    func nmUserHistoryIndex(at index: Int) throws -> Int {
        guard messages.indices.contains(index), messages[index].role == .user else {
            throw NivoChatMutationError.staleHistory
        }
        let sourceIDs = messages[index].nmSourceMessageIDs
        if !sourceIDs.isEmpty {
            let matches = agentHistory.indices.filter { position in
                guard let identifier = agentHistory[position].dbMessageId else { return false }
                return sourceIDs.contains(identifier) && Self.isUserBubbleEntry(agentHistory[position])
            }
            guard matches.count == 1, let match = matches.first else { throw NivoChatMutationError.staleHistory }
            return match
        }
        let ordinal = messages.prefix(index + 1).filter { $0.role == .user }.count
        let indices = agentHistory.indices.filter { Self.isUserBubbleEntry(agentHistory[$0]) }
        guard ordinal > 0, indices.count >= ordinal else { throw NivoChatMutationError.staleHistory }
        return indices[ordinal - 1]
    }

    /// 编辑发送保留当前草稿，落盘失败时不清输入、不删消息，也不调用模型。
    func nmSendEditedMessage(scheduledRunID: String?, userOrigin: NivoUserTurnOrigin? = nil) {
        guard let index = editingMessageIndex else { return }
        do {
            let historyIndex = try nmUserHistoryIndex(at: index)
            let retained = Array(agentHistory.prefix(historyIndex))
            nmCommitHistoryEdit(retaining: retained, scheduledRunID: scheduledRunID, apply: { _ in
                self.messages.removeSubrange(index...)
                self.editingMessageIndex = nil
            }, continueAfterCommit: {
                self.send(scheduledRunID: scheduledRunID, userOrigin: userOrigin)
            })
        } catch { errorMessage = NivoLifeModel.message(error) }
    }

    /// 编辑占位跨越异步写入，调度重试复用自己的真实租约，不借用别的任务身份。
    func nmCommitHistoryEdit(retaining history: [AgentMessage], trimmedToolUseID: String? = nil,
                             replacingAttachments: [InputAttachment]? = nil, scheduledRunID: String? = nil,
                             apply: @escaping ([AttachmentMeta]?) -> Void,
                             continueAfterCommit: @escaping () -> Void = {}) {
        guard !isProcessing, !isTruncatingForRetry, !isLoadingSession, !isCompacting, remoteDeviceId == nil else { return }
        let capturedSession = sessionId
        let capturedAccount = NanoMuseAccountData.shared.current
        let visibleIDs = messages.map(\.id)
        let expectedIDs = agentHistory.compactMap(\.dbMessageId)
        let token: UUID?
        do {
            try NivoChatAccountAccess.require(sessionID: capturedSession, scheduledRunID: scheduledRunID)
            if let capturedSession {
                token = try NivoChatAccountAccess.beginConversationEdit([capturedSession], scheduledRunID: scheduledRunID)
            } else {
                token = try NivoChatAccountAccess.beginSynchronizedEdit([capturedSession ?? "draft-edit-" + UUID().uuidString])
            }
        } catch { errorMessage = NivoLifeModel.message(error); return }
        isTruncatingForRetry = true
        currentTask = Task { @MainActor in
            var staged: NivoChatEditAttachments?
            var committed = false
            defer {
                if let token { NivoScheduledRunScopes.shared.endConversationEdit(token) }
                self.isTruncatingForRetry = false
                if !committed { staged?.discard() }
            }
            do {
                try Task.checkCancellation()
                guard self.sessionId == capturedSession, NanoMuseAccountData.shared.current == capturedAccount else {
                    throw NivoLifeError.accountChanged
                }
                var retained = history
                if let replacingAttachments, !replacingAttachments.isEmpty {
                    guard let capturedSession, !retained.isEmpty else { throw NivoChatMutationError.staleHistory }
                    let replacement = try NivoChatEditAttachments.stage(replacingAttachments, model: self, sessionID: capturedSession)
                    staged = replacement
                    retained[retained.count - 1].parts.removeAll(where: NivoChatEditAttachments.isAttachment)
                    retained[retained.count - 1].parts += replacement.agentParts
                }
                if let capturedSession {
                    try await ChatStore.shared.nmTruncateChat(sessionID: capturedSession, expectedMessageIDs: expectedIDs,
                        retainedMessageIDs: retained.compactMap(\.dbMessageId), trimmedToolUseID: trimmedToolUseID,
                        replacementParts: staged?.storedParts, replacesAttachments: staged != nil)
                }
                committed = true
                guard self.sessionId == capturedSession, NanoMuseAccountData.shared.current == capturedAccount else {
                    throw NivoLifeError.accountChanged
                }
                guard self.messages.map(\.id) == visibleIDs else { throw NivoChatMutationError.staleHistory }
                self.agentHistory = retained
                self.cachedLatestMarker = nil
                self.canResume = false
                apply(staged?.metas)
                self.messages.removeAll { $0.role == .compactDivider }
                for message in self.messages { message.isCompactedHistory = false }
                self.rebuildToolSnapshotsFromMessages()
                if !self.transitionSuspended { self.objectWillChange.send() }
                self.retrySnapshotReloadSignal.send()
                if let replacingAttachments { Self.cleanupAttachmentFiles(replacingAttachments) }
                // 新请求会重新检查占位，先释放本次编辑；这里到启动之间没有异步交接。
                if let token { NivoScheduledRunScopes.shared.endConversationEdit(token) }
                self.isTruncatingForRetry = false
                guard !Task.isCancelled else { return }
                try NivoChatAccountAccess.require(sessionID: capturedSession, scheduledRunID: scheduledRunID)
                self.userDidCancel = false
                continueAfterCommit()
            } catch is CancellationError {
                // 进入数据库前取消会拒绝写入；已提交的结果继续由界面加载恢复。
            } catch {
                if self.sessionId == capturedSession { self.errorMessage = NivoLifeModel.message(error) }
                if committed {
                    Task { @MainActor in await self.reloadMessagesFromDB(reason: "localEditCommitted") }
                }
            }
        }
    }
}

/// 重试附件先保存到本次拥有的新文件，数据库失败只撤销新副本，不删除用户原选择。
struct NivoChatEditAttachments {
    let agentParts: [AgentContentPart]
    let storedParts: [ContentPart]
    let metas: [AttachmentMeta]
    let copiedFiles: [URL]
    let mediaDirectory: URL

    /// 保留原正文，移除旧的附件元数据及内联图片。
    static func isAttachment(_ part: AgentContentPart) -> Bool {
        switch part {
        case .imageData: return true
        case .text(let text): return isAttachmentText(text)
        default: return false
        }
    }

    /// 仅识别宿主生成的独立附件块，普通正文中的引用不会因此整段消失。
    static func isAttachmentText(_ text: String) -> Bool {
        text.hasPrefix("<user-attached-files>") || text.hasPrefix("[attached image: ")
            || text.hasPrefix("<system-reminder>Only ") || text.hasPrefix("[image omitted")
    }

    /// 复用附件预处理，要求每个选中文件均成功复制，图像副本写盘失败向外抛出。
    @MainActor
    static func stage(_ attachments: [InputAttachment], model: AIChatViewModel,
                      sessionID: String) throws -> Self {
        let manager = FileManager.default
        let uploads = AIChatViewModel.minisUploadsDir(for: sessionID)
        try manager.createDirectory(at: uploads, withIntermediateDirectories: true)
        let prepared = model.processAttachments(attachments, uploadsDir: uploads,
            nowStr: ISO8601DateFormatter().string(from: Date()))
        let copies = prepared.metas.map { uploads.appendingPathComponent($0.fileName) }
        let directoryName = "retry-" + UUID().uuidString
        let relativeDirectory = sessionID + "/attachments/" + directoryName
        let directory = ChatStore.shared.minisBaseURL.appendingPathComponent(relativeDirectory, isDirectory: true)
        do {
            guard prepared.metas.count == attachments.count else { throw CocoaError(.fileWriteUnknown) }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            var stored: [ContentPart] = []
            for part in prepared.parts {
                switch part {
                case .text(let value): stored.append(.text(value))
                case .imageData(let data, let mime, let linuxPath):
                    let name = UUID().uuidString
                    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                    stored.append(.mediaRef(MediaRef(id: name, relativePath: relativeDirectory + "/" + name,
                        mimeType: mime, originalFileName: nil, linuxPath: linuxPath)))
                default: throw NivoChatMutationError.invalidRequest
                }
            }
            return .init(agentParts: prepared.parts, storedParts: stored, metas: prepared.metas,
                         copiedFiles: copies, mediaDirectory: directory)
        } catch {
            for file in copies { try? manager.removeItem(at: file) }
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    /// 只清理本次生成的唯一目录和拷贝，原聊天的附件继续保留。
    func discard() {
        for file in copiedFiles { try? FileManager.default.removeItem(at: file) }
        try? FileManager.default.removeItem(at: mediaDirectory)
    }
}
