import Foundation

/// 恢复日志缺失与损坏必须分开；读不懂日志时保留快照并阻止新的个人数据写入。
enum NivoBackupRecoveryState {
    struct Marker: Codable, Equatable, Sendable {
        var backupId: String
        var startedAt: Date
        var categories: [String]
        var runId: String? = nil
        var snapshotNames: [String]? = nil
        var credentialRestore: NivoCredentialRestoreReceipt? = nil
        var providerKeyRotation: NivoProviderKeyRotation.Receipt? = nil
        var providerSetupQueue: NivoProviderSetupSyncSQL.Receipt? = nil
    }

    case absent
    case pending(Marker)
    case unreadable

    var marker: Marker? {
        if case .pending(let marker) = self { return marker }
        return nil
    }

    var requiresRecovery: Bool {
        if case .absent = self { return false }
        return true
    }

    var affectsPersonalData: Bool {
        switch self {
        case .absent: return false
        case .pending(let marker): return marker.categories.contains("personal_data")
        case .unreadable: return true
        }
    }

    /// 大小和类型检查先于解码，目录、链接、权限错误和截断JSON都不能解释为空日志。
    static func read(_ url: URL) -> Self {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.int64Value <= 4 * 1_024 * 1_024 else { return .unreadable }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let marker = try decoder.decode(Marker.self, from: Data(contentsOf: url))
            guard !marker.backupId.isEmpty,
                  marker.startedAt.timeIntervalSince1970.isFinite else { return .unreadable }
            if let runId = marker.runId {
                guard !runId.isEmpty, runId.count <= 64,
                      runId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                      let names = marker.snapshotNames, names.count <= 10_000,
                      Set(names).count == names.count, names.allSatisfy(Self.isSnapshotName) else { return .unreadable }
            } else if marker.snapshotNames != nil { return .unreadable }
            if let credentialRestore = marker.credentialRestore {
                guard marker.runId != nil, marker.categories.contains("providers") else { return .unreadable }
                try credentialRestore.validate()
            }
            if marker.providerKeyRotation != nil || marker.providerSetupQueue != nil {
                guard marker.runId != nil, marker.categories == ["providers"] else { return .unreadable }
                try marker.providerKeyRotation?.validate()
                try marker.providerSetupQueue?.validate()
            }
            return .pending(marker)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return .absent
        } catch { return .unreadable }
    }

    /// 快照名称只能指向本次暂存根的直接子项。
    static func isSnapshotName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !value.contains("\\") && !value.contains(":") && !value.contains("\0")
    }
}
