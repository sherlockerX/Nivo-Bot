import XCTest
@testable import Minis

/// 脚本快照和argv规则直接用于生产执行器，不调用模型或用户脚本。
final class NivoScheduledScriptTests: XCTestCase {
    func testFixedTimezoneDoesNotRequireFileAndRegionalTimezoneKeepsRules() throws {
        XCTAssertEqual(try NivoScheduledTimezone(TimeZone(secondsFromGMT: 0)!).environmentValue, "UTC0")
        let east = try NivoScheduledTimezone(TimeZone(secondsFromGMT: 19_800)!)
        XCTAssertEqual(east.environmentValue, "UTC-5:30:0")
        XCTAssertNil(east.requiredDataPath)
        XCTAssertEqual(try NivoScheduledTimezone(TimeZone(secondsFromGMT: -12_600)!).environmentValue, "UTC+3:30:0")
        let region = try NivoScheduledTimezone(TimeZone(identifier: "America/Chicago")!)
        XCTAssertEqual(region.environmentValue, "America/Chicago")
        XCTAssertEqual(region.requiredDataPath, "/usr/share/zoneinfo/America/Chicago")
    }

    func testRejectsPathsUnsupportedTypesAndOversizedArguments() throws {
        for id in ["../x.sh", "x/hi.py", "a..sh", "x.exe", "中文.sh", "a.sh\n", String(repeating: "a", count: 80) + ".sh"] {
            XCTAssertThrowsError(try NivoRoutineScript(id: id).validate(), id)
        }
        XCTAssertThrowsError(try NivoRoutineScript(id: "a.sh", arguments: ["x\0y"]).validate())
        XCTAssertThrowsError(try NivoRoutineScript(id: "a.sh", arguments: [String(repeating: "界", count: 86)]).validate())
        XCTAssertThrowsError(try NivoRoutineScript(id: "a.sh", arguments: Array(repeating: "", count: 17)).validate())
    }

    func testFrozenVersionRetainsLiteralArgumentsAndBindsApprovalToBodyAndArguments() throws {
        let script = NivoRoutineScript(id: "daily.sh", arguments: ["", "x'; $(echo bad);\nmore"])
        var data = Data("printf '%s' \"$1\"".utf8)
        let version = try NivoScheduledScriptVersion(script: script, data: data)
        data = Data("exit 1".utf8)
        XCTAssertEqual(version.invocationArguments, ["-c", "cd /var/minis/home || exit 125\nprintf '%s' \"$1\"", script.guestPath] + script.arguments)
        XCTAssertNotEqual(version.digest, try NivoScheduledScriptVersion(script: script, data: data).digest)
        XCTAssertEqual(version.digest, try NivoScheduledScriptVersion(script: script, data: Data(version.body.utf8)).digest)
        var changed = script
        changed.arguments = ["other"]
        XCTAssertNotEqual(version.digest, try NivoScheduledScriptVersion(script: changed, data: Data(version.body.utf8)).digest)
    }

    func testRejectsBinaryAndOversizedScriptInsteadOfTruncating() {
        let script = NivoRoutineScript(id: "daily.py")
        XCTAssertThrowsError(try NivoScheduledScriptVersion(script: script, data: Data([0xff, 0xfe])))
        XCTAssertThrowsError(try NivoScheduledScriptVersion(script: script, data: Data("x\0y".utf8)))
        XCTAssertThrowsError(try NivoScheduledScriptVersion(script: script, data: Data(repeating: 65, count: 65_537)))
    }

    func testScriptCannotAlsoRunPromptModelOrDestructiveRerun() throws {
        for extra in [["--prompt", "run"], ["--model", "image"], ["--target", "rerun", "--session", UUID().uuidString, "--message", UUID().uuidString]] {
            let command = try NivoScheduledCommand.parse(["create", "--time", "09:00", "--script", "daily.py"] + extra)
            XCTAssertThrowsError(try command.applying(to: nil))
        }
    }
}
