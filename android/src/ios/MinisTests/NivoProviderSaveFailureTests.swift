import XCTest
@testable import Minis

/// 保存诊断只能暴露固定阶段和系统返回码，不能把路径或凭证带到界面。
final class NivoProviderSaveFailureTests: XCTestCase {
    func testDiagnosticKeepsStageAndCodeWithoutUnderlyingDetails() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 259,
            userInfo: [NSLocalizedDescriptionKey: "fixture-private-path"])
        let failure = NivoProviderSaveFailure.capture(error, stage: .snapshot)
        XCTAssertEqual(failure.diagnosticCode, "PV-03-259")
        XCTAssertFalse(failure.diagnosticCode.contains("fixture-private-path"))
    }

    func testOuterFailureKeepsOriginalInnerStage() {
        let inner = NivoProviderSaveFailure.capture(CocoaError(.fileWriteOutOfSpace), stage: .configuration)
        let outer = NivoProviderSaveFailure.capture(inner, stage: .baseline)
        XCTAssertEqual(outer.stage, .configuration)
        XCTAssertEqual(outer.diagnosticCode, inner.diagnosticCode)
    }
}
