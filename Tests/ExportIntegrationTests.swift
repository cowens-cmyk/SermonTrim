import XCTest
import AVFoundation
import CoreMedia

/// Generates a small H.264+AAC clip with ffmpeg (skipped if ffmpeg isn't installed) and runs a real export.
final class ExportIntegrationTests: XCTestCase {
    var ffmpeg: String? { ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) } }

    func testExportKeepsSizeAndFormat() async throws {
        guard let ffmpeg else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.mp4"), out = dir.appendingPathComponent("out.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                       "-t", "40", "-c:v", "libx264", "-b:v", "3M", "-g", "90", "-bf", "2", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", src.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let spec = TrimSpec(inTime: CMTime(seconds: 1.5, preferredTimescale: 60000), outTime: CMTime(seconds: 36, preferredTimescale: 60000),
                            start: Transition(kind: .fadeBlack, duration: 0.5), end: Transition(kind: .fadeBlack, duration: 3))
        let r = try await ExportEngine().export(source: src, output: out, spec: spec) { _ in }
        XCTAssertFalse(r.plan.isSingleSegment)
        XCTAssertNotNil(r.plan.mid)
        XCTAssertEqual(r.report.output.codec, r.report.original.codec)
        XCTAssertEqual(r.report.output.width, 1280)
        XCTAssertEqual(r.report.output.duration, 34.5, accuracy: 0.1)
        XCTAssertLessThan(r.report.sizeRatio, 1.1)
        XCTAssertFalse(r.report.looksTooLarge)
        XCTAssertLessThan(r.plan.reencodedDuration, 9)

        // The audio and video both reach the end together.
        let asset = AVURLAsset(url: out)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        XCTAssertNotNil(audio)
        let aDur = try await audio!.load(.timeRange).duration.seconds_
        XCTAssertEqual(aDur, 34.5, accuracy: 0.1)
    }

    func testCancelStopsExport() async throws {
        guard let ffmpeg else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.mp4"), out = dir.appendingPathComponent("out.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-f", "lavfi", "-i", "sine=frequency=440", "-t", "20",
                       "-c:v", "libx264", "-g", "60", "-pix_fmt", "yuv420p", "-c:a", "aac", src.path]
        try p.run(); p.waitUntilExit()
        let engine = ExportEngine()
        engine.cancel()
        do {
            _ = try await engine.export(source: src, output: out,
                                        spec: TrimSpec(inTime: CMTime(seconds: 1, preferredTimescale: 600), outTime: CMTime(seconds: 18, preferredTimescale: 600),
                                                       start: .none, end: Transition(kind: .fadeBlack, duration: 2))) { _ in }
            XCTFail("expected cancellation")
        } catch ExportError.cancelled {
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
    }
}
