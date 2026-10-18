import XCTest
import AVFoundation
import CoreMedia

/// Tests written for the last mutants the suite didn't catch.
final class WFSpaceMarginTests: XCTestCase {
    func testKeeps200MBSpare() {
        let need: Int64 = 1_000_000_000
        XCTAssertThrowsError(try ErrorExplainer.checkSpace(available: need + 150_000_000, needing: need), "less than 200 MB would be left")
        XCTAssertNoThrow(try ErrorExplainer.checkSpace(available: need + 250_000_000, needing: need))
        XCTAssertNoThrow(try ErrorExplainer.checkSpace(available: 0, needing: need), "unknown capacity doesn't block the export")
    }
}

final class WFBatchInPointTests: XCTestCase {
    func testInPointStartsJustBeforeTheFirstWord() {
        XCTAssertEqual(BatchModel.inPoint(forDetectedStart: 1848.0), 1847.7, accuracy: 1e-9)
        XCTAssertEqual(BatchModel.inPoint(forDetectedStart: 0.1), 0, "never before the start of the file")
        XCTAssertEqual(BatchModel.inPoint(forDetectedStart: nil), 0)
    }
}

@MainActor
final class WFRecentSpeakerTests: XCTestCase {
    override func tearDown() async throws {
        for k in ["recentSpeakers", "lastSpeaker"] { UserDefaults.standard.removeObject(forKey: k) }
    }
    func testNewestSpeakerComesFirstWithoutDuplicates() {
        let model = AppModel()
        model.recentSpeakers = []
        model.speaker = "Rick"; model.rememberSpeaker()
        model.speaker = "Will"; model.rememberSpeaker()
        model.speaker = "rick"; model.rememberSpeaker()
        XCTAssertEqual(model.recentSpeakers, ["rick", "Will"], "latest first, case-insensitive dedupe")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "recentSpeakers"), ["rick", "Will"])
    }
}

final class WFCancelCleanupTests: XCTestCase {
    /// Cancelling while the final file is being written must not leave a half-written output behind.
    func testCancelDuringWriteRemovesPartialOutput() async throws {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wf-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.mp4"), out = dir.appendingPathComponent("out.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-f", "lavfi", "-i", "sine=frequency=440", "-t", "60",
                       "-c:v", "libx264", "-g", "60", "-pix_fmt", "yuv420p", "-c:a", "aac", src.path]
        try p.run(); p.waitUntilExit()
        let engine = ExportEngine()
        let sawWriting = Locked(false)
        do {
            _ = try await engine.export(source: src, output: out,
                                        spec: TrimSpec(inTime: CMTime(seconds: 1, preferredTimescale: 600), outTime: CMTime(seconds: 58, preferredTimescale: 600),
                                                       start: .none, end: Transition(kind: .fadeBlack, duration: 2))) { prog in
                // Cancel partway through writing the final file (it's written in staging, then moved in).
                if prog.stage == "Writing file", prog.fraction > 0.4, prog.fraction < 0.95 { sawWriting.set(true); engine.cancel() }
            }
            XCTFail("export should have been cancelled")
        } catch ExportError.cancelled {
            XCTAssertTrue(sawWriting.get(), "cancel happened during the write stage")
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "no partial output")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["src.mp4"], "nothing left next to the source")
        }
    }
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
}

final class SafeSaveTests: XCTestCase {
    func testStagingIsOutsideTheDestinationAndMoveLandsTheFinalName() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("wf-safesave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dest) }
        let staged = SafeSave.stagingURL(near: dest, ext: "mp4")
        XCTAssertNotEqual(staged.deletingLastPathComponent().standardizedFileURL, dest.standardizedFileURL, "never staged inside the output folder")
        try Data(repeating: 7, count: 1024).write(to: staged)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), [], "nothing visible in the destination while writing")
        let final = dest.appendingPathComponent("The Lord Sees (10.4.26).mp4")
        try SafeSave.move(staged, to: final)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.path), ["The Lord Sees (10.4.26).mp4"])
        XCTAssertEqual(try Data(contentsOf: final).count, 1024)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path), "staging folder cleaned up")
    }
}
