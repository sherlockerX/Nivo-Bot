import XCTest
@testable import Minis

/// 使用可控挂起点执行生产导入流程，验证读取、写入、关闭和相机呈现的真实顺序。
@MainActor
final class NivoMosaicEditorLifecycleTests: XCTestCase {
    func testReadingPhotoHoldsLockAndRejectsSecondSelection() async throws {
        let lifecycle = NivoMosaicEditorLifecycle()
        let gate = MosaicMediaGate()
        let identifier = try XCTUnwrap(lifecycle.beginImport())
        XCTAssertTrue(lifecycle.isBusy)
        var savedPaths: [String] = []
        let operation = Task { @MainActor in
            await lifecycle.importPhoto(id: identifier, read: {
                await gate.wait()
                return Data([1, 2])
            }, store: { data in
                XCTAssertEqual(data, Data([1, 2]))
                return "photo.jpg"
            }, scopeIsCurrent: { true }, apply: { savedPaths.append($0) }, onError: { _ in XCTFail() })
        }
        await gate.waitUntilBlocked()
        XCTAssertTrue(lifecycle.isImporting)
        XCTAssertNil(lifecycle.beginImport())
        gate.open()
        let canClearSelection = await operation.value
        XCTAssertTrue(canClearSelection)
        XCTAssertEqual(savedPaths, ["photo.jpg"])
        XCTAssertFalse(lifecycle.isBusy)
    }

    func testClosingDuringNonCancellableReadRejectsLateMediaWrite() async throws {
        let lifecycle = NivoMosaicEditorLifecycle()
        let gate = MosaicMediaGate()
        let identifier = try XCTUnwrap(lifecycle.beginImport())
        let operation = Task { @MainActor in
            await lifecycle.importPhoto(id: identifier, read: {
                await gate.wait()
                return Data([1])
            }, store: { _ in XCTFail("结束后不能写媒体"); return "old.jpg" },
                scopeIsCurrent: { true }, apply: { _ in XCTFail() }, onError: { _ in XCTFail() })
        }
        await gate.waitUntilBlocked()
        lifecycle.finish()
        gate.open()
        let canClearSelection = await operation.value
        XCTAssertFalse(canClearSelection)
        XCTAssertTrue(lifecycle.hasFinished)
        XCTAssertNil(lifecycle.beginImport())
    }

    func testClosingDuringMediaWriteRejectsLateDraftMutation() async throws {
        let lifecycle = NivoMosaicEditorLifecycle()
        let gate = MosaicMediaGate()
        let identifier = try XCTUnwrap(lifecycle.beginImport())
        let operation = Task { @MainActor in
            await lifecycle.importPhoto(id: identifier, read: { Data([1]) }, store: { _ in
                await gate.wait()
                return "late.jpg"
            }, scopeIsCurrent: { true }, apply: { _ in XCTFail("迟到路径不能更新已关闭草稿") }, onError: { _ in XCTFail() })
        }
        await gate.waitUntilBlocked()
        lifecycle.finish()
        gate.open()
        let canClearSelection = await operation.value
        XCTAssertFalse(canClearSelection)
        XCTAssertFalse(lifecycle.isBusy)
    }

    func testCancelledOldReadCannotReplaceNewPhotoOrReleaseItsLock() async throws {
        let lifecycle = NivoMosaicEditorLifecycle()
        let oldGate = MosaicMediaGate()
        let newGate = MosaicMediaGate()
        let oldID = try XCTUnwrap(lifecycle.beginImport())
        var selection: String? = "old"
        let old = Task { @MainActor in
            let canClearSelection = await lifecycle.importPhoto(id: oldID, read: {
                await oldGate.wait()
                return Data([1])
            }, store: { _ in XCTFail(); return "old.jpg" },
                scopeIsCurrent: { true }, apply: { _ in XCTFail() }, onError: { _ in XCTFail() })
            if canClearSelection { selection = nil }
        }
        await oldGate.waitUntilBlocked()
        lifecycle.cancelImport()
        old.cancel()
        selection = "new"
        let newID = try XCTUnwrap(lifecycle.beginImport())
        var result: String?
        let latest = Task { @MainActor in
            let canClearSelection = await lifecycle.importPhoto(id: newID, read: {
                await newGate.wait()
                return Data([2])
            }, store: { _ in "new.jpg" }, scopeIsCurrent: { true },
                apply: { result = $0 }, onError: { _ in XCTFail() })
            if canClearSelection { selection = nil }
        }
        await newGate.waitUntilBlocked()
        oldGate.open()
        await old.value
        XCTAssertTrue(lifecycle.isImporting)
        XCTAssertNil(result)
        XCTAssertEqual(selection, "new")
        newGate.open()
        await latest.value
        XCTAssertEqual(result, "new.jpg")
        XCTAssertFalse(lifecycle.isBusy)
        XCTAssertNil(selection)
    }

