import Foundation

/// 模型的稳定存储身份与可编辑接口ID分离，改名不能改动另一条记录的UUID。
struct NivoProviderModelIdentity: Equatable, Sendable {
    enum Failure: Error, Equatable { case invalidID, duplicateModelID(String), changed }
    let uuid: String
    let providerID: String
    let modelID: String

    /// 先按稳定UUID定位原记录，再检查新ID是否被同一提供商的其他记录占用。
    static func replacementIndex(for proposed: Self, in current: [Self]) throws -> Int {
        try validate(proposed)
        let matches = current.indices.filter { current[$0].uuid == proposed.uuid }
        guard matches.count == 1, let index = matches.first,
              current[index].providerID == proposed.providerID else { throw Failure.changed }
        guard !current.contains(where: {
            $0.uuid != proposed.uuid && $0.providerID == proposed.providerID && $0.modelID == proposed.modelID
        }) else { throw Failure.duplicateModelID(proposed.modelID) }
        return index
    }

    /// 新增模型同时验证UUID和供应商内的接口ID，不能先发布再让SQLite发现重复行。
    static func validateAddition(_ proposed: Self, in current: [Self]) throws {
        try validate(proposed)
        guard !current.contains(where: { $0.uuid == proposed.uuid }) else { throw Failure.changed }
        guard !current.contains(where: { $0.providerID == proposed.providerID && $0.modelID == proposed.modelID }) else {
            throw Failure.duplicateModelID(proposed.modelID)
        }
    }

    /// 保留成员次序，将同一模型的历史别名合并成一个新引用。
    static func remap(_ references: [String], aliases: Set<String>, target: String) -> [String] {
        var seen = Set<String>()
        return references.compactMap {
            let reference = aliases.contains($0) ? target : $0
            return seen.insert(reference).inserted ? reference : nil
        }
    }

    private static func validate(_ value: Self) throws {
        guard !value.uuid.isEmpty, !value.providerID.isEmpty,
              !value.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (value.providerID + "/" + value.modelID).utf8.count <= 4096,
              !value.modelID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Failure.invalidID
        }
    }
}
