import XCTest
import Security
@testable import Minis

/// 仅在Apple宿主使用随机身份，验证真实Keychain迁移属性与范围。
@MainActor
final class NivoLocalKeychainMigrationTests: XCTestCase {
    func testProviderMigrationPreservesMetadataAndCreatesDeviceOnlyCopy() throws {
        let target = makeTarget()
        let version = Data("fixture-version".utf8)
        try insert("fixture-source", target: target, synchronizable: true,
            version: version, comment: "fixture-comment")
        try NivoLocalKeychainMigration.migrateCredential(service: target.service, account: target.account)
        let local = try XCTUnwrap(read(target, synchronizable: false))
        XCTAssertEqual(local[kSecValueData as String] as? Data, Data("fixture-source".utf8))
        XCTAssertEqual(local[kSecAttrGeneric as String] as? Data, version)
        XCTAssertEqual(local[kSecAttrComment as String] as? String, "fixture-comment")
        XCTAssertEqual(local[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNil(try read(target, synchronizable: true))
        try NivoLocalKeychainMigration.migrateCredential(service: target.service, account: target.account)
        XCTAssertEqual(try read(target, synchronizable: false)?[kSecValueData as String] as? Data,
            Data("fixture-source".utf8))
    }

    func testExistingLocalValueWinsAndOldSourceIsRemoved() throws {
        let target = makeTarget(account: "oauth-token")
        try insert("fixture-old-cloud", target: target, synchronizable: true)
        try insert("fixture-new-local", target: target, synchronizable: false)
        try NivoLocalKeychainMigration.migrateCredential(service: target.service, account: target.account)
        XCTAssertEqual(try read(target, synchronizable: false)?[kSecValueData as String] as? Data,
            Data("fixture-new-local".utf8))
        XCTAssertNil(try read(target, synchronizable: true))
    }

    func testEnvironmentWithoutMetadataMigrates() throws {
        let target = makeTarget(service: "io.github.nanomuse.app.envvar", account: UUID().uuidString)
        try insert("fixture-environment", target: target, synchronizable: true)
        try NivoLocalKeychainMigration.migrateCredential(service: target.service, account: target.account)
        XCTAssertEqual(try read(target, synchronizable: false)?[kSecValueData as String] as? Data,
            Data("fixture-environment".utf8))
        XCTAssertNil(try read(target, synchronizable: true))
    }

    func testForeignAndMCPServicesRemainUntouched() throws {
        for service in ["io.github.nanomuse.app.mcp-oauth", "io.github.nanomuse.app.device", "another.app"] {
            let target = makeTarget(service: service, account: UUID().uuidString)
            try insert("fixture-preserved", target: target, synchronizable: true)
            try NivoLocalKeychainMigration.migrateCredential(service: target.service, account: target.account)
            XCTAssertNotNil(try read(target, synchronizable: true))
            XCTAssertNil(try read(target, synchronizable: false))
        }
    }

    private struct Target: Sendable {
        let service: String
        let account: String
    }

    private func makeTarget(service: String? = nil, account: String = "api-key") -> Target {
        let target = Target(service: service ?? "io.github.nanomuse.app.provider." + UUID().uuidString,
            account: account)
        addTeardownBlock {
            for isSync in [false, true] {
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: target.service, kSecAttrAccount as String: target.account,
                    kSecAttrSynchronizable as String: isSync]
                SecItemDelete(query as CFDictionary)
            }
        }
        return target
    }

    private func insert(_ value: String, target: Target, synchronizable: Bool,
                        version: Data? = nil, comment: String? = nil) throws {
        var query = match(target, synchronizable: synchronizable)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let version { query[kSecAttrGeneric as String] = version }
        if let comment { query[kSecAttrComment as String] = comment }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private func read(_ target: Target, synchronizable: Bool) throws -> [String: Any]? {
        var query = match(target, synchronizable: synchronizable)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return try XCTUnwrap(result as? [String: Any])
    }

    private func match(_ target: Target, synchronizable: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: target.service,
         kSecAttrAccount as String: target.account, kSecAttrSynchronizable as String: synchronizable]
    }
}
