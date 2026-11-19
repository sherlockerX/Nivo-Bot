import Foundation
import XCTest
@testable import Minis

/// 移除云账号后，本地档案不能改名、丢失，也不能被后来导入的旧账号覆盖。
final class NivoLocalIdentityTests: XCTestCase {
    func testFirstMigrationPreservesTheCurrentOwnerAndProviderIDs() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("local-profile.json")
            let profile = try NivoLocalIdentity.prepare(at: url, legacyOwner: "existing-owner",
                retiring: ["old-provider", "old-provider"])
            XCTAssertEqual(profile.owner, "existing-owner")
            XCTAssertEqual(profile.retiredProviderIDs, ["old-provider"])
            XCTAssertEqual(try NivoLocalIdentity.read(from: url), profile)
        }
    }

    func testRetryAndImportedCloudMetadataNeverSwitchTheLocalOwner() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("local-profile.json")
            _ = try NivoLocalIdentity.prepare(at: url, legacyOwner: "existing-owner", retiring: ["first"])
            let retried = try NivoLocalIdentity.prepare(at: url, legacyOwner: "different-owner", retiring: ["second"])
            XCTAssertEqual(retried.owner, "existing-owner")
            XCTAssertEqual(retried.retiredProviderIDs, ["first", "second"])
        }
    }

    func testAnEstablishedEmptyOwnerRemainsLocalAfterImport() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("local-profile.json")
            _ = try NivoLocalIdentity.prepare(at: url, legacyOwner: "", retiring: [])
            XCTAssertEqual(try NivoLocalIdentity.prepare(at: url, legacyOwner: "old-account", retiring: []).owner, "")
        }
    }

    func testUnreadableProfileIsPreservedAndDoesNotCreateANewIdentity() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("local-profile.json")
            let broken = Data("{invalid".utf8)
            try broken.write(to: url)
            XCTAssertThrowsError(try NivoLocalIdentity.prepare(at: url, legacyOwner: "", retiring: []))
            XCTAssertEqual(try Data(contentsOf: url), broken)
        }
    }

    func testOnlyRetiredInstancesAndTheOriginalServiceAreRemoved() {
        XCTAssertTrue(NivoLocalIdentity.isRetiredProvider(id: "old", baseURL: "https://custom.example.org", retiredIDs: ["old"]))
        XCTAssertTrue(NivoLocalIdentity.isRetiredProvider(id: "restored", baseURL: "https://CLOUD.NANOMUSE.CN/v1", retiredIDs: []))
        XCTAssertFalse(NivoLocalIdentity.isRetiredProvider(id: "own", baseURL: "https://api.openai.com/v1", retiredIDs: []))
        XCTAssertFalse(NivoLocalIdentity.isRetiredProvider(id: "own", baseURL: "https://cloud.nanomuse.cn.example.org", retiredIDs: []))
        XCTAssertFalse(NivoLocalIdentity.isRetiredProvider(id: "own", baseURL: "http://192.168.1.4:11434", retiredIDs: []))
    }

    func testRetiredProviderPolicyPreservesUserEndpointsAndBlocksRestoredIDs() {
        let policy = NivoRetiredProviderPolicy()
        policy.install(["old-relay"])
        XCTAssertTrue(policy.blocks(id: "old-relay", baseURL: "https://custom.example.org"))
        XCTAssertTrue(policy.blocks(id: "imported", baseURL: "https://cloud.nanomuse.cn/v1"))
        XCTAssertFalse(policy.blocks(id: "own-key", baseURL: "https://api.openai.com/v1"))
        XCTAssertFalse(policy.blocks(id: "local", baseURL: "http://localhost:11434"))
        policy.install(["old-relay", "other-relay"])
        XCTAssertTrue(policy.blocks(id: "other-relay", baseURL: nil))
    }

    func testDNSRootDotCannotReactivateTheOriginalCloud() {
        XCTAssertTrue(NivoLocalIdentity.isRetiredProvider(id: "imported", baseURL: "https://cloud.nanomuse.cn./v1", retiredIDs: []))
        XCTAssertTrue(NivoLocalIdentity.isRetiredProvider(id: "imported", baseURL: "https://CLOUD.NANOMUSE.CN.:443/v1", retiredIDs: []))
        XCTAssertFalse(NivoLocalIdentity.isRetiredProvider(id: "own", baseURL: "https://cloud.nanomuse.cn.example.org./v1", retiredIDs: []))
        XCTAssertFalse(NivoLocalIdentity.isRetiredProvider(id: "own", baseURL: "https://example.org/cloud.nanomuse.cn.", retiredIDs: []))
    }

    private func withDirectory(_ operation: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try operation(root)
    }
}