    func testCancelledOldWriteCannotClearNewSelectionOrReleaseItsLock() async throws {
        let lifecycle = NivoMosaicEditorLifecycle()
        let gate = MosaicMediaGate()
        let oldID = try XCTUnwrap(lifecycle.beginImport())
        let old = Task { @MainActor in
            await lifecycle.importPhoto(id: oldID, read: { Data([1]) }, store: { _ in
                await gate.wait()
                return "old.jpg"
            }, scopeIsCurrent: { true }, apply: { _ in XCTFail() }, onError: { _ in XCTFail() })
        }
        await gate.waitUntilBlocked()
        lifecycle.cancelImport()
        old.cancel()
        let newID = try XCTUnwrap(lifecycle.beginImport())
        gate.open()
        let canClearSelection = await old.value
        XCTAssertFalse(canClearSelection)
        XCTAssertTrue(lifecycle.isImporting)
        var result: String?
        await lifecycle.importPhoto(id: newID, read: { Data([2]) }, store: { _ in "new.jpg" },
            scopeIsCurrent: { true }, apply: { result = $0 }, onError: { _ in XCTFail() })
        XCTAssertEqual(result, "new.jpg")
    }

    func testChangedAccountAfterReadRejectsResult() async throws {
        let lifecycle = NivoMosaicEditorLifecycle()
        let identifier = try XCTUnwrap(lifecycle.beginImport())
        var isCurrent = true
        await lifecycle.importPhoto(id: identifier, read: {
            isCurrent = false
            return Data([1])
        }, store: { _ in XCTFail(); return "wrong-owner.jpg" },
            scopeIsCurrent: { isCurrent }, apply: { _ in XCTFail() }, onError: { _ in XCTFail() })
        XCTAssertFalse(lifecycle.isBusy)
    }

    func testChangedAccountAfterWriteRejectsResult() async throws {
        let lifecycle = NivoMosaicEditorLifecycle()
        let identifier = try XCTUnwrap(lifecycle.beginImport())
        var isCurrent = true
        await lifecycle.importPhoto(id: identifier, read: { Data([1]) }, store: { _ in
            isCurrent = false
            return "wrong-owner.jpg"
        }, scopeIsCurrent: { isCurrent }, apply: { _ in XCTFail() }, onError: { _ in XCTFail() })
        XCTAssertFalse(lifecycle.isBusy)
    }

    func testReadFailureReportsErrorAndAllowsRetry() async throws {
        let lifecycle = NivoMosaicEditorLifecycle()
        let identifier = try XCTUnwrap(lifecycle.beginImport())
        var errors = 0
        await lifecycle.importPhoto(id: identifier, read: { throw CocoaError(.fileReadUnknown) },
            store: { _ in XCTFail(); return "unused.jpg" }, scopeIsCurrent: { true },
            apply: { _ in XCTFail() }, onError: { _ in errors += 1 })
        XCTAssertEqual(errors, 1)
        XCTAssertFalse(lifecycle.isBusy)
        XCTAssertNotNil(lifecycle.beginImport())
    }

    func testCancellationIsHonouredEvenIfReaderReturnsData() async throws {
        let lifecycle = NivoMosaicEditorLifecycle()
        let gate = MosaicMediaGate()
        let identifier = try XCTUnwrap(lifecycle.beginImport())
        let operation = Task { @MainActor in
            await lifecycle.importPhoto(id: identifier, read: {
                await gate.wait()
                return Data([1])
            }, store: { _ in XCTFail(); return "unused.jpg" }, scopeIsCurrent: { true },
                apply: { _ in XCTFail() }, onError: { _ in XCTFail() })
        }
        await gate.waitUntilBlocked()
        operation.cancel()
        gate.open()
        let canClearSelection = await operation.value
        XCTAssertFalse(canClearSelection)
        XCTAssertFalse(lifecycle.isBusy)
    }

