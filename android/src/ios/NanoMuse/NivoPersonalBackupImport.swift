import Foundation

extension BackupImporter {
    /// 所有模型、文件和聊天归属检查成功后才提交，失败由外层恢复整个账户快照。
    func importPersonalData(root: URL, fileIndex: [BackupFileIndexEntry]) async throws -> CategoryReport {
        guard let lease = personalLease else { throw NivoPersonalBackupError.busy }
        let document = try NivoPersonalBackupFiles.read(root: root)
        let localRoutines = try NivoRoutineArchive.read(NivoRoutineBackupFiles.routineFile)
        let mergedRoutines = try document.routines?.merging(into: localRoutines)
        // 先做纯值合并，避免内容冲突时已经写入图片。
        _ = try NivoPersonalBackupMerge.life(local: lease.life, incoming: document.life, owner: lease.ownerKey)
        let combinedCoach = try NivoPersonalBackupMerge.coach(local: lease.coach, incoming: document.coach)
        try await validateCoachChatOwners(combinedCoach, owner: lease.ownerKey)
        let coach = try await verifyingSources(combinedCoach)
        let images = try NivoPersonalBackupFiles.restoreImages(document: document, root: root,
            index: fileIndex, owner: lease.ownerKey)
        let filtered = NivoPersonalBackupFiles.droppingMissingImages(document, missing: images.missing, local: lease.life)
        let life = try NivoPersonalBackupMerge.life(local: lease.life, incoming: filtered.life, owner: lease.ownerKey)
        let backgrounds = try NivoPersonalBackupFiles.mergeBackgrounds(filtered.backgrounds, owner: lease.ownerKey)
        let archives = try mergedArchives(local: lease.archives, incoming: document.archives,
            coach: coach, owner: lease.ownerKey, originalOwner: document.life.ownerKey)
        var routineFiles = NivoRoutineBackupFiles.Restored()
        if let incoming = document.routines, let mergedRoutines {
            routineFiles = try NivoRoutineBackupFiles.restore(incoming, root: root, entries: fileIndex)
            // 不从包中恢复审批；即使本机残留同ID旧授权，新导入的任务也必须重新确认。
            try await MainActor.run {
                for identifier in mergedRoutines.importedIDs { try NivoScheduledScriptApproval.shared.revoke(taskID: identifier) }
            }
            try NivoRoutineArchive.write(mergedRoutines.routines, to: NivoRoutineBackupFiles.routineFile)
            if !FileManager.default.fileExists(atPath: NivoRoutineBackupFiles.settingsFile.path) {
                try NivoRoutineArchive.writeSettings(incoming.settings, to: NivoRoutineBackupFiles.settingsFile)
            }
        }
        try await NivoLifeModel.shared.repository.installBackup(life, token: lease.id)
        try await NivoCoachV2Store.shared.installBackup(coach, archives: archives, token: lease.id)
        if lease.selectedBackground.isEmpty,
           backgrounds.contains(where: { $0.id == document.selectedBackground }) {
            await MainActor.run { NivoFocusPreferences.setBackground(document.selectedBackground, owner: lease.ownerKey) }
        }
        var report = CategoryReport(category: BackupCategory.personalData.rawValue)
        report.imported = max(0, life.tasks.count - lease.life.tasks.count)
            + max(0, life.focusSessions.count - lease.life.focusSessions.count)
            + max(0, (life.mosaic?.entries.count ?? 0) - (lease.life.mosaic?.entries.count ?? 0))
            + max(0, coach.sessions.count - lease.coach.sessions.count)
            + (mergedRoutines?.importedIDs.count ?? 0)
        report.updated = changedCount(local: lease.life.tasks, merged: life.tasks)
            + changedCount(local: lease.life.focusSessions, merged: life.focusSessions)
        report.filesWritten = images.written + routineFiles.files
        report.bytesWritten = images.bytes + routineFiles.bytes
        report.unreadable += routineFiles.skipped
        report.keptLocalConflicts = (mergedRoutines?.conflicts ?? []) + routineFiles.conflicts
        report.importedPausedRoutines = mergedRoutines?.importedIDs.count ?? 0
        return report
    }

