import XCTest
import CoreMedia

/// AppModel / BatchModel tests that need no video. Each test isolates UserDefaults and points the
/// output folder at a scratch directory before building an AppModel (so init's temp clean-up never
/// touches the real Desktop).
@MainActor
final class WFAppFlowModelTests: XCTestCase {
    var dir: URL!
    var saved: [String: Any] = [:]

    override func setUp() async throws {
        saved = WFDefaults.snapshot()
        dir = try WFScratch.make("model")
        WFDefaults.prepare(outputFolder: dir)
    }

    override func tearDown() async throws {
        WFDefaults.restore(saved)
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func model(duration: Double = 100) -> (AppModel, WFCountingUndoManager) {
        let m = AppModel()
        XCTAssertEqual(m.outputFolder.standardizedFileURL.path, dir.standardizedFileURL.path, "test must not use the real Desktop")
        let um = WFCountingUndoManager()
        um.groupsByEvent = false
        m.undoManager = um
        m.duration = duration; m.frameRate = 30; m.outTime = duration; m.inTime = 0
        um.removeAllActions()
        um.registrations = 0
        return (m, um)
    }

    /// One undo group around `body` (the app gets one per UI event).
    func event(_ um: UndoManager, _ body: () -> Void) { um.beginUndoGrouping(); body(); um.endUndoGrouping() }

    func candidate(_ t: Double) -> MarkerCandidate { MarkerCandidate(time: t, score: 1, reason: "", context: "", source: .phrases) }

    // MARK: Undo coalescing (replaces AppModelTests.testDragSetsCoalesceIntoOneUndoStep, which passed even with coalescing removed)

    func testDragOfTwentyUpdatesRegistersOneUndo() {
        let (m, um) = model()
        event(um) { for t in stride(from: 1.0, through: 20.0, by: 1.0) { m.setIn(t) } }
        XCTAssertEqual(m.inTime, 20, accuracy: 0.001)
        XCTAssertEqual(um.registrations, 1, "a drag registers exactly one undo action")
        XCTAssertEqual(um.undoActionName, "Set In")
        um.undo()
        XCTAssertEqual(m.inTime, 0, accuracy: 0.001)
    }

    func testSwitchingFromInToOutRegistersANewUndo() {
        let (m, um) = model()
        event(um) { m.setIn(5); m.setIn(6); m.setOut(80); m.setOut(70) }
        XCTAssertEqual(um.registrations, 2, "the name change starts a new step")
        event(um) { m.setIn(7); m.setOut(60); m.setIn(8) }
        XCTAssertEqual(um.registrations, 5, "alternating In/Out never coalesces")
    }

    // MARK: Undo / redo of In and Out (replaces AppModelTests.testUndoRedoOfInOutPoints)

    func testUndoRedoOfInAndOutPointsInOrder() {
        let (m, um) = model()
        event(um) { m.setIn(10) }
        XCTAssertEqual(um.undoActionName, "Set In")
        event(um) { m.setOut(80) }
        XCTAssertEqual(um.undoActionName, "Set Out")
        XCTAssertEqual([m.inTime, m.outTime], [10, 80])

        um.undo()
        XCTAssertEqual(m.inTime, 10, accuracy: 0.001)
        XCTAssertEqual(m.outTime, 100, accuracy: 0.001)
        um.undo()
        XCTAssertEqual(m.inTime, 0, accuracy: 0.001)
        XCTAssertEqual(m.outTime, 100, accuracy: 0.001)
        XCTAssertFalse(um.canUndo)

        um.redo()
        XCTAssertEqual(m.inTime, 10, accuracy: 0.001)
        XCTAssertEqual(m.outTime, 100, accuracy: 0.001)
        um.redo()
        XCTAssertEqual(m.inTime, 10, accuracy: 0.001)
        XCTAssertEqual(m.outTime, 80, accuracy: 0.001)
        XCTAssertFalse(um.canRedo)
    }

    func testBladeIsOneUndoStepEachWay() {
        let (m, um) = model()
        m.currentTime = 30
        event(um) { m.bladeRemoveBefore() }
        XCTAssertEqual(m.inTime, 30, accuracy: 0.001)
        XCTAssertEqual(um.undoActionName, "Blade")
        XCTAssertFalse(m.bladeOpen)
        um.undo()
        XCTAssertEqual([m.inTime, m.outTime], [0, 100])
        XCTAssertFalse(um.canUndo, "a blade cut is a single step")

        m.currentTime = 70
        event(um) { m.bladeRemoveAfter() }
        XCTAssertEqual(m.outTime, 70, accuracy: 0.001)
        XCTAssertEqual(um.undoActionName, "Blade")
        um.undo()
        XCTAssertEqual([m.inTime, m.outTime], [0, 100])
        XCTAssertFalse(um.canUndo)
    }

    // MARK: applyBestGuess / applyStart / applyEnd

    func testApplyBestGuessSetsBothPointsAsOneUndoStep() {
        let (m, um) = model(duration: 3000)
        m.endKind = .none
        m.tailSeconds = 5
        m.endDuration = 3
        var d = DetectedMarkers()
        d.starts = [candidate(40), candidate(900)]
        d.ends = [candidate(2500)]

        event(um) { m.applyBestGuess() }
        XCTAssertEqual(m.inTime, 0, "nothing happens unless detection is ready")
        XCTAssertEqual(m.outTime, 3000)
        XCTAssertEqual(um.registrations, 0)
        um.removeAllActions()

        m.detectState = .ready(d)
        event(um) { m.applyBestGuess() }
        XCTAssertEqual(m.endKind, TransitionKind.fadeBlack, "an end fade is switched on")
        XCTAssertEqual(m.inTime, 39.7, accuracy: 0.001, "0.3 s pre-roll before the first word")
        XCTAssertEqual(m.outTime, 2508, accuracy: 0.001, "end + 5 s hold + 3 s fade")
        XCTAssertEqual(um.undoActionName, "Use Suggestions")
        XCTAssertEqual(um.registrations, 1, "Use Suggestions is a single step")
        um.undo()
        XCTAssertEqual(m.inTime, 0, accuracy: 0.001)
        XCTAssertEqual(m.outTime, 3000, accuracy: 0.001)
        XCTAssertFalse(um.canUndo)
    }

    func testApplyStartAndEnd() {
        let (m, _) = model(duration: 1000)
        m.undoManager = nil
        m.tailSeconds = 5; m.endKind = .fadeBlack; m.endDuration = 3
        m.applyStart(candidate(0.1))
        XCTAssertEqual(m.inTime, 0, accuracy: 0.001, "pre-roll never goes below zero")
        m.applyStart(candidate(12))
        XCTAssertEqual(m.inTime, 11.7, accuracy: 0.001)
        m.applyEnd(candidate(500))
        XCTAssertEqual(m.outTime, 508, accuracy: 0.001)
    }

    // MARK: outTime(forEnd:) (strengthens AppModelTests.testOutTimeAddsHoldAndFade)

    func testOutTimeForEndIsClampedToDurationAndCountsWhiteFades() {
        let (m, _) = model(duration: 1000)
        m.tailSeconds = 5; m.endDuration = 3
        m.endKind = .fadeBlack
        XCTAssertEqual(m.outTime(forEnd: candidate(995)), 1000, accuracy: 0.001, "never past the end of the file")
        m.endKind = .fadeWhite
        XCTAssertEqual(m.outTime(forEnd: candidate(500)), 508, accuracy: 0.001)
        m.endKind = .none
        XCTAssertEqual(m.outTime(forEnd: candidate(999)), 1000, accuracy: 0.001)
    }

    // MARK: setIn / setOut clamping and snapping

    func testSetInAndSetOutClampAndSnapToFrames() {
        let (m, _) = model()
        m.undoManager = nil
        let frame = 1.0 / 30
        m.setOut(2000)
        XCTAssertEqual(m.outTime, 100, accuracy: 0.0001, "clamped to duration")
        m.setIn(-5)
        XCTAssertEqual(m.inTime, 0, accuracy: 0.0001)
        m.setIn(10.01)
        XCTAssertEqual(m.inTime, 10, accuracy: 0.0001, "snapped to the nearest frame")
        m.setOut(5)
        XCTAssertEqual(m.outTime, 10 + frame, accuracy: 0.0001, "Out stays at least one frame after In")
        m.setOut(50)
        m.setIn(200)
        XCTAssertEqual(m.inTime, 50 - frame, accuracy: 0.0001, "In stays at least one frame before Out")
        XCTAssertEqual(m.snap(1.0 / 60 + 0.0001), frame, accuracy: 0.0001)
    }

    // MARK: cleanUpTempExports

    func testCleanUpRemovesOnlyPrefixedTempFilesInTheOutputFolder() throws {
        let other = try WFScratch.make("model-other")
        defer { try? FileManager.default.removeItem(at: other) }
        let fm = FileManager.default
        let keep = ["The Lord Sees (10.4.26).mp4", ".DS_Store", ".SermonTrim-other.mp4", "x.SermonTrim-export-1.mp4"]
        for n in keep { try Data([1]).write(to: dir.appendingPathComponent(n)) }
        let temp1 = AppModel.tempPrefix + "A.mp4", temp2 = AppModel.tempPrefix + "B.mov"
        try Data([1]).write(to: dir.appendingPathComponent(temp1))
        try Data([1]).write(to: dir.appendingPathComponent(temp2))
        try Data([1]).write(to: other.appendingPathComponent(temp1))

        // Building the model cleans its (saved) output folder.
        let m = AppModel()
        XCTAssertEqual(WFScratch.ls(dir), keep.sorted())
        XCTAssertTrue(fm.fileExists(atPath: other.appendingPathComponent(temp1).path), "other folders are left alone")

        try Data([1]).write(to: dir.appendingPathComponent(temp1))
        m.outputFolder = other
        m.cleanUpTempExports()
        XCTAssertEqual(WFScratch.ls(other), [])
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(temp1).path), "only the current output folder is cleaned")
    }

    // MARK: Settings persistence

    func testSettingsArePersistedAndReloaded() {
        let (m, _) = model()
        m.startKind = .fadeWhite
        m.endKind = .none
        m.startDuration = 1.25
        m.endDuration = 4
        m.tailSeconds = 7
        let again = AppModel()
        XCTAssertEqual(again.startKind, .fadeWhite)
        XCTAssertEqual(again.endKind, TransitionKind.none)
        XCTAssertEqual(again.startDuration, 1.25)
        XCTAssertEqual(again.endDuration, 4)
        XCTAssertEqual(again.tailSeconds, 7)
        XCTAssertEqual(again.outputFolder.standardizedFileURL.path, dir.standardizedFileURL.path)
    }

    // MARK: load failure

    func testOpeningAnUnreadableFileReportsAnErrorAndKeepsNoFile() async throws {
        let (m, _) = model()
        let junk = dir.appendingPathComponent("not really.mp4")
        try Data("hello".utf8).write(to: junk)
        m.open(junk)
        try await WFWait.until("load error", timeout: 60) { m.loadError != nil }
        XCTAssertFalse(m.hasFile)
        XCTAssertFalse(m.loadErrorIsPermission)
        XCTAssertTrue(m.loadError?.hasPrefix("Opening the video failed") == true, m.loadError ?? "")
    }

    // MARK: Batch (replaces AppModelTests.testBatchFailsGracefullyWhenNothingIsDetected, which really tests a missing file)

    func testBatchFailsGracefullyForMissingFile() async throws {
        let batch = BatchModel()
        let missing = dir.appendingPathComponent("gone-\(UUID().uuidString).mp4")
        batch.add([missing, missing])
        XCTAssertEqual(batch.items.count, 1, "duplicates are ignored")
        batch.start(startFade: .none, endFade: Transition(kind: .fadeBlack, duration: 3), tail: 5, markerSettings: MarkerSettings(), outputFolder: dir)
        XCTAssertTrue(batch.running)
        try await WFWait.until("batch to stop", timeout: 30) { !batch.running }
        guard case .failed(let msg) = batch.items[0].status else { return XCTFail("expected failure, got \(batch.items[0].status)") }
        XCTAssertTrue(msg.contains("isn't there any more"), msg)
        XCTAssertNil(batch.items[0].output)
        XCTAssertEqual(WFScratch.ls(dir), [])
        batch.clearFinished()
        XCTAssertTrue(batch.items.isEmpty)
    }

    func testBatchCancelledBeforeItRunsProcessesNothing() async throws {
        let batch = BatchModel()
        batch.add([dir.appendingPathComponent("a.mp4"), dir.appendingPathComponent("b.mp4")])
        batch.start(startFade: .none, endFade: .none, tail: 5, markerSettings: MarkerSettings(), outputFolder: dir)
        batch.cancel()
        try await WFWait.until("batch to stop", timeout: 30) { !batch.running }
        for item in batch.items {
            if case .waiting = item.status {} else { XCTFail("item should not have been processed: \(item.status)") }
        }
        batch.clearFinished()
        XCTAssertEqual(batch.items.count, 2, "waiting items are kept")
    }
}

/// Counts undo registrations, so coalescing can be checked without relying on how groups are formed.
final class WFCountingUndoManager: UndoManager {
    var registrations = 0
    override func __registerUndoWithTarget(_ target: Any, handler: @escaping (Any) -> Void) {
        registrations += 1
        super.__registerUndoWithTarget(target, handler: handler)
    }
}