    func testCameraWaitsForSavedDraftAndReleasesLockBeforeCapture() async {
        let lifecycle = NivoMosaicEditorLifecycle()
        let gate = MosaicMediaGate()
        var savedText: String?
        var hasPresented = false
        var captureID: UUID?
        let operation = Task { @MainActor in
            await lifecycle.prepareCamera(saveDraft: {
                await gate.wait()
                savedText = "拍照之前的心得"
            }, scopeIsCurrent: { true }, present: {
                XCTAssertEqual(savedText, "拍照之前的心得")
                XCTAssertFalse(lifecycle.isBusy)
                hasPresented = true
                captureID = lifecycle.beginImport()
            }, onError: { _ in XCTFail() })
        }
        await gate.waitUntilBlocked()
        XCTAssertTrue(lifecycle.isPreparingCamera)
        XCTAssertFalse(hasPresented)
        XCTAssertNil(lifecycle.beginImport())
        gate.open()
        await operation.value
        XCTAssertTrue(hasPresented)
        XCTAssertNotNil(captureID)
        XCTAssertTrue(lifecycle.isImporting)
    }

    func testCancellingCameraPreservesAlreadySavedDraftAndAllowsNextSelection() async throws {
        let lifecycle = NivoMosaicEditorLifecycle()
        var savedText: String?
        await lifecycle.prepareCamera(saveDraft: { savedText = "保留这句话" },
            scopeIsCurrent: { true }, present: {}, onError: { _ in XCTFail() })
        // 取消相机不触发拍照回调，既有草稿已由展示前的保存完成落盘。
        XCTAssertEqual(savedText, "保留这句话")
        XCTAssertFalse(lifecycle.hasFinished)
        let identifier = try XCTUnwrap(lifecycle.beginImport())
        var result: String?
        await lifecycle.importPhoto(id: identifier, read: { Data([1]) }, store: { _ in "next.jpg" },
            scopeIsCurrent: { true }, apply: { result = $0 }, onError: { _ in XCTFail() })
        XCTAssertEqual(result, "next.jpg")
    }

    func testCameraSaveFailureKeepsEditorOpenAndReportsError() async {
        let lifecycle = NivoMosaicEditorLifecycle()
        var errors = 0
        await lifecycle.prepareCamera(saveDraft: { throw CocoaError(.fileWriteUnknown) },
            scopeIsCurrent: { true }, present: { XCTFail() }, onError: { _ in errors += 1 })
        XCTAssertEqual(errors, 1)
        XCTAssertFalse(lifecycle.isBusy)
        XCTAssertFalse(lifecycle.hasFinished)
    }

    func testClosingWhileSavingDraftDoesNotOpenCameraAfterwards() async {
        let lifecycle = NivoMosaicEditorLifecycle()
        let gate = MosaicMediaGate()
        let operation = Task { @MainActor in
            await lifecycle.prepareCamera(saveDraft: { await gate.wait() },
                scopeIsCurrent: { true }, present: { XCTFail() }, onError: { _ in XCTFail() })
        }
        await gate.waitUntilBlocked()
        lifecycle.finish()
        gate.open()
        await operation.value
        XCTAssertFalse(lifecycle.isBusy)
    }
}

/// 测试明确控制挂起与恢复，不通过睡眠时长推测照片读取进度。
@MainActor
private final class MosaicMediaGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var isBlocked = false

    /// 模拟尚未返回且可能忽略取消的系统照片读取。
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            isBlocked = true
            observer?.resume()
            observer = nil
        }
    }

    /// 测试只在被测流程真实进入等待后执行下一步操作。
    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { observer = $0 }
    }

    /// 解除当前等待，让迟到回调按照测试设定的次序抵达。
    func open() {
        continuation?.resume()
        continuation = nil
    }
}
