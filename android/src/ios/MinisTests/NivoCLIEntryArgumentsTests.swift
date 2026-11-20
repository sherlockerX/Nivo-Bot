import XCTest
@testable import Minis

/// 验证原生入口使用的命令与筛选解析，不读取配置或调用供应商。
final class NivoCLIEntryArgumentsTests: XCTestCase {
    func testConfigWithoutCommandPreservesDiscoveryDefault() throws {
        XCTAssertNil(try NivoCLIEntryArguments.configCommandIndex([]))
        XCTAssertNil(try NivoCLIEntryArguments.configCommandIndex(["--compact", "-q"]))
    }

    func testConfigRejectsMissingLeadingMetadataValues() {
        for option in ["--actor", "--session", "--caption"] {
            for arguments in [[option], [option, "--compact", "get", "appearance.theme"]] {
                XCTAssertThrowsError(try NivoCLIEntryArguments.configCommandIndex(arguments), "\(arguments)")
            }
        }
    }

    func testConfigRetainsCommandIndexForExistingArgumentNormalization() throws {
        let arguments = ["--compact", "--actor", "agent", "--session", "chat", "--caption", "Read", "get", "appearance.theme"]
        XCTAssertEqual(try NivoCLIEntryArguments.configCommandIndex(arguments), 7)
        XCTAssertEqual(try NivoCLIEntryArguments.configCommandIndex(["--caption", "", "get", "models"]), 2)
    }

    func testModelUseFlagsBeforeCommandDoNotConsumeCommand() throws {
        for flags in [["--compact"], ["--all"], ["--compact", "--all", "-q"]] {
            XCTAssertEqual(try NivoCLIEntryArguments.modelUse(flags + ["list"]).command, "list")
            let search = try NivoCLIEntryArguments.modelUse(flags + ["search", "fast", "model"])
            XCTAssertEqual(search.command, "search")
            XCTAssertEqual(search.searchQuery, "fast model")
        }
    }

    func testModelUseSearchFlagsNeverConsumeQueryWords() throws {
        let result = try NivoCLIEntryArguments.modelUse(["search", "--all", "fast", "--compact", "model", "--provider", "Primary"])
        XCTAssertEqual(result.searchQuery, "fast model")
        XCTAssertEqual(result.provider, "Primary")
    }

    func testModelUseRejectsMissingProviderForEveryCommand() {
        for command in ["list", "search", "run"] {
            for suffix in [["--provider"], ["--provider", "--compact"], ["--provider", ""], ["--provider", "   "], ["--provider="]] {
                XCTAssertThrowsError(try NivoCLIEntryArguments.modelUse([command] + suffix), "\(command) \(suffix)")
            }
        }
    }

    func testModelUseProviderBeforeCommandRemainsAFilter() throws {
        let result = try NivoCLIEntryArguments.modelUse(["--all", "--provider", "Primary", "list"])
        XCTAssertEqual(result.command, "list")
        XCTAssertEqual(result.provider, "Primary")
        XCTAssertEqual(try NivoCLIEntryArguments.modelUse(["--provider=Primary", "list"]).provider, "Primary")
    }

    func testModelUseRepeatedProviderKeepsFirstFilterAndValidatesEveryValue() throws {
        let result = try NivoCLIEntryArguments.modelUse(["list", "--provider", "Primary", "--provider", "Secondary"])
        XCTAssertEqual(result.provider, "Primary")
        XCTAssertThrowsError(try NivoCLIEntryArguments.modelUse(["list", "--provider", "Primary", "--provider"]))
    }

    func testModelUsePromptLiteralIsNotAProviderOption() throws {
        let result = try NivoCLIEntryArguments.modelUse(["run", "--model", "model", "--prompt", "--provider", "--provider", "Primary"])
        XCTAssertEqual(result.command, "run")
        XCTAssertEqual(result.provider, "Primary")
    }

    func testModelUseMissingCommandStillFails() {
        XCTAssertThrowsError(try NivoCLIEntryArguments.modelUse([]))
        XCTAssertThrowsError(try NivoCLIEntryArguments.modelUse(["--compact", "--all"]))
    }
}
