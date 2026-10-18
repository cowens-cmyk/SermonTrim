import XCTest
import CoreMedia

@MainActor
final class AppModelTests: XCTestCase {
    var saved: [String: Any] = [:]
    var scratch: URL!
    override func setUp() async throws {
        saved = WFDefaults.snapshot()
        scratch = try WFScratch.make("baseline-model")
        WFDefaults.prepare(outputFolder: scratch)
    }
    override func tearDown() async throws {
        WFDefaults.restore(saved)
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testUndoRedoOfInOutPoints() {
        let model = AppModel()
        let um = UndoManager()
        um.groupsByEvent = false
        model.undoManager = um
        model.duration = 100; model.frameRate = 30; model.outTime = 100; model.inTime = 0

        um.beginUndoGrouping(); model.setIn(10); um.endUndoGrouping()
        XCTAssertEqual(model.inTime, 10, accuracy: 0.05)
        um.undo()
        XCTAssertEqual(model.inTime, 0, accuracy: 0.05)
        um.redo()
        XCTAssertEqual(model.inTime, 10, accuracy: 0.05)
    }

    func testDragSetsCoalesceIntoOneUndoStep() {
        let model = AppModel()
        let um = UndoManager()
        um.groupsByEvent = false
        model.undoManager = um
        model.duration = 100; model.frameRate = 30; model.outTime = 100; model.inTime = 0
        um.beginUndoGrouping()
        for t in stride(from: 1.0, through: 20.0, by: 1.0) { model.setIn(t) }   // a drag fires many updates
        um.endUndoGrouping()
        um.undo()
        XCTAssertEqual(model.inTime, 0, accuracy: 0.05)
    }

    func testOutTimeAddsHoldAndFade() {
        let model = AppModel()
        model.duration = 1000
        model.tailSeconds = 5
        model.endKind = .fadeBlack
        model.endDuration = 3
        let c = MarkerCandidate(time: 500, score: 1, reason: "", context: "", source: .phrases)
        XCTAssertEqual(model.outTime(forEnd: c), 508, accuracy: 0.001)       // last word + 5 s hold + 3 s fade
        model.endKind = .none
        XCTAssertEqual(model.outTime(forEnd: c), 505, accuracy: 0.001)
    }

    func testBatchFailsGracefullyWhenNothingIsDetected() async throws {
        let batch = BatchModel()
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-a-video-\(UUID().uuidString).mp4")
        batch.add([missing])
        batch.start(startFade: .none, endFade: Transition(kind: .fadeBlack, duration: 3), tail: 5, markerSettings: MarkerSettings())
        for _ in 0..<50 where batch.running { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(batch.running)
        if case .failed = batch.items[0].status {} else { XCTFail("expected a failure status") }
    }
}

final class MessageOnlyTests: XCTestCase {
    /// A recording that is just the sermon: speech begins almost immediately and runs to an "amen".
    func testSermonOnlyFileStartsNearTheBeginning() {
        var words: [TranscriptWord] = []
        var t = 1.2
        let line = "So friends today we are going to talk about grace and how God meets us right where we are."
        while t < 45 * 60 { for w in line.split(separator: " ") { words.append(.init(text: String(w), start: t, end: t + 0.3)); t += 0.38 }; t += 0.4 }
        for w in "In Jesus name we pray. Amen.".split(separator: " ") { words.append(.init(text: String(w), start: t, end: t + 0.3)); t += 0.4 }
        let tr = Transcript(words: words, duration: t + 4)
        let d = MarkerDetector.heuristicCandidates(transcript: tr, settings: MarkerSettings())
        XCTAssertEqual(d.starts.first?.time ?? 99, 1.2, accuracy: 1.0)
        XCTAssertEqual(d.ends.first?.time ?? 0, words.last!.end, accuracy: 2.0)
    }
}

@MainActor
final class SermonFlowTests: XCTestCase {
    var dir: URL!
    var outDir: URL!
    var src: URL!
    var saved: [String: Any] = [:]

    override func setUp() async throws {
        saved = WFDefaults.snapshot()
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffmpeg else { throw XCTSkip("ffmpeg not installed") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-flow-\(UUID().uuidString)")
        outDir = dir.appendingPathComponent("Desktop-like")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        WFDefaults.prepare(outputFolder: outDir)
        src = dir.appendingPathComponent("Sunday Morning 1080.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-f", "lavfi", "-i", "sine=frequency=440", "-t", "25",
                       "-c:v", "libx264", "-g", "60", "-pix_fmt", "yuv420p", "-c:a", "aac", src.path]
        try p.run(); p.waitUntilExit()
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        WFDefaults.restore(saved)
    }

    func loadedModel() async throws -> AppModel {
        let model = AppModel()
        model.open(src)
        for _ in 0..<100 where !model.hasFile { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.hasFile)
        model.outputFolder = outDir
        model.setIn(1)
        return model
    }

    func waitUntilDone(_ model: AppModel) async throws -> ExportEngine.Result {
        for _ in 0..<400 {
            if case .done(let r) = model.exportState { return r }
            if case .failed(let m) = model.exportState { XCTFail(m); break }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WFTimeout(description: "export did not finish: \(model.exportState)")
    }

    func waitUntilExportFinishedWaiting(_ model: AppModel) async throws {
        for _ in 0..<400 where !model.exportFinishedWaiting { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(model.exportFinishedWaiting)
    }

    func hiddenLeftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []).filter { $0.hasPrefix(AppModel.tempPrefix) }
    }

    /// Typing the details while the export is still running.
    func testDetailsEnteredDuringExport() async throws {
        let model = try await loadedModel()
        let originalSize = try src.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertEqual(Calendar(identifier: .gregorian).component(.weekday, from: model.sermonDate), 1, "defaults to a Sunday")
        model.export()
        XCTAssertTrue(model.showDetailsSheet)
        XCTAssertTrue(model.isExporting)
        model.sermonTitle = "The Lord Sees"
        model.sermonDate = SermonNaming.gregorian.date(from: DateComponents(year: 2026, month: 10, day: 4))!
        model.speaker = "Rick"
        model.submitDetails()
        XCTAssertFalse(model.showDetailsSheet)
        let r = try await waitUntilDone(model)
        XCTAssertEqual(r.outputURL.lastPathComponent, "The Lord Sees (10.4.26).mp4")
        XCTAssertEqual(r.outputURL.deletingLastPathComponent().path, outDir.path)
        XCTAssertEqual(Tagging.tags(of: r.outputURL), ["Rick"])
        XCTAssertEqual(try src.resourceValues(forKeys: [.fileSizeKey]).fileSize, originalSize, "original untouched")
        XCTAssertEqual(hiddenLeftovers(), [])
        XCTAssertEqual(model.recentSpeakers.first, "Rick")
    }

    /// The export finishes first; the file is only named once Save is pressed.
    func testDetailsEnteredAfterExportFinished() async throws {
        let model = try await loadedModel()
        model.export()
        try await waitUntilExportFinishedWaiting(model)
        XCTAssertEqual(((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []).count, 0, "waits in staging, not in the (possibly iCloud) output folder")
        model.sermonTitle = "Grace Upon Grace"
        model.sermonDate = SermonNaming.gregorian.date(from: DateComponents(year: 2026, month: 10, day: 11))!
        model.speaker = "Will, Rick"
        model.submitDetails()
        let r = try await waitUntilDone(model)
        XCTAssertEqual(r.outputURL.lastPathComponent, "Grace Upon Grace (10.11.26).mp4")
        XCTAssertEqual(Set(Tagging.tags(of: r.outputURL)), ["Will", "Rick"])
        XCTAssertEqual(hiddenLeftovers(), [])
    }

    func testSkipUsesOriginalNameWithoutTag() async throws {
        let model = try await loadedModel()
        model.speaker = ""
        model.export()
        model.skipDetails()
        let r = try await waitUntilDone(model)
        XCTAssertEqual(r.outputURL.lastPathComponent, "Sunday Morning 1080 - trimmed.mp4")
        XCTAssertEqual(Tagging.tags(of: r.outputURL), [])
    }

    func testCancelFromSheetLeavesNothingBehind() async throws {
        let model = try await loadedModel()
        model.export()
        try await waitUntilExportFinishedWaiting(model)
        model.cancelExportFromSheet()
        XCTAssertEqual(hiddenLeftovers(), [])
        XCTAssertEqual(((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []).count, 0)
    }
}
