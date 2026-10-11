import XCTest

final class ErrorExplainerTests: XCTestCase {
    let generic = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
        NSLocalizedDescriptionKey: "The operation could not be completed",
        NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -17913),
    ])
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-err-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFileIsExplained() {
        let e = ErrorExplainer.explain(generic, operation: "Opening the video", input: dir.appendingPathComponent("gone.mp4"))
        XCTAssertTrue(e.message.contains("isn't there any more"))
        XCTAssertFalse(e.isPermission)
    }

    func testUnreadableFileIsReportedAsPermissionProblem() throws {
        let f = dir.appendingPathComponent("locked.mp4")
        try Data([1, 2, 3]).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.path)
        let e = ErrorExplainer.explain(generic, operation: "Opening the video", input: f)
        XCTAssertTrue(e.isPermission)
        XCTAssertTrue(e.message.contains("Privacy & Security"))
    }

    func testReadOnlyOutputFolderIsReported() throws {
        let f = dir.appendingPathComponent("ok.mp4")
        try Data([1, 2, 3]).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let e = ErrorExplainer.explain(generic, operation: "Export", input: f, outputFolder: dir)
        XCTAssertTrue(e.isPermission)
        XCTAssertTrue(e.message.contains("can't save"))
    }

    func testGenericFallbackIncludesErrorCodes() throws {
        let f = dir.appendingPathComponent("ok.mp4")
        try Data([1, 2, 3]).write(to: f)
        let e = ErrorExplainer.explain(generic, operation: "Export", input: f, outputFolder: dir)
        XCTAssertTrue(e.message.contains("-11800"))
        XCTAssertTrue(e.message.contains("-17913"))
    }

    func testNotEnoughSpaceMessage() {
        XCTAssertThrowsError(try ErrorExplainer.checkSpace(for: dir.appendingPathComponent("x.mp4"), needing: Int64.max / 4)) { err in
            XCTAssertTrue((err as? ExportError)?.localizedDescription.contains("free space") == true)
        }
    }
}

final class StartSnapTests: XCTestCase {
    /// Worship → prayer/"amen" → "be seated, kids dismissed" → 20 s pause → sermon with a scripture reading later on.
    func testStartSnapsBackToTheBeginningOfTheMessage() {
        var words: [TranscriptWord] = []
        func say(_ text: String, at t: Double) -> Double {
            var cur = t
            for w in text.split(separator: " ") { words.append(.init(text: String(w), start: cur, end: cur + 0.3)); cur += 0.4 }
            return cur
        }
        var t = say("What a powerful name it is.", at: 100)
        t = say("God we thank you. In Jesus name we pray. Amen. You can be seated and kids you can be dismissed.", at: t + 5)
        let sermonStart = t + 20
        t = say("Well good morning. My name is Will. We have a lot to cover this morning.", at: sermonStart)
        while t < sermonStart + 6 * 60 { t = say("And this is a long thought about how God keeps his promises to his people.", at: t + 0.3) }
        let scripture = t + 1
        t = say("Genesis chapter 30 verse 25 so we are going to pick up there.", at: scripture)
        while t < sermonStart + 40 * 60 { t = say("And the story goes on because God is faithful to us in every season of life.", at: t + 0.3) }
        t = say("In Jesus name we pray. Amen.", at: t)
        let tr = Transcript(words: words, duration: t + 200)
        let d = MarkerDetector.heuristicCandidates(transcript: tr, settings: MarkerSettings())
        XCTAssertEqual(d.starts.first?.time ?? 0, sermonStart, accuracy: 3)
    }
}
