import XCTest
@testable import Minis

/// 终端读命令严格校验参数，不将拼写错误静默解释为默认值。
final class NivoConfigCLIArgumentsTests: XCTestCase {
    func testGetPreservesDottedPathAndDefaultSentinels() throws {
        let result = try NivoConfigCLIArguments.parseGet(["models.provider/model.v4.contextWindow"])
        XCTAssertEqual(result.path, "models.provider/model.v4.contextWindow")
        XCTAssertNil(result.filter)
        XCTAssertEqual(result.page, 0)
        XCTAssertEqual(result.pageSize, 0)
    }

    func testGetSupportsLongAndShortFlags() throws {
        for flags in [["--filter", "flash text", "--page", "2", "--page-size", "50"],
                      ["-f", "flash text", "-p", "2", "-s", "50"]] {
            let result = try NivoConfigCLIArguments.parseGet(["models"] + flags)
            XCTAssertEqual(result.filter, "flash text")
            XCTAssertEqual(result.page, 2)
            XCTAssertEqual(result.pageSize, 50)
        }
    }

    func testCommonOutputFlagsDoNotBecomePathsOrValues() throws {
        let result = try NivoConfigCLIArguments.parseGet(["--compact", "models", "-q"])
        XCTAssertEqual(result.path, "models")
        XCTAssertThrowsError(try NivoConfigCLIArguments.parseGet(["models", "--filter", "--quiet"]))
    }

    func testAuditMetadataFlagsRemainCompatibleForReadCommands() throws {
        let arguments = ["models", "--session", "session", "--actor", "agent", "--caption", "Inspect"]
        XCTAssertEqual(try NivoConfigCLIArguments.parseGet(arguments).path, "models")
        XCTAssertEqual(try NivoConfigCLIArguments.parseTopic(arguments, availableTopics: ["models"]), "models")
        XCTAssertThrowsError(try NivoConfigCLIArguments.parseGet(["models", "--session"]))
    }

    func testInvalidPaginationAndExtraArgumentsFail() {
        for arguments in [[String](), ["--page", "2"], ["models", "extra"],
                          ["models", "--unknown"], ["models", "--page"],
                          ["models", "--page", "abc"], ["models", "--page", "2junk"],
                          ["models", "--page", "0"], ["models", "--page", "-1"],
                          ["models", "--page-size", "0"],
                          ["models", "--page", "9999999999999999999999999"],
                          ["models", "--page", "1", "-p", "2"]] {
            XCTAssertThrowsError(try NivoConfigCLIArguments.parseGet(arguments), "\(arguments)")
        }
    }

    func testPageSizeAboveCapIsPassedToExistingBridgeClamp() throws {
        XCTAssertEqual(try NivoConfigCLIArguments.parseGet(["models", "-s", "101"]).pageSize, 101)
    }

    func testTopicHelpRequiresExactlyOneKnownTopic() throws {
        XCTAssertEqual(try NivoConfigCLIArguments.parseTopic(["models", "--compact"],
            availableTopics: ["models", "providers"]), "models")
        for arguments in [[String](), ["missing"], ["models", "providers"], ["--filter", "models"]] {
            XCTAssertThrowsError(try NivoConfigCLIArguments.parseTopic(arguments,
                availableTopics: ["models", "providers"]))
        }
    }

    func testExitCodesFollowConfigContract() {
        XCTAssertEqual(NivoConfigCLIArguments.exitCode(isOK: true, error: nil), 0)
        for error in ["invalid_args", "unknown_path", "validation_failed", "read_failed"] {
            XCTAssertEqual(NivoConfigCLIArguments.exitCode(isOK: false, error: error), 1)
        }
        XCTAssertEqual(NivoConfigCLIArguments.exitCode(isOK: false, error: "timeout"), 124)
        XCTAssertEqual(NivoConfigCLIArguments.exitCode(isOK: false, error: "user_rejected"), 125)
        XCTAssertEqual(NivoConfigCLIArguments.exitCode(isOK: false, error: "all_rejected"), 125)
        XCTAssertEqual(NivoConfigCLIArguments.exitCode(isOK: false, error: "permission_denied"), 126)
    }
}
