import XCTest
import AVFoundation
import CoreMedia
import CoreVideo

// Real exports of synthetic ffmpeg clips, checking frames, bytes, pixels and audio levels.

enum WFMedia {
    static func ffmpegPath() -> String? {
        var candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/ffmpeg" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Skips when ffmpeg is missing, except on CI (or with REQUIRE_FFMPEG set), where a skip would hide the export tests.
    static func requireFFmpeg(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        if let f = ffmpegPath() { return f }
        let env = ProcessInfo.processInfo.environment
        if env["CI"] != nil || env["REQUIRE_FFMPEG"] != nil {
            XCTFail("ffmpeg is required for the export tests", file: file, line: line)
        }
        throw XCTSkip("ffmpeg not installed")
    }

    static func ffmpeg(_ args: [String], to url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try requireFFmpeg())
        p.arguments = ["-v", "error", "-y"] + args + [url.path]
        p.standardInput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "ffmpeg failed: \(args)")
    }

    /// 30 fps 640x360 H.264 with a fixed 3 s GOP (IDR at 0, 3, 6, ...), 2 B-frames, mono 48 kHz sine audio.
    static func h264Args(seconds: Int, gop: Int = 90, bframes: Int = 2, audio: Bool = true, extraVideo: [String] = []) -> [String] {
        var a = ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30"]
        if audio { a += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000"] }
        a += ["-t", "\(seconds)", "-c:v", "libx264", "-b:v", "2M", "-g", "\(gop)", "-keyint_min", "\(gop)", "-sc_threshold", "0",
              "-bf", "\(bframes)", "-pix_fmt", "yuv420p"] + extraVideo
        if audio { a += ["-c:a", "aac", "-b:a", "128k"] }
        return a
    }

    static func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60000) }

    struct Packet { var pts: Double; var data: Data }

    /// Compressed video samples in decode order (no decoding).
    static func packets(_ url: URL, range: CMTimeRange? = nil) async throws -> [Packet] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        if let range { reader.timeRange = range }
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var result: [Packet] = []
        while let sb = out.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sb) > 0, let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMBlockBufferGetDataLength(bb)
            var d = Data(count: n)
            d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
            result.append(Packet(pts: CMSampleBufferGetPresentationTimeStamp(sb).seconds_, data: d))
        }
        return result
    }

    /// Mean luma (code values, 0-255 or 0-1023) of each decoded frame, keyed by presentation time.
    static func lumaMeans(_ url: URL, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                          range: CMTimeRange? = nil) async throws -> [(pts: Double, luma: Double)] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        if let range { reader.timeRange = range }
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        let tenBit = pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        var result: [(Double, Double)] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
            var sum = 0.0, n = 0.0
            for r in Swift.stride(from: 0, to: h, by: 4) {
                for x in Swift.stride(from: 0, to: w, by: 4) {
                    if tenBit { sum += Double((base + r * stride).assumingMemoryBound(to: UInt16.self)[x] >> 6) }
                    else { sum += Double((base + r * stride).assumingMemoryBound(to: UInt8.self)[x]) }
                    n += 1
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            result.append((CMSampleBufferGetPresentationTimeStamp(sb).seconds_, sum / n))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// Decoded audio (channel 0) laid out by presentation time; gaps stay 0.
    static func audio(_ url: URL) async throws -> (samples: [Float], rate: Double, channels: Int, firstPTS: Double) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let fds = try await track.load(.formatDescriptions)
        let fd = try XCTUnwrap(fds.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee)
        let rate = asbd.mSampleRate, ch = Int(asbd.mChannelsPerFrame)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        var firstPTS = Double.infinity
        while let sb = out.copyNextSampleBuffer() {
            let n = CMSampleBufferGetNumSamples(sb)
            guard n > 0, let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds_
            firstPTS = min(firstPTS, pts)
            var data = [Float](repeating: 0, count: n * ch)
            _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: min(n * ch * 4, CMBlockBufferGetDataLength(bb)), destination: &data)
            let start = Int((pts * rate).rounded())
            if start + n > samples.count { samples += [Float](repeating: 0, count: start + n - samples.count) }
            for i in 0..<n where start + i >= 0 { samples[start + i] = data[i * ch] }
        }
        return (samples, rate, ch, firstPTS)
    }

    static func rms(_ a: (samples: [Float], rate: Double, channels: Int, firstPTS: Double), _ from: Double, _ to: Double) -> Double {
        let lo = max(0, Int(from * a.rate)), hi = min(a.samples.count, Int(to * a.rate))
        guard hi > lo else { return 0 }
        var s = 0.0
        for i in lo..<hi { s += Double(a.samples[i] * a.samples[i]) }
        return (s / Double(hi - lo)).squareRoot()
    }

    static func ftypBrand(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let d = h.readData(ofLength: 12)
        return String(decoding: d[8..<12], as: UTF8.self)
    }
}

final class WFExportProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ExportProgress] = []
    func add(_ p: ExportProgress) { lock.lock(); items.append(p); lock.unlock() }
    var all: [ExportProgress] { lock.lock(); defer { lock.unlock() }; return items }
}

