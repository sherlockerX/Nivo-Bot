import XCTest
@testable import Minis

/// 版本检查使用本地结构化样本，验证平台选择，不访问真实发行服务。
final class NivoReleaseCatalogTests: XCTestCase {
    private func catalog(_ releases: [[String: Any]], status: String = "available") -> [String: Any] {
        ["schemaVersion": 2, "platforms": [["id": "ios", "status": status]], "releases": releases]
    }

    private func release(_ version: String, platform: String = "ios") -> [String: Any] {
        ["version": version, "platform": platform, "channel": "stable", "distribution": "ipa",
         "downloadUrl": "https://nivo.8666886.xyz/downloads/Nivo-\(version).ipa"]
    }

    func testAndroidOnlyCatalogCannotBecomeAnIOSUpdate() {
        XCTAssertEqual(NivoReleaseCatalog.lookup(catalog([release("2.0.0", platform: "android")], status: "unreleased")), .unpublished)
        XCTAssertNil(NivoReleaseCatalog.lookup(catalog([release("9.0.0", platform: "android")])))
        XCTAssertNil(NivoReleaseCatalog.lookup(["latest": "9.0.0"]))
        XCTAssertNil(NivoReleaseCatalog.lookup(["releases": [["tag": "v9.0.0"]]]))
    }

    func testChoosesNewestStableIOSReleaseIndependentOfOrder() {
        var beta = release("4.0.0")
        beta["channel"] = "beta"
        let found = NivoReleaseCatalog.lookup(catalog([release("2.2.0"), release("8.0.0", platform: "android"),
            beta, release("2.10.0"), release("3.0.0-beta.1")]))
        XCTAssertEqual(found, .available(.init(version: "2.10.0", page: NivoProduct.downloads.absoluteString)))
    }

    func testInstallRouteMustMatchIOSDistribution() {
        var row = release("2.0.0")
        for address in ["https://nivo.8666886.xyz/downloads/app.apk", "file:///app.ipa", "https://other.invalid/app.ipa"] {
            row["downloadUrl"] = address
            XCTAssertNil(NivoReleaseCatalog.lookup(catalog([row])), address)
        }
        row["distribution"] = "testflight"
        row["downloadUrl"] = "https://testflight.apple.com/join/fixture"
        XCTAssertNotNil(NivoReleaseCatalog.lookup(catalog([row])))
        row["downloadUrl"] = "https://testflight.apple.com@other.invalid/join/fixture"
        XCTAssertNil(NivoReleaseCatalog.lookup(catalog([row])))
        row["distribution"] = "appstore"
        row["downloadUrl"] = "https://apps.apple.com/app/id000000000"
        XCTAssertNotNil(NivoReleaseCatalog.lookup(catalog([row])))
    }

    func testGitHubFallbackRequiresPublishedIPA() {
        var row: [String: Any] = ["tag_name": "v2.1.0", "html_url": "https://github.com/sherlockerX/Nicholasx/releases/tag/v2.1.0"]
        XCTAssertNil(NivoReleaseCatalog.github(row))
        row["assets"] = [["name": "app.apk", "browser_download_url": "https://github.com/sherlockerX/Nicholasx/releases/download/v2.1.0/app.apk"]]
        XCTAssertNil(NivoReleaseCatalog.github(row))
        row["assets"] = [["name": "app.ipa", "browser_download_url": "https://github.com/sherlockerX/Nicholasx/releases/download/v2.1.0/app.ipa"]]
        XCTAssertEqual(NivoReleaseCatalog.github(row)?.version, "v2.1.0")
        row["draft"] = true
        XCTAssertNil(NivoReleaseCatalog.github(row))
        row["draft"] = false
        row["prerelease"] = true
        XCTAssertNil(NivoReleaseCatalog.github(row))
    }

    func testVersionsUseNumericComponentsAndIgnoreBuildMetadata() {
        XCTAssertEqual(NivoReleaseCatalog.compareVersions("v2.10.0", "2.9.9"), 1)
        XCTAssertEqual(NivoReleaseCatalog.compareVersions("2.0.0-beta.10", "2.0.0-beta.9"), 1)
        XCTAssertEqual(NivoReleaseCatalog.compareVersions("2.0.0", "2.0.0-rc.1"), 1)
        XCTAssertEqual(NivoReleaseCatalog.compareVersions("2.0.0-beta.01.x", "2.0.0-beta.1.y"), -1)
        XCTAssertEqual(NivoReleaseCatalog.compareVersions("2.0.0+7", "2.0+8"), 0)
        XCTAssertEqual(NivoReleaseCatalog.compareVersions("2.0.0-1", "2.0.0-a"), -1)
    }

    func testMalformedVersionsAndCatalogSchemaAreRejected() {
        for version in ["Android 2.0", "2", "2..0", "2.0.0-", "2.0.0<script>", "２.０"] {
            XCTAssertFalse(NivoReleaseCatalog.isValidVersion(version), version)
            XCTAssertNil(NivoReleaseCatalog.lookup(catalog([release(version)])))
        }
        var old = catalog([release("2.0.0")])
        old["schemaVersion"] = 99
        XCTAssertNil(NivoReleaseCatalog.lookup(old))
        XCTAssertTrue(NivoReleaseCatalog.isValidVersion(" v2.1.0\n"))
    }
}
