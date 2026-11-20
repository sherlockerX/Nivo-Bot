import XCTest
@testable import Minis

/// 参数错误必须在读取会话、弹出权限提示或查询任务之前得到确定结果。
final class NivoScheduledCommandTests: XCTestCase {
    func testProbeWithoutIDReportsMissingArgument() {
        XCTAssertThrowsError(try NivoScheduledCommand.parse(["probe"])) { error in
            XCTAssertEqual(error as? NivoLifeError, .invalidField("id_required"))
        }
    }

    func testEveryExistingTaskActionRequiresNonemptyID() {
        for action in ["probe", "logs", "update", "delete", "enable", "disable", "run"] {
            for arguments in [[action], [action, "--id", ""], [action, "--id", "   "]] {
                XCTAssertThrowsError(try NivoScheduledCommand.parse(arguments), "\(arguments)")
            }
        }
    }

    func testMissingIDCannotConsumeAnotherOption() {
        XCTAssertThrowsError(try NivoScheduledCommand.parse(["probe", "--id", "--expected-revision=1"]))
    }

    func testScriptArgumentsAndPromptPreserveLeadingDashes() throws {
        let script = try NivoScheduledCommand.parse(["create", "--time", "09:00", "--script", "daily.py", "--script-arg", "--verbose"])
        XCTAssertEqual(script.options["script-arg"], ["--verbose"])
        let prompt = try NivoScheduledCommand.parse(["create", "--time", "09:00", "--prompt", "-- a literal note"])
        XCTAssertEqual(prompt.value("prompt"), "-- a literal note")
    }

    func testMutationsRequireValidRevisionBeforeHostAccess() {
        for action in ["update", "delete", "enable", "disable", "run"] {
            for revision in [nil, "", "-1", "broken", "9223372036854775808"] as [String?] {
                let arguments = [action, "--id", "existing-task"]
                    + (revision.map { ["--expected-revision", $0] } ?? [])
                XCTAssertThrowsError(try NivoScheduledCommand.parse(arguments), "\(arguments)")
            }
        }
    }

    func testReadOnlyProbeDoesNotRequireWriteRevision() throws {
        let command = try NivoScheduledCommand.parse(["probe", "--id", "existing-task"])
        XCTAssertTrue(command.isReadOnly)
        XCTAssertEqual(command.value("id"), "existing-task")
    }

    func testMissingArgumentDiagnosticNamesTheActualCLIOption() throws {
        let output = NivoLifeToolFailure.output(NivoLifeError.invalidField("id_required"))
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(result["error"] as? String, "invalid_args")
        XCTAssertEqual(result["argument"] as? String, "--id")
        XCTAssertEqual(result["success"] as? Bool, false)
    }

    func testPermissionDenialIsNotReportedAsAnInvalidArgument() throws {
        let output = NivoLifeToolFailure.output(NivoScheduledExecutionError.permissionDenied)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(result["error"] as? String, "permission_denied")
        XCTAssertNil(result["argument"])
        XCTAssertTrue((result["message"] as? String)?.contains("Settings > Permissions") == true)
    }

    func testValidMutationAndGlobalReadRemainAvailable() throws {
        let command = try NivoScheduledCommand.parse(["disable", "--id", "existing-task", "--expected-revision", "0"])
        XCTAssertFalse(command.isReadOnly)
        XCTAssertEqual(command.value("expected-revision"), "0")
        XCTAssertEqual(try NivoScheduledCommand.parse([]).action, "list")
        XCTAssertTrue(try NivoScheduledCommand.parse(["settings"]).isReadOnly)
    }
}
