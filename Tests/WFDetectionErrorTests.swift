import XCTest
import AVFoundation

final class WFDetectionErrorExplainerTests: XCTestCase {
    let generic = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
        NSLocalizedDescriptionKey: "The operation could not be completed",
        NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -17913),
    ])
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-wferr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        if let dir, let items = FileManager.default.enumerator(atPath: dir.path) {
            for case let p as String in items {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent(p).path)
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    func readableFile(in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = folder.appendingPathComponent("ok.mp4")
        try Data([1, 2, 3]).write(to: f)
        return f
    }

    /// Kills the mutant that removed the early return for ExportError.cancelled.
    func testCancelledExportIsNotBlamedOnTheMissingFile() {
        let e = ErrorExplainer.explain(ExportError.cancelled, operation: "Export", input: dir.appendingPathComponent("gone.mp4"))
        XCTAssertEqual(e.message, "Export cancelled.")
        XCTAssertFalse(e.isPermission)
    }

    func testCancelledExportIsNotBlamedOnAReadOnlyFolder() throws {
        let input = try readableFile(in: dir.appendingPathComponent("in"))
        let out = dir.appendingPathComponent("ro")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: out.path)
        let e = ErrorExplainer.explain(ExportError.cancelled, operation: "Export", input: input, outputFolder: out)
        XCTAssertEqual(e.message, "Export cancelled.")
        XCTAssertFalse(e.isPermission)
    }

    func testTranscriptionStageErrorsKeepTheirOwnText() {
        let stage = TranscriptionError.stage("transcribing", generic)
        let e = ErrorExplainer.explain(stage, operation: "Transcription", input: dir.appendingPathComponent("gone.mp4"))
        XCTAssertEqual(e.message, stage.localizedDescription)
        XCTAssertTrue(e.message.hasPrefix("Transcription stopped while transcribing."))
        XCTAssertFalse(e.isPermission)
        let stops = TranscriptionError.audioStops(at: 600, of: 3600, generic)
        let e2 = ErrorExplainer.explain(stops, operation: "Transcription", input: dir.appendingPathComponent("gone.mp4"))
        XCTAssertEqual(e2.message, stops.localizedDescription)
        XCTAssertTrue(e2.message.contains("0:10:00"))
    }

    /// Kills the mutant that checked the input's folder instead of the output folder for write access.
    func testReadOnlyOutputFolderOnAnotherPathIsReported() throws {
        let input = try readableFile(in: dir.appendingPathComponent("source"))
        let out = dir.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: out.path)
        let e = ErrorExplainer.explain(generic, operation: "Export", input: input, outputFolder: out)
        XCTAssertTrue(e.isPermission)
        XCTAssertTrue(e.message.contains("can't save into “Exports”"), e.message)
    }

    func testMissingInputWinsOverReadOnlyOutputFolder() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let e = ErrorExplainer.explain(generic, operation: "Export", input: dir.appendingPathComponent("gone.mp4"), outputFolder: dir)
        XCTAssertTrue(e.message.contains("isn't there any more"), e.message)
        XCTAssertFalse(e.isPermission)
    }

    func testExportErrorPassesThroughWhenFileChecksPass() throws {
        let input = try readableFile(in: dir)
        let e = ErrorExplainer.explain(ExportError.writerFailed("x"), operation: "Export", input: input, outputFolder: dir)
        XCTAssertEqual(e.message, "Writing failed: x")
        XCTAssertFalse(e.isPermission)
        let u = ErrorExplainer.explain(ExportError.unsupported("variable frame timing"), operation: "Export", input: input, outputFolder: dir)
        XCTAssertEqual(u.message, "Unsupported source: variable frame timing")
    }

    /// Stronger replacement for ErrorExplainerTests.testGenericFallbackIncludesErrorCodes.
    func testGenericFallbackFullContract() throws {
        let input = try readableFile(in: dir)
        let e = ErrorExplainer.explain(generic, operation: "Export", input: input, outputFolder: dir)
        XCTAssertFalse(e.isPermission)
        XCTAssertTrue(e.message.hasPrefix("Export failed: The operation could not be completed"), e.message)
        XCTAssertTrue(e.message.contains("AVFoundationErrorDomain -11800 / NSOSStatusErrorDomain -17913"), e.message)
        XCTAssertEqual(ErrorExplainer.code(generic), "AVFoundationErrorDomain -11800 / NSOSStatusErrorDomain -17913")
        XCTAssertEqual(ErrorExplainer.code(NSError(domain: "D", code: 7)), "D 7")
    }

    /// Stronger replacement for ErrorExplainerTests.testMissingFileIsExplained.
    func testMissingFileMessageNamesFileAndOperation() {
        let e = ErrorExplainer.explain(generic, operation: "Opening the video", input: dir.appendingPathComponent("gone.mp4"))
        XCTAssertTrue(e.message.hasPrefix("Opening the video failed"), e.message)
        XCTAssertTrue(e.message.contains("gone.mp4"), e.message)
        XCTAssertTrue(e.message.contains("isn't there any more"))
        XCTAssertFalse(e.isPermission)
    }

}

final class WFDetectionWaveformTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-wfwave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { if let dir { try? FileManager.default.removeItem(at: dir) } }

    func tone(seconds: Int) throws -> URL {
        let f = dir.appendingPathComponent("tone-\(seconds).m4a")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=8000", "-t", "\(seconds)",
                       "-c:a", "aac", "-movflags", "+faststart", f.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return f
    }

    func testPeaksHaveOneValuePerBucketAndAreNormalised() async throws {
        let peaks = await Waveform.peaks(asset: AVURLAsset(url: try tone(seconds: 5)), buckets: 200)
        XCTAssertEqual(peaks.count, 200)
        XCTAssertEqual(peaks.max() ?? 0, 1, accuracy: 1e-6)
        XCTAssertGreaterThan(peaks[100], 0.5)
    }

    /// Kills the off-by-one bucket clamp: the audio track (10 s) runs longer than the container duration (patched to 5 s),
    /// so more samples arrive than duration × rate. The original clamps into the last bucket; the mutant crashes.
    func testAudioLongerThanContainerDurationDoesNotOverflowBuckets() async throws {
        var d = try Data(contentsOf: try tone(seconds: 10))
        let r = try XCTUnwrap(d.range(of: Data("mvhd".utf8)))
        XCTAssertEqual(d[r.lowerBound + 4], 0, "expected a version 0 mvhd box")
        let durAt = r.lowerBound + 20
        let dur = d[durAt..<durAt + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let half = dur / 2
        for k in 0..<4 { d[durAt + k] = UInt8((half >> UInt32(24 - 8 * k)) & 0xff) }
        let patched = dir.appendingPathComponent("patched.m4a")
        try d.write(to: patched)
        let asset = AVURLAsset(url: patched)
        let containerDuration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let trackDuration = try await XCTUnwrap(tracks.first).load(.timeRange).duration.seconds
        XCTAssertLessThan(containerDuration, trackDuration - 1, "the patch should make the container shorter than the track")
        let peaks = await Waveform.peaks(asset: asset, buckets: 100)
        XCTAssertEqual(peaks.count, 100)
        XCTAssertEqual(peaks.last ?? 0, 1, accuracy: 0.2)   // the overflow lands in the last bucket
    }
}
