import XCTest
import CoreMedia

@MainActor
final class AppModelTests: XCTestCase {
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