    /// 导入专题只能引用属于当前账户的聊天，不认领其他账户已有会话。
    private func validateCoachChatOwners(_ coach: NivoCoachState, owner: String) async throws {
        for chatID in Set(coach.topics.map(\.chatSessionID).filter { !$0.isEmpty }) {
            let belongs = await MainActor.run { () -> Bool in
                guard NivoPersonalBackupAccess.isBusy, NanoMuseAccountData.shared.current == owner else { return false }
                let existing = NanoMuseAccountData.shared.owner(of: chatID)
                return existing == nil || existing == owner
            }
            guard belongs else { throw NivoLifeError.accountChanged }
            if await ChatStore.shared.getSession(chatID) != nil {
                try await MainActor.run { try NanoMuseAccountData.shared.claim(chatID, owner: owner) }
            }
        }
    }

    /// 未随备份恢复的聊天不能继续充当掌握证据，保留原文供回顾并撤销相关结论。
    private func verifyingSources(_ original: NivoCoachState) async throws -> NivoCoachState {
        var checked = original
        for topic in original.topics where !topic.chatSessionID.isEmpty {
            let turns = original.sessions.filter { $0.topicID == topic.id }.flatMap(\.turns)
                .filter { !$0.sourceInvalidated && !$0.originMessageID.isEmpty }
            let grouped = Dictionary(grouping: turns, by: \.originMessageID)
            let bundle = try await ChatStore.shared.nmCoachSources(chatSessionID: topic.chatSessionID, identifiers: Set(grouped.keys))
            if !bundle.sessionExists {
                try NivoCoachHostRules.invalidateConversation(chatSessionID: topic.chatSessionID,
                    reason: "backup_source_missing", state: &checked)
            }
            let invalid = Set(grouped.compactMap { identifier, excerpts -> String? in
                guard let row = bundle.messages[identifier], row.sessionID == topic.chatSessionID else { return identifier }
                let matches = excerpts.allSatisfy { turn in
                    row.role == (turn.role == "user" ? "user" : "assistant") && row.text.contains(turn.text)
                        && (turn.sourceDigest == nil || row.digest == turn.sourceDigest)
                }
                return matches ? nil : identifier
            })
            if !invalid.isEmpty {
                try NivoCoachHostRules.invalidateMessages(chatSessionID: topic.chatSessionID, messageIDs: invalid, state: &checked)
            }
        }
        return checked
    }

    /// 队列只能携带现存课次和一致内容，重复条目沿用本机首次课次。
    private func mergedArchives(local: [NivoCoachArchiveEntry], incoming: [NivoCoachArchiveEntry],
                                coach: NivoCoachState, owner: String, originalOwner: String) throws -> [NivoCoachArchiveEntry] {
        var entries = Dictionary(uniqueKeysWithValues: local.map { ($0.chatID + ":" + $0.messageID, $0) })
        for var entry in incoming {
            guard entry.ownerKey == originalOwner,
                  coach.sessions.contains(where: { $0.id == entry.lessonID && $0.chatSessionID == entry.chatID }) else {
                throw NivoPersonalBackupError.invalidPackage
            }
            entry.ownerKey = owner
            let key = entry.chatID + ":" + entry.messageID
            if let previous = entries[key], previous != entry { throw NivoLifeError.operationConflict }
            entries[key] = entry
        }
        return entries.values.sorted { $0.messageID < $1.messageID }
    }

    private func changedCount<Value: Identifiable & Equatable>(local: [Value], merged: [Value]) -> Int where Value.ID: Hashable {
        let existing = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        return merged.filter { existing[$0.id] != nil && existing[$0.id] != $0 }.count
    }
}
