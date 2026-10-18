import XCTest
import AVFoundation

/// End-to-end AppModel export → details sheet → finalize tests on a synthetic ffmpeg clip.
/// UserDefaults are isolated, the output folder is a scratch directory set *before* AppModel() is built,
/// and fades are set explicitly so the path covered doesn't depend on earlier tests.
@MainActor
final class WFAppFlowExportTests: XCTestCase {
    var dir: URL!
    var outDir: URL!
    var src: URL!
    var saved: [String: Any] = [:]
    var extraDirs: [URL] = []

    override func setUp() async throws {
        saved = WFDefaults.snapshot()
        dir = try WFScratch.make("flow")
        outDir = dir.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        WFDefaults.prepare(outputFolder: outDir)
        src = dir.appendingPathComponent("Sunday Morning.mp4")
        try WFClip.make(at: src, seconds: 12)
    }

    override func tearDown() async throws {
        WFDefaults.restore(saved)
        if let dir { try? FileManager.default.removeItem(at: dir) }
        for d in extraDirs { try? FileManager.default.removeItem(at: d) }
    }

    func loadedModel(points: (Double, Double)? = nil) async throws -> AppModel {
        let model = AppModel()
        XCTAssertEqual(model.outputFolder.standardizedFileURL.path, outDir.standardizedFileURL.path, "never the real Desktop")
        model.startKind = .none
        model.endKind = .fadeBlack
        model.endDuration = 2
        model.open(src, points: points)
        try await WFWait.until("the clip to load", timeout: 60) { model.hasFile || model.loadError != nil }
        XCTAssertNil(model.loadError)
        if points == nil { model.setIn(1) }
        return model
    }

    func hiddenLeftovers(_ folder: URL? = nil) -> [String] { WFScratch.ls(folder ?? outDir).filter { $0.hasPrefix(AppModel.tempPrefix) } }

    func exportAndSave(_ model: AppModel, title: String, speaker: String) async throws -> ExportEngine.Result {
        model.export()
        model.sermonTitle = title
        model.sermonDate = SermonNaming.gregorian.date(from: DateComponents(year: 2026, month: 10, day: 4))!
        model.speaker = speaker
        model.submitDetails()
        return try await WFWait.done(model)
    }

    // MARK: Trimmed output + date from the file (strengthens SermonFlowTests.testDetailsEnteredDuringExport)

