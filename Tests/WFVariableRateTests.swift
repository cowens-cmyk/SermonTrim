import XCTest
import AVFoundation
import CoreMedia

/// Live-stream style sources: the frame rate changes mid-file and B-frame reordering gets deeper later on.
/// These used to fail with "variable frame timing (decode time passed display time)".
final class WFVariableRateTests: XCTestCase {
    func testFrameRateChangeWithDeepReorderingExportsCleanly() async throws {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wf-vfr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("mixed.mp4"), out = dir.appendingPathComponent("out.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=60", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30",
                       "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                       "-filter_complex", "[0:v]trim=0:8,setpts=PTS-STARTPTS[a];[1:v]trim=0:12,setpts=PTS-STARTPTS,noise=alls=40:allf=t[b];[a][b]concat=n=2:v=1[v]",
                       "-map", "[v]", "-map", "2:a", "-t", "20", "-fps_mode", "vfr", "-c:v", "libx264", "-g", "120", "-bf", "3", "-b_strategy", "2",
                       "-x264-params", "b-pyramid=normal", "-pix_fmt", "yuv420p", "-c:a", "aac", src.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let r = try await ExportEngine().export(source: src, output: out,
            spec: TrimSpec(inTime: CMTime(seconds: 1.5, preferredTimescale: 600), outTime: CMTime(seconds: 19, preferredTimescale: 600),
                           start: Transition(kind: .fadeBlack, duration: 0.5), end: Transition(kind: .fadeBlack, duration: 2))) { _ in }
        XCTAssertNotNil(r.plan.mid, "the middle is still stream-copied")

        // Every packet: decode time strictly increasing and never after display time.
        let asset = AVURLAsset(url: out)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(o); reader.startReading()
        var lastDTS = -Double.infinity
        var pts: [Double] = []
        while let sb = o.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sb) > 0 else { continue }
            let d = CMSampleBufferGetDecodeTimeStamp(sb).seconds, t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            XCTAssertGreaterThan(d, lastDTS, "decode times strictly increase")
            XCTAssertLessThanOrEqual(d, t + 1e-9, "decode time never after display time")
            lastDTS = d; pts.append(t)
        }
        // No duplicate or near-duplicate frames: every gap is ~1/60 s or ~1/30 s, like the source.
        pts.sort()
        for (a, b) in zip(pts, pts.dropFirst()) {
            let g = b - a
            XCTAssertTrue(abs(g - 1.0 / 60) < 0.002 || abs(g - 1.0 / 30) < 0.002, "unexpected frame gap \(g) at \(a)")
        }
    }
}