final class WFExportIntegrationTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-wf-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// 40 s clip, IDR every 3 s.
    func mainClip() throws -> URL {
        let src = dir.appendingPathComponent("src.mp4")
        try WFMedia.ffmpeg(WFMedia.h264Args(seconds: 40), to: src)
        return src
    }

    /// The spec from ExportIntegrationTests: In 1.5, Out 36, 0.5 s fade in, 3 s fade out.
    let fadeSpec = TrimSpec(inTime: WFMedia.t(1.5), outTime: WFMedia.t(36),
                            start: Transition(kind: .fadeBlack, duration: 0.5), end: Transition(kind: .fadeBlack, duration: 3))

    func assertRange(_ r: CMTimeRange?, _ a: Double, _ b: Double, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let r = try XCTUnwrap(r, "\(what) missing", file: file, line: line)
        XCTAssertEqual(r.start.seconds_, a, accuracy: 1e-3, "\(what).start", file: file, line: line)
        XCTAssertEqual(r.end.seconds_, b, accuracy: 1e-3, "\(what).end", file: file, line: line)
    }

    /// Expected boundaries come from the source timeline, including its composition offset.
    func assertFadedPlan(_ plan: ExportPlan, source: URL, spec: TrimSpec,
                         file: StaticString = #filePath, line: UInt = #line) async throws -> (count: Int, duration: Double, fps: Double) {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let info = try await SourceAnalyzer.analyze(asset: asset)
        let keys = AssetKeyframeProvider(asset: asset, info: info)
        let first = try XCTUnwrap(keys.frameTime(atOrAfter: spec.inTime))
        let end = try XCTUnwrap(keys.frameTime(atOrAfter: spec.outTime))
        let headEnd = try XCTUnwrap(keys.keyframe(atOrAfter: CMTimeAdd(first, WFMedia.t(spec.start.effective))))
        let tailStart = try XCTUnwrap(keys.keyframe(atOrBefore: CMTimeSubtract(end, WFMedia.t(spec.end.effective))))
        XCTAssertFalse(plan.isSingleSegment, file: file, line: line)
        XCTAssertEqual(plan.firstFrame.seconds_, first.seconds_, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(plan.endTime.seconds_, end.seconds_, accuracy: 1e-4, file: file, line: line)
        try assertRange(plan.head, first.seconds_, headEnd.seconds_, "head", file: file, line: line)
        try assertRange(plan.mid, headEnd.seconds_, tailStart.seconds_, "mid", file: file, line: line)
        try assertRange(plan.tail, tailStart.seconds_, end.seconds_, "tail", file: file, line: line)
        let reencoded = CMTimeSubtract(headEnd, first).seconds_ + CMTimeSubtract(end, tailStart).seconds_
        XCTAssertEqual(plan.reencodedDuration, reencoded, accuracy: 1e-4, file: file, line: line)
        let duration = CMTimeSubtract(end, first).seconds_
        let frameDuration = 1 / info.frameRate
        return (Int((duration / frameDuration).rounded()), duration, info.frameRate)
    }

    /// Decode to honor the edit list; raw packet PTS can start after presentation time zero.
    /// Every output frame must be present exactly once, one frame apart, starting at 0.
    func assertContinuousFrames(_ url: URL, count: Int, fps: Double = 30, file: StaticString = #filePath, line: UInt = #line) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        XCTAssertEqual(range.start.seconds_, 0, accuracy: 1e-4, "track starts at 0", file: file, line: line)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "\(String(describing: reader.error))", file: file, line: line)
        var pts: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetImageBuffer(sample) != nil else { continue }
            pts.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds_)
        }
        XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))", file: file, line: line)
        XCTAssertEqual(pts.count, count, "decoded frame count", file: file, line: line)
        XCTAssertEqual(pts.first ?? -1, 0, accuracy: 1e-4, "first frame at 0", file: file, line: line)
        var bad = 0
        for i in 1..<max(1, pts.count) where abs(pts[i] - pts[i - 1] - 1 / fps) > 1e-3 {
            bad += 1
            if bad <= 3 { XCTFail("frame step \(pts[i] - pts[i - 1]) at \(pts[i - 1]) -> \(pts[i])", file: file, line: line) }
        }
        XCTAssertEqual(bad, 0, "PTS must rise by exactly one frame everywhere (no duplicate or missing frames at the joins)", file: file, line: line)
    }

    // MARK: Replacements for ExportIntegrationTests.testExportKeepsSizeAndFormat

    /// Exact plan, frame count, PTS continuity across both joins, A/V lengths, format and size.
    func testExportExactPlanFramesAndFormat() async throws {
        let src = try mainClip(), out = dir.appendingPathComponent("out.mp4")
        let progress = WFExportProgressLog()
        let r = try await ExportEngine().export(source: src, output: out, spec: fadeSpec) { progress.add($0) }

        let expected = try await assertFadedPlan(r.plan, source: src, spec: fadeSpec)
        XCTAssertEqual(r.outputURL, out)

        try await assertContinuousFrames(out, count: expected.count, fps: expected.fps)

        let asset = AVURLAsset(url: out)
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(vTracks.first)
        let aTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(aTracks.first)
        let vDur = try await video.load(.timeRange).duration.seconds_
        let aDur = try await audio.load(.timeRange).duration.seconds_
        XCTAssertEqual(vDur, expected.duration, accuracy: 1 / expected.fps + 0.001)
        XCTAssertEqual(aDur, vDur, accuracy: 0.025, "audio and video end together")

        let o = r.report.output, s = r.report.original
        XCTAssertEqual(o.codec, s.codec)
        XCTAssertEqual(o.width, 640)
        XCTAssertEqual(o.height, 360)
        XCTAssertEqual(o.frameRate, s.frameRate, accuracy: 0.01)
        XCTAssertEqual(o.audioCodec, s.audioCodec)
        XCTAssertEqual(o.duration, expected.duration, accuracy: 0.05)

        let expectedRatio = expected.duration / s.duration
        XCTAssertGreaterThan(r.report.sizeRatio, expectedRatio * 0.95)
        XCTAssertLessThan(r.report.sizeRatio, expectedRatio * 1.10)
        let outBytes = try XCTUnwrap(out.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let srcBytes = try XCTUnwrap(src.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(r.report.sizeRatio, Double(outBytes) / Double(srcBytes), accuracy: 1e-9)

        // Progress: non-decreasing, ends at exactly 1 with "Done".
        let fr = progress.all.map(\.fraction)
        XCTAssertFalse(fr.isEmpty)
        for i in 1..<fr.count { XCTAssertGreaterThanOrEqual(fr[i], fr[i - 1] - 1e-9, "progress went back at \(i)") }
        XCTAssertEqual(progress.all.last?.fraction, 1)
        XCTAssertEqual(progress.all.last?.stage, "Done")
        XCTAssertTrue(progress.all.contains { $0.stage == "Writing file" })
    }

    /// The core promise: the middle is copied byte for byte.
    func testMiddleIsByteIdenticalStreamCopy() async throws {
        let src = try mainClip(), out = dir.appendingPathComponent("out.mp4")
        let r = try await ExportEngine().export(source: src, output: out, spec: fadeSpec) { _ in }
        let expected = try await assertFadedPlan(r.plan, source: src, spec: fadeSpec)
        let mid = try XCTUnwrap(r.plan.mid)
        // Read the whole source so a range-limited passthrough reader cannot omit boundary B-frames.
        let sourcePackets = try await WFMedia.packets(src)
        let srcPk = sourcePackets.filter { $0.pts >= mid.start.seconds_ && $0.pts < mid.end.seconds_ }
        let headCount = Int((CMTimeSubtract(mid.start, r.plan.firstFrame).seconds_ * expected.fps).rounded())
        let tailCount = Int((CMTimeSubtract(r.plan.endTime, mid.end).seconds_ * expected.fps).rounded())
        let outputPackets = try await WFMedia.packets(out)
        XCTAssertFalse(srcPk.isEmpty)
        XCTAssertEqual(srcPk.count, Int((mid.duration.seconds_ * expected.fps).rounded()))
        XCTAssertEqual(outputPackets.count, headCount + srcPk.count + tailCount)
        // The head occupies headCount decode slots; the next packet must be the middle's first IDR.
        // Output packet timestamps include retiming/edit-list offsets, so they are not pairing keys.
        let outPk = Array(outputPackets.dropFirst(headCount).prefix(srcPk.count))
        XCTAssertEqual(outPk.count, srcPk.count)
        let differ = zip(srcPk, outPk).filter { $0.0.data != $0.1.data }.count
        XCTAssertEqual(differ, 0, "\(differ) copied frames are not byte-identical to the source")
        let headSource = sourcePackets.filter { $0.pts >= r.plan.firstFrame.seconds_ && $0.pts < mid.start.seconds_ }
        XCTAssertEqual(headSource.count, headCount)
        XCTAssertTrue(zip(headSource, outputPackets.prefix(headCount)).contains { $0.0.data != $0.1.data },
                      "the faded head must actually be re-encoded")
        try await assertContinuousFrames(out, count: expected.count, fps: expected.fps)
    }

    /// The requested fades are really in the picture and the sound.
    func testFadesReachBlackAndSilence() async throws {
        let src = try mainClip(), out = dir.appendingPathComponent("out.mp4")
        _ = try await ExportEngine().export(source: src, output: out, spec: fadeSpec) { _ in }

        let luma = try await WFMedia.lumaMeans(out)
        let first = try XCTUnwrap(luma.first), last = try XCTUnwrap(luma.last)
        XCTAssertEqual(first.pts, 0, accuracy: 1e-3)
        XCTAssertEqual(first.luma, 16, accuracy: 2, "first frame is black")
        XCTAssertEqual(last.pts, 34.5 - 1.0 / 30, accuracy: 1e-3)
        XCTAssertEqual(last.luma, 16, accuracy: 2, "last frame is black")
        // Mid-fade-out frame (1.5 s before the end): about half way between black and picture.
        let srcLuma = try await WFMedia.lumaMeans(src, range: CMTimeRange(start: WFMedia.t(16), end: WFMedia.t(36)))
        func srcAt(_ t: Double) -> Double? { srcLuma.first { abs($0.pts - t) < 1e-3 }?.luma }
        let midOut = try XCTUnwrap(luma.first { abs($0.pts - 15.0) < 1e-3 })
        XCTAssertEqual(midOut.luma, try XCTUnwrap(srcAt(16.5)), accuracy: 1.0, "copied middle matches the source")
        let fadeT = 34.5 - 1.5                                     // output time; source time 34.5
        let fadeOut = try XCTUnwrap(luma.first { abs($0.pts - fadeT) < 1e-3 })
        let srcFade = try XCTUnwrap(srcAt(34.5))
        let f = (36 - 1.0 / 30 - 34.5) / (3 - 1.0 / 30)
        XCTAssertEqual(fadeOut.luma, 16 + f * (srcFade - 16), accuracy: 3)

        let a = try await WFMedia.audio(out)
        XCTAssertEqual(a.channels, 1)
        let body = WFMedia.rms(a, 15, 16)
        XCTAssertGreaterThan(body, 0.05)
        XCTAssertLessThan(WFMedia.rms(a, 0, 0.01), body * 0.1, "audio fades in from silence")
        XCTAssertLessThan(WFMedia.rms(a, 34.48, 34.5), body * 0.1, "audio fades out to silence")
        XCTAssertGreaterThan(WFMedia.rms(a, 31.5, 32.0), body * 0.9, "fade-out starts at output time 31.5 s")
    }

    /// The audio covers the very start of the output (it is not shifted or truncated at the front).
    func testAudioStartsWithTheFirstFrame() async throws {
        let src = try mainClip(), out = dir.appendingPathComponent("out.mp4")
        _ = try await ExportEngine().export(source: src, output: out, spec: fadeSpec) { _ in }
        let a = try await WFMedia.audio(out)
        XCTAssertLessThan(a.firstPTS, 0.01)
        let body = WFMedia.rms(a, 15, 16)
        // 0.2-0.3 s into a 0.5 s sine fade-in: gain 0.59-0.81.
        XCTAssertGreaterThan(WFMedia.rms(a, 0.2, 0.3), body * 0.45)
        XCTAssertGreaterThan(WFMedia.rms(a, 0.05, 0.1), body * 0.1)
        XCTAssertEqual(Double(a.samples.count) / a.rate, 34.5, accuracy: 0.03)
    }

    // MARK: Cancellation (replaces ExportIntegrationTests.testCancelStopsExport)

    func testCancelDuringAssemblyRemovesPartialOutput() async throws {
        let src = try mainClip(), out = dir.appendingPathComponent("out.mp4")
        let engine = ExportEngine()
        let seen = WFExportProgressLog()
        do {
            _ = try await engine.export(source: src, output: out, spec: fadeSpec) { p in
                seen.add(p)
                if p.stage == "Writing file" && p.fraction > 0.4 { engine.cancel() }
            }
            XCTFail("expected cancellation")
        } catch ExportError.cancelled {
            XCTAssertTrue(seen.all.contains { $0.stage == "Writing file" && $0.fraction > 0.4 }, "cancelled while writing")
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "partial output removed")
        }
    }

    func testCancelDuringHeadEncode() async throws {
        let src = try mainClip(), out = dir.appendingPathComponent("out.mp4")
        let engine = ExportEngine()
        let seen = WFExportProgressLog()
        do {
            _ = try await engine.export(source: src, output: out, spec: fadeSpec) { p in
                seen.add(p)
                if p.stage == "Re-encoding start" { engine.cancel() }
            }
            XCTFail("expected cancellation")
        } catch ExportError.cancelled {
            XCTAssertFalse(seen.all.contains { $0.stage == "Writing file" }, "never reached assembly")
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
    }

    // MARK: Plan shapes exported for real

    func testCopyToEOFWithNoHeadOrTail() async throws {
        let src = try mainClip(), out = dir.appendingPathComponent("out.mp4")
        let asset = AVURLAsset(url: src, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let info = try await SourceAnalyzer.analyze(asset: asset)
        let keys = AssetKeyframeProvider(asset: asset, info: info)
        let firstKey = try XCTUnwrap(keys.keyframe(atOrAfter: info.timeRange.start))
        let start = try XCTUnwrap(keys.keyframe(atOrAfter: CMTimeAdd(firstKey, info.frameDuration)))
        let end = info.timeRange.end
        let r = try await ExportEngine().export(source: src, output: out, spec: TrimSpec(inTime: start, outTime: end)) { _ in }
        XCTAssertFalse(r.plan.isSingleSegment)
        XCTAssertNil(r.plan.head)
        XCTAssertNil(r.plan.tail)
        XCTAssertEqual(r.plan.firstFrame.seconds_, start.seconds_, accuracy: 1e-4)
        XCTAssertEqual(r.plan.endTime.seconds_, end.seconds_, accuracy: 1e-4)
        try assertRange(r.plan.mid, start.seconds_, end.seconds_, "mid")
        let count = Int((CMTimeSubtract(end, start).seconds_ * info.frameRate).rounded())
        try await assertContinuousFrames(out, count: count, fps: info.frameRate)
        let pk = try await WFMedia.packets(out)
        let srcPk = try await WFMedia.packets(src).filter { $0.pts >= start.seconds_ && $0.pts < end.seconds_ }
        XCTAssertEqual(srcPk.count, count)
        XCTAssertEqual(pk.count, srcPk.count)
        XCTAssertEqual(zip(pk, srcPk).filter { $0.0.data != $0.1.data }.count, 0, "everything is a stream copy, in decode order")
        XCTAssertTrue(r.log.contains { $0.hasPrefix("Stream-copy reorder delay:") })
    }

    func testSingleSegmentShortClip() async throws {
        let src = try mainClip(), out = dir.appendingPathComponent("out.mp4")
        let spec = TrimSpec(inTime: WFMedia.t(10.2), outTime: WFMedia.t(11.9),
                            start: Transition(kind: .fadeBlack, duration: 0.5), end: Transition(kind: .fadeBlack, duration: 0.5))
        let r = try await ExportEngine().export(source: src, output: out, spec: spec) { _ in }
        XCTAssertTrue(r.plan.isSingleSegment)
        try assertRange(r.plan.head, 10.2, 11.9, "head")
        _ = try await assertContinuousFrames(out, count: 51)
        XCTAssertTrue(r.log.contains("Stream-copy reorder delay: 0 frames"))
        let luma = try await WFMedia.lumaMeans(out)
        XCTAssertEqual(try XCTUnwrap(luma.first).luma, 16, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(luma.last).luma, 16, accuracy: 2)
    }

    func testHeadAndTailWithoutMiddle() async throws {
        let src = try mainClip(), out = dir.appendingPathComponent("out.mp4")
        let asset = AVURLAsset(url: src, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let info = try await SourceAnalyzer.analyze(asset: asset)
        let keys = AssetKeyframeProvider(asset: asset, info: info)
        let join = try XCTUnwrap(keys.keyframe(atOrAfter: WFMedia.t(1)))
        // Both fade boundaries land exactly on the same actual keyframe.
        let start = CMTimeSubtract(join, WFMedia.t(2))
        let end = CMTimeAdd(join, WFMedia.t(2.8))
        let spec = TrimSpec(inTime: start, outTime: end,
                            start: Transition(kind: .fadeBlack, duration: 2), end: Transition(kind: .fadeWhite, duration: 2.8))
        let r = try await ExportEngine().export(source: src, output: out, spec: spec) { _ in }
        XCTAssertFalse(r.plan.isSingleSegment)
        XCTAssertEqual(r.plan.firstFrame.seconds_, start.seconds_, accuracy: 1e-4)
        XCTAssertEqual(r.plan.endTime.seconds_, end.seconds_, accuracy: 1e-4)
        try assertRange(r.plan.head, start.seconds_, join.seconds_, "head")
        XCTAssertNil(r.plan.mid)
        try assertRange(r.plan.tail, join.seconds_, end.seconds_, "tail")
        let count = Int((CMTimeSubtract(end, start).seconds_ * info.frameRate).rounded())
        try await assertContinuousFrames(out, count: count, fps: info.frameRate)
        let luma = try await WFMedia.lumaMeans(out)
        XCTAssertEqual(try XCTUnwrap(luma.first).luma, 16, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(luma.last).luma, 235, accuracy: 2, "fade to white ends on white")
    }

    func testNoBFramesHasZeroReorderDelay() async throws {
        let src = dir.appendingPathComponent("nob.mp4"), out = dir.appendingPathComponent("out.mp4")
        try WFMedia.ffmpeg(WFMedia.h264Args(seconds: 12, gop: 60, bframes: 0), to: src)
        let spec = TrimSpec(inTime: WFMedia.t(1), outTime: WFMedia.t(11), end: Transition(kind: .fadeBlack, duration: 1))
        let r = try await ExportEngine().export(source: src, output: out, spec: spec) { _ in }
        let expected = try await assertFadedPlan(r.plan, source: src, spec: spec)
        let line = try XCTUnwrap(r.log.first { $0.hasPrefix("Stream-copy reorder delay:") })
        let value = try XCTUnwrap(line.dropFirst("Stream-copy reorder delay: ".count).split(separator: " ").first)
        let frames = try XCTUnwrap(Int(value))
        XCTAssertGreaterThanOrEqual(frames, 0)
        // Rounding the measured lag up can legitimately report one frame even without B-frames.
        XCTAssertLessThanOrEqual(frames, 1, "\(r.log)")
        try await assertContinuousFrames(out, count: expected.count, fps: expected.fps)
    }

    func testBFramesNeedReorderDelay() async throws {
        let src = try mainClip(), out = dir.appendingPathComponent("out.mp4")
        let r = try await ExportEngine().export(source: src, output: out, spec: fadeSpec) { _ in }
        let line = try XCTUnwrap(r.log.first { $0.hasPrefix("Stream-copy reorder delay:") })
        XCTAssertNotEqual(line, "Stream-copy reorder delay: 0 frames")
    }

    // MARK: Source variants

    func testVideoOnlySourceExportsVideoOnly() async throws {
        let src = dir.appendingPathComponent("silent.mp4"), out = dir.appendingPathComponent("out.mp4")
        try WFMedia.ffmpeg(WFMedia.h264Args(seconds: 10, gop: 60, audio: false), to: src)
        let spec = TrimSpec(inTime: WFMedia.t(1), outTime: WFMedia.t(9), end: Transition(kind: .fadeBlack, duration: 1))
        let r = try await ExportEngine().export(source: src, output: out, spec: spec) { _ in }
        let expected = try await assertFadedPlan(r.plan, source: src, spec: spec)
        XCTAssertEqual(r.report.output.audioCodec, "none")
        let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio)
        XCTAssertTrue(tracks.isEmpty)
        try await assertContinuousFrames(out, count: expected.count, fps: expected.fps)
    }

    func testStereoSourceStaysStereo() async throws {
        let src = dir.appendingPathComponent("stereo.mp4"), out = dir.appendingPathComponent("out.mp4")
        try WFMedia.ffmpeg(WFMedia.h264Args(seconds: 10, gop: 60) + ["-ac", "2"], to: src)
        _ = try await ExportEngine().export(source: src, output: out,
                                            spec: TrimSpec(inTime: WFMedia.t(1), outTime: WFMedia.t(9), end: Transition(kind: .fadeBlack, duration: 1))) { _ in }
        let a = try await WFMedia.audio(out)
        XCTAssertEqual(a.channels, 2)
        XCTAssertEqual(a.rate, 48000)
        XCTAssertEqual(Double(a.samples.count) / a.rate, 8, accuracy: 0.03)
    }

    func testFullRangeSourceFadesToFullRangeBlack() async throws {
        let src = dir.appendingPathComponent("full.mp4"), out = dir.appendingPathComponent("out.mp4")
        try WFMedia.ffmpeg(WFMedia.h264Args(seconds: 10, gop: 60, extraVideo: ["-vf", "scale=out_range=full", "-color_range", "pc"]), to: src)
        let info = try await SourceAnalyzer.analyze(asset: AVURLAsset(url: src))
        XCTAssertTrue(info.isFullRange)
        _ = try await ExportEngine().export(source: src, output: out,
                                            spec: TrimSpec(inTime: WFMedia.t(1), outTime: WFMedia.t(9),
                                                           start: Transition(kind: .fadeBlack, duration: 0.5), end: Transition(kind: .fadeWhite, duration: 1))) { _ in }
        let outInfo = try await SourceAnalyzer.analyze(asset: AVURLAsset(url: out))
        XCTAssertTrue(outInfo.isFullRange)
        let luma = try await WFMedia.lumaMeans(out, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(try XCTUnwrap(luma.first).luma, 0, accuracy: 3, "full-range black is 0, not 16")
        XCTAssertEqual(try XCTUnwrap(luma.last).luma, 255, accuracy: 3, "full-range white is 255, not 235")
    }

    func testHEVC10BitExport() async throws {
        let src = dir.appendingPathComponent("hevc10.mp4"), out = dir.appendingPathComponent("out.mp4")
        try WFMedia.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                            "-t", "10", "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-profile:v", "main10", "-tag:v", "hvc1",
                            "-x265-params", "keyint=60:min-keyint=60:scenecut=0:open-gop=0:bframes=2:log-level=error", "-b:v", "2M",
                            "-c:a", "aac"], to: src)
        let info = try await SourceAnalyzer.analyze(asset: AVURLAsset(url: src))
        XCTAssertTrue(info.isHEVC)
        XCTAssertEqual(info.bitDepth, 10)
        let spec = TrimSpec(inTime: WFMedia.t(1), outTime: WFMedia.t(9),
                            start: Transition(kind: .fadeBlack, duration: 0.5), end: Transition(kind: .fadeBlack, duration: 1))
        let r = try await ExportEngine().export(source: src, output: out, spec: spec) { _ in }
        let expected = try await assertFadedPlan(r.plan, source: src, spec: spec)
        XCTAssertEqual(r.report.output.codec, "hvc1")
        let outInfo = try await SourceAnalyzer.analyze(asset: AVURLAsset(url: out))
        XCTAssertEqual(outInfo.bitDepth, 10)
        try await assertContinuousFrames(out, count: expected.count, fps: expected.fps)
        let luma = try await WFMedia.lumaMeans(out, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(try XCTUnwrap(luma.first).luma, 64, accuracy: 6, "10-bit video-range black")
        let mid = try XCTUnwrap(luma.first { abs($0.pts - 4) < 1e-3 })
        XCTAssertGreaterThan(mid.luma, 150, "copied picture is not faded")
    }

    func testMovOutputUsesQuickTimeContainer() async throws {
        let src = try mainClip(), out = dir.appendingPathComponent("out.mov")
        let r = try await ExportEngine().export(source: src, output: out, spec: fadeSpec) { _ in }
        let expected = try await assertFadedPlan(r.plan, source: src, spec: fadeSpec)
        XCTAssertEqual(try WFMedia.ftypBrand(out), "qt  ")
        XCTAssertEqual(r.report.output.duration, expected.duration, accuracy: 0.05)
        try await assertContinuousFrames(out, count: expected.count, fps: expected.fps)
        let mp4 = dir.appendingPathComponent("out.mp4")
        _ = try await ExportEngine().export(source: src, output: mp4, spec: fadeSpec) { _ in }
        XCTAssertNotEqual(try WFMedia.ftypBrand(mp4), "qt  ")
    }

    // MARK: Metadata (engine capability; replaces the self-checking parts of SermonExportTests)

    func testEngineWritesMetadataWhenGivenSermonInfo() async throws {
        let src = try mainClip(), out = dir.appendingPathComponent("out.mp4")
        let info = SermonInfo(title: "The Lord Sees", date: SermonNaming.gregorian.date(from: DateComponents(year: 2026, month: 10, day: 4))!, speaker: "Rick")
        let r = try await ExportEngine().export(source: src, output: out, spec: fadeSpec, sermon: info) { _ in }
        XCTAssertEqual(r.outputURL, out)
        let asset = AVURLAsset(url: r.outputURL)
        var title: String?, artist: String?
        for fmt in try await asset.load(.availableMetadataFormats) {
            for i in try await asset.loadMetadata(for: fmt) {
                let v = try await i.load(.stringValue)
                if i.commonKey == .commonKeyTitle || i.identifier == .iTunesMetadataSongName { title = v }
                if i.commonKey == .commonKeyArtist || i.identifier == .iTunesMetadataArtist { artist = v }
            }
        }
        XCTAssertEqual(title, "The Lord Sees")
        XCTAssertEqual(artist, "Rick")
    }
}

// MARK: - Source analysis and keyframe lookup on real files

final class WFExportSourceTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-wf-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { if let dir { try? FileManager.default.removeItem(at: dir) } }

    func testAnalyzeReportsFormat() async throws {
        let src = dir.appendingPathComponent("a.mp4")
        try WFMedia.ffmpeg(WFMedia.h264Args(seconds: 4, gop: 60), to: src)
        let info = try await SourceAnalyzer.analyze(asset: AVURLAsset(url: src))
        XCTAssertTrue(info.isH264)
        XCTAssertEqual(info.width, 640)
        XCTAssertEqual(info.height, 360)
        XCTAssertEqual(info.frameRate, 30, accuracy: 0.01)
        XCTAssertEqual(info.frameDuration.seconds_, 1.0 / 30, accuracy: 1e-6)
        XCTAssertEqual(info.bitDepth, 8)
        XCTAssertFalse(info.isFullRange)
    }

    func testAudioOnlyFileHasNoVideoTrack() async throws {
        let src = dir.appendingPathComponent("a.m4a")
        try WFMedia.ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440", "-t", "2", "-c:a", "aac"], to: src)
        do {
            _ = try await SourceAnalyzer.analyze(asset: AVURLAsset(url: src))
            XCTFail("expected noVideoTrack")
        } catch ExportError.noVideoTrack {}
    }

    func testUnsupportedCodecNamesFourCC() async throws {
        let src = dir.appendingPathComponent("m.mp4")
        try WFMedia.ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-t", "1", "-c:v", "mpeg4"], to: src)
        do {
            _ = try await SourceAnalyzer.analyze(asset: AVURLAsset(url: src))
            XCTFail("expected unsupported")
        } catch ExportError.unsupported(let msg) {
            XCTAssertTrue(msg.contains("mp4v"), msg)
            XCTAssertTrue(msg.contains("only H.264 and HEVC"), msg)
        }
    }

    func testAssetKeyframeProviderFindsIDRs() async throws {
        for bframes in [0, 2] {
            let src = dir.appendingPathComponent("k-\(bframes).mp4")
            try WFMedia.ffmpeg(WFMedia.h264Args(seconds: 10, gop: 60, bframes: bframes), to: src)
            let asset = AVURLAsset(url: src, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let info = try await SourceAnalyzer.analyze(asset: asset)
            let k = AssetKeyframeProvider(asset: asset, info: info)
            // Independent oracle: sync samples in this fixed, closed-GOP x264 fixture are IDRs.
            // Cursor presentation times include the source's actual composition offset.
            let cursor = try XCTUnwrap(info.track.makeSampleCursor(presentationTimeStamp: .zero))
            var idrs: [CMTime] = []
            repeat {
                if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue { idrs.append(cursor.presentationTimeStamp) }
            } while cursor.stepInDecodeOrder(byCount: 1) != 0
            idrs.sort { CMTimeCompare($0, $1) < 0 }
            XCTAssertEqual(idrs.count, 5)
            let first = try XCTUnwrap(idrs.first), last = try XCTUnwrap(idrs.last)
            let frame = WFMedia.t(1 / info.frameRate)
            func s(_ t: CMTime?) -> Double { t?.seconds_ ?? -1 }
            for (i, key) in idrs.enumerated() {
                XCTAssertEqual(s(k.keyframe(atOrBefore: key)), key.seconds_, accuracy: 1e-4)
                XCTAssertEqual(s(k.keyframe(atOrAfter: key)), key.seconds_, accuracy: 1e-4)
                if i > 0 {
                    XCTAssertEqual(CMTimeSubtract(key, idrs[i - 1]).seconds_, 60 / info.frameRate, accuracy: 1e-4)
                    XCTAssertEqual(s(k.keyframe(atOrBefore: CMTimeSubtract(key, frame))), idrs[i - 1].seconds_, accuracy: 1e-4)
                    XCTAssertEqual(s(k.keyframe(atOrAfter: CMTimeAdd(idrs[i - 1], frame))), key.seconds_, accuracy: 1e-4)
                }
            }
            XCTAssertNil(k.keyframe(atOrBefore: CMTimeSubtract(first, frame)), "before the first IDR")
            XCTAssertNil(k.keyframe(atOrAfter: CMTimeAdd(last, frame)), "past the last GOP")
            let onFrame = CMTimeAdd(first, CMTimeMultiply(frame, multiplier: 45))
            XCTAssertEqual(s(k.frameTime(atOrAfter: onFrame)), onFrame.seconds_, accuracy: 1e-4)
            let betweenFrames = CMTimeAdd(onFrame, CMTimeMultiplyByFloat64(frame, multiplier: 0.75))
            XCTAssertEqual(s(k.frameTime(atOrAfter: betweenFrames)), CMTimeAdd(onFrame, frame).seconds_, accuracy: 1e-4)
        }
    }

    func testPreflightOnRealFile() async throws {
        let src = dir.appendingPathComponent("p.mp4")
        try WFMedia.ffmpeg(WFMedia.h264Args(seconds: 10, gop: 60), to: src)
        let asset = AVURLAsset(url: src, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let info = try await SourceAnalyzer.analyze(asset: asset)
        let keys = AssetKeyframeProvider(asset: asset, info: info)
        let startKey = try XCTUnwrap(keys.keyframe(atOrAfter: WFMedia.t(1)))
        let endKey = try XCTUnwrap(keys.keyframe(atOrBefore: info.timeRange.end))
        let onKeys = try await ExportEngine.preflight(source: src, spec: TrimSpec(inTime: startKey, outTime: endKey))
        XCTAssertEqual(onKeys.summary, "Copies everything as-is")
        XCTAssertEqual(onKeys.totalSeconds, CMTimeSubtract(endKey, startKey).seconds_, accuracy: 1e-4)
        XCTAssertEqual(onKeys.reencodedSeconds, 0)
        XCTAssertFalse(onKeys.plan.isSingleSegment)
        XCTAssertNil(onKeys.plan.head)
        XCTAssertNil(onKeys.plan.tail)
        let copy = try XCTUnwrap(onKeys.plan.mid)
        XCTAssertEqual(copy.start.seconds_, startKey.seconds_, accuracy: 1e-4)
        XCTAssertEqual(copy.end.seconds_, endKey.seconds_, accuracy: 1e-4)

        let spec = TrimSpec(inTime: WFMedia.t(1), outTime: WFMedia.t(9), end: Transition(kind: .fadeBlack, duration: 1))
        let first = try XCTUnwrap(keys.frameTime(atOrAfter: spec.inTime))
        let end = try XCTUnwrap(keys.frameTime(atOrAfter: spec.outTime))
        let headEnd = try XCTUnwrap(keys.keyframe(atOrAfter: first))
        let tailStart = try XCTUnwrap(keys.keyframe(atOrBefore: CMTimeSubtract(end, WFMedia.t(spec.end.effective))))
        let total = CMTimeSubtract(end, first).seconds_
        let reencoded = CMTimeSubtract(headEnd, first).seconds_ + CMTimeSubtract(end, tailStart).seconds_
        let pf = try await ExportEngine.preflight(source: src, spec: spec)
        XCTAssertFalse(pf.plan.isSingleSegment)
        let head = try XCTUnwrap(pf.plan.head), mid = try XCTUnwrap(pf.plan.mid), tail = try XCTUnwrap(pf.plan.tail)
        XCTAssertEqual(head.start.seconds_, first.seconds_, accuracy: 1e-4)
        XCTAssertEqual(head.end.seconds_, headEnd.seconds_, accuracy: 1e-4)
        XCTAssertEqual(mid.start.seconds_, headEnd.seconds_, accuracy: 1e-4)
        XCTAssertEqual(mid.end.seconds_, tailStart.seconds_, accuracy: 1e-4)
        XCTAssertEqual(tail.start.seconds_, tailStart.seconds_, accuracy: 1e-4)
        XCTAssertEqual(tail.end.seconds_, end.seconds_, accuracy: 1e-4)
        XCTAssertEqual(pf.totalSeconds, total, accuracy: 1e-4)
        XCTAssertEqual(pf.reencodedSeconds, reencoded, accuracy: 1e-4)
        XCTAssertEqual(pf.copiedSeconds, CMTimeSubtract(tailStart, headEnd).seconds_, accuracy: 1e-4)
        XCTAssertEqual(pf.summary, String(format: "Copies %.1f%% as-is · re-encodes %.1f s", (total - reencoded) / total * 100, reencoded))
        XCTAssertFalse(pf.isHeavy)
    }
}