    func testExportIsTheTrimmedRangeAndDateComesFromFileCreationDate() async throws {
        let thursday = SermonNaming.gregorian.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 15))!
        try FileManager.default.setAttributes([.creationDate: thursday], ofItemAtPath: src.path)
        let model = try await loadedModel()
        XCTAssertEqual(model.sermonDate, SermonNaming.closestSunday(to: thursday))
        XCTAssertEqual(SermonNaming.dateString(model.sermonDate), "10.11.26", "Thursday → the following Sunday")
        model.setOut(9)
        let expected = model.outTime - model.inTime
        XCTAssertEqual(expected, 8, accuracy: 0.001)
        let r = try await exportAndSave(model, title: "The Lord Sees", speaker: "Rick")
        XCTAssertEqual(r.outputURL.lastPathComponent, "The Lord Sees (10.4.26).mp4")
        XCTAssertEqual(r.report.output.duration, expected, accuracy: 0.1, "only the In→Out range is exported")
        let asset = AVURLAsset(url: r.outputURL)
        let d = try await asset.load(.duration).seconds
        XCTAssertEqual(d, expected, accuracy: 0.1)
        XCTAssertEqual(hiddenLeftovers(), [])
    }

    // MARK: Name collisions through finalize

    func testRepeatedExportsWithTheSameTitleNeverOverwrite() async throws {
        let model = try await loadedModel()
        var names: [String] = []
        for _ in 0..<3 {
            let r = try await exportAndSave(model, title: "Grace", speaker: "")
            names.append(r.outputURL.lastPathComponent)
            XCTAssertTrue(FileManager.default.fileExists(atPath: r.outputURL.path))
        }
        XCTAssertEqual(names, ["Grace (10.4.26).mp4", "Grace (10.4.26) 2.mp4", "Grace (10.4.26) 3.mp4"])
        XCTAssertEqual(WFScratch.ls(outDir), names.sorted())
    }

    // MARK: Recent speakers

    func testNewestSpeakerGoesFirstAndListIsCappedAtTwelve() async throws {
        let older = (1...12).map { "Speaker \($0)" }
        UserDefaults.standard.set(older, forKey: "recentSpeakers")
        let model = try await loadedModel()
        XCTAssertEqual(model.recentSpeakers, older)
        _ = try await exportAndSave(model, title: "Grace", speaker: "Rick; speaker 3")
        let expected = ["Rick", "speaker 3"].reversed() + older.filter { $0 != "Speaker 3" }
        XCTAssertEqual(model.recentSpeakers, Array(expected.prefix(12)))
        XCTAssertEqual(model.recentSpeakers.first, "speaker 3", "most recent name first; case-insensitive duplicate replaced")
        XCTAssertFalse(model.recentSpeakers.contains("Speaker 12"), "the oldest name drops off")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "recentSpeakers"), model.recentSpeakers)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "lastSpeaker"), "Rick; speaker 3")
        XCTAssertEqual(AppModel().speaker, "Rick; speaker 3", "prefilled next time")
    }

    // MARK: Output folder changed while the sheet is open

    func testChangingOutputFolderWhileWaitingMovesTheFileThere() async throws {
        let model = try await loadedModel()
        model.export()
        try await WFWait.until("export to finish and wait for details") { model.exportFinishedWaiting }
        XCTAssertEqual(WFScratch.ls(outDir).count, 0, "nothing appears in the output folder until it is saved")
        // Another volume when possible (the worktree may be on an external drive), else another folder.
        let worktree = dir!
        let other = worktree.appendingPathComponent(".wf-appflow-scratch-\(UUID().uuidString)", isDirectory: true)
        extraDirs.append(other)
        model.outputFolder = other          // doesn't exist yet: finalize creates it
        model.sermonTitle = "Moved"
        model.sermonDate = SermonNaming.gregorian.date(from: DateComponents(year: 2026, month: 10, day: 4))!
        model.submitDetails()
        let r = try await WFWait.done(model)
        XCTAssertEqual(r.outputURL.standardizedFileURL.path, other.appendingPathComponent("Moved (10.4.26).mp4").standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.outputURL.path))
        XCTAssertEqual(WFScratch.ls(outDir), [], "nothing left in the old folder")
        XCTAssertEqual(hiddenLeftovers(other), [])
    }

    // MARK: Saving fails (move error)

    func testFailedSaveKeepsTheExportAndCanBeRetried() async throws {
        let model = try await loadedModel()
        model.export()
        try await WFWait.until("export to finish and wait for details") { model.exportFinishedWaiting }
        let blocker = dir.appendingPathComponent("not-a-folder")
        try Data([1]).write(to: blocker)
        model.outputFolder = blocker.appendingPathComponent("Sub", isDirectory: true)
        model.sermonTitle = "Grace"
        model.sermonDate = SermonNaming.gregorian.date(from: DateComponents(year: 2026, month: 10, day: 4))!
        model.submitDetails()
        try await WFWait.until("save to fail") { if case .failed = model.exportState { return true }; return false }
        guard case .failed(let msg) = model.exportState else { return }
        XCTAssertTrue(msg.hasPrefix("Saving the file failed"), msg)
        XCTAssertEqual(WFScratch.ls(outDir).count, 0, "still nothing in the folder; the finished export waits in staging")

        model.outputFolder = outDir
        model.submitDetails()
        // The state stays .failed until the retried move finishes, so poll for .done directly.
        try await WFWait.until("retried save") { if case .done = model.exportState { return true }; return false }
        guard case .done(let r) = model.exportState else { return }
        XCTAssertEqual(r.outputURL.lastPathComponent, "Grace (10.4.26).mp4")
        XCTAssertEqual(WFScratch.ls(outDir), ["Grace (10.4.26).mp4"])
    }

    // MARK: Cancel from the sheet

    /// Strengthens SermonFlowTests.testCancelFromSheetLeavesNothingBehind (also checks the resulting state).
    func testCancelFromSheetAfterExportFinishedResetsState() async throws {
        let model = try await loadedModel()
        model.export()
        try await WFWait.until("export to finish and wait for details") { model.exportFinishedWaiting }
        model.cancelExportFromSheet()
        if case .idle = model.exportState {} else { XCTFail("expected idle, got \(model.exportState)") }
        XCTAssertFalse(model.showDetailsSheet)
        XCTAssertFalse(model.exportFinishedWaiting)
        XCTAssertEqual(WFScratch.ls(outDir), [])
        model.submitDetails()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(WFScratch.ls(outDir), [], "Save after cancel does nothing")
    }

    func testCancelFromSheetWhileExportIsRunning() async throws {
        let model = try await loadedModel()
        model.export()
        XCTAssertTrue(model.isExporting)
        model.cancelExportFromSheet()
        XCTAssertFalse(model.showDetailsSheet)
        try await WFWait.until("cancel to finish") { if case .idle = model.exportState { return true }; return false }
        XCTAssertFalse(model.exportFinishedWaiting)
        XCTAssertEqual(WFScratch.ls(outDir), [])
        model.submitDetails()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(WFScratch.ls(outDir), [], "Save after cancel produces no file")
    }

    // MARK: load: points, reset

    func testOpenWithPointsSetsThemWithoutUndoAndResetsState() async throws {
        let model = try await loadedModel()
        let um = UndoManager(); um.groupsByEvent = false
        model.undoManager = um
        um.beginUndoGrouping(); model.setIn(3); um.endUndoGrouping()
        XCTAssertTrue(um.canUndo)
        model.sermonTitle = "Old title"
        model.detectState = .failed("old")
        model.open(src, points: (2, 8))
        try await WFWait.until("reload") { model.sermonTitle.isEmpty }
        try await WFWait.until("points") { abs(model.inTime - 2) < 0.001 }
        XCTAssertEqual(model.outTime, 8, accuracy: 0.001)
        XCTAssertFalse(um.canUndo, "opening a file clears undo and doesn't register the points")
        if case .idle = model.detectState {} else { XCTFail("detect state reset") }
        if case .idle = model.exportState {} else { XCTFail("export state reset") }

        let junk = dir.appendingPathComponent("junk.mp4")
        try Data("nope".utf8).write(to: junk)
        model.open(junk)
        try await WFWait.until("load error", timeout: 60) { model.loadError != nil }
        XCTAssertEqual(model.url, src, "a bad file keeps the previous video open")
        XCTAssertFalse(model.loadErrorIsPermission)
    }
}
