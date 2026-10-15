import XCTest
import CoreMedia
import CoreVideo

// Unit tests for ExportPlan, FadeEnvelope, Transition, PixelFader, FileComparison, Preflight,
// uniqueOutputURL and timecodes. No media files needed.

/// Keyframe provider with an explicit, finite keyframe list (like a real file: nil past the last GOP).
struct WFListKeyframes: KeyframeProvider {
    var keyframes: [Double]
    var fps = 60.0
    var snapFrames = true
    func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60000) }
    func keyframe(atOrBefore t: CMTime) -> CMTime? { keyframes.last { $0 <= t.seconds_ + 1e-9 }.map { self.t($0) } }
    func keyframe(atOrAfter t: CMTime) -> CMTime? { keyframes.first { $0 >= t.seconds_ - 1e-9 }.map { self.t($0) } }
    func frameTime(atOrAfter t: CMTime) -> CMTime? {
        snapFrames ? self.t(((t.seconds_ * fps) - 1e-6).rounded(.up) / fps) : nil
    }
    /// Keyframes every `gop` seconds from 0 through `last` (inclusive).
    static func grid(gop: Double = 3.2, last: Double) -> WFListKeyframes {
        WFListKeyframes(keyframes: stride(from: 0.0, through: last + 1e-9, by: gop).map { ($0 * 1000).rounded() / 1000 })
    }
}

final class WFExportPlanTests: XCTestCase {
    let frame = CMTime(value: 1, timescale: 60)
    let trackEnd = CMTime(seconds: 100, preferredTimescale: 60000)
    func spec(_ a: Double, _ b: Double, _ s: Transition = .none, _ e: Transition = .none) -> TrimSpec {
        TrimSpec(inTime: CMTime(seconds: a, preferredTimescale: 60000), outTime: CMTime(seconds: b, preferredTimescale: 60000), start: s, end: e)
    }
    func fade(_ d: Double) -> Transition { Transition(kind: .fadeBlack, duration: d) }
    func plan(_ s: TrimSpec, _ k: KeyframeProvider = FakeKeyframes()) throws -> ExportPlan {
        try ExportPlan.make(spec: s, trackEnd: trackEnd, frameDuration: frame, keyframes: k)
    }
    func assertRange(_ r: CMTimeRange?, _ a: Double, _ b: Double, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let r = try XCTUnwrap(r, "\(what) missing", file: file, line: line)
        XCTAssertEqual(r.start.seconds_, a, accuracy: 0.001, "\(what).start", file: file, line: line)
        XCTAssertEqual(r.end.seconds_, b, accuracy: 0.001, "\(what).end", file: file, line: line)
    }
    func assertInvalidRange(_ s: TrimSpec, _ k: KeyframeProvider = FakeKeyframes(), file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try plan(s, k), file: file, line: line) { e in
            guard case ExportError.invalidRange = e else { return XCTFail("expected invalidRange, got \(e)", file: file, line: line) }
        }
    }

    // MARK: Head/tail overlap guard (line 61)

    /// The fade-in head ends on exactly the keyframe where the fade-out tail starts: two re-encoded
    /// segments that touch, not a fall-back to re-encoding everything.
    func testHeadEndingExactlyOnTailKeyframeIsNotSingleSegment() throws {
        // head: keyframe >= 1 + 2 = 3.2; tail: keyframe <= 6.0 - 2.8 = 3.2
        let p = try plan(spec(1.0, 6.0, fade(2), fade(2.8)))
        XCTAssertFalse(p.isSingleSegment)
        try assertRange(p.head, 1.0, 3.2, "head")
        XCTAssertNil(p.mid)
        try assertRange(p.tail, 3.2, 6.0, "tail")
        XCTAssertEqual(p.reencodedDuration, 5.0, accuracy: 0.001)
    }

    /// Same guard with a real stream-copied middle: head end one GOP before the tail start.
    func testHeadOneGopBeforeTailKeepsMiddleCopy() throws {
        let p = try plan(spec(1.0, 9.2, fade(2), fade(2.8)))   // head end 3.2, tail start keyframe <= 6.4 -> 6.4
        XCTAssertFalse(p.isSingleSegment)
        try assertRange(p.head, 1.0, 3.2, "head")
        try assertRange(p.mid, 3.2, 6.4, "mid")
        try assertRange(p.tail, 6.4, 9.2, "tail")
    }

    func testOverlappingHeadAndTailFallBackToSingleSegment() throws {
        // head keyframe >= 3.5 -> 6.4 (< end 7); tail keyframe <= 4.0 -> 3.2: they overlap.
        let p = try plan(spec(1, 7, fade(2.5), fade(3)))
        XCTAssertTrue(p.isSingleSegment)
        try assertRange(p.head, 1, 7, "head")
        XCTAssertNil(p.mid)
        XCTAssertNil(p.tail)
    }

    // MARK: Replacements for loose PlanTests

    /// Replaces PlanTests.testFadeInLongerThanGopExtendsHeadToLaterKeyframe (exact plan).
    func testFadeInLongerThanGopStopsAtNextKeyframeAfterFade() throws {
        let p = try plan(spec(1.0, 90, fade(4), .none))
        XCTAssertFalse(p.isSingleSegment)
        try assertRange(p.head, 1.0, 6.4, "head")
        try assertRange(p.mid, 6.4, 89.6, "mid")
        try assertRange(p.tail, 89.6, 90, "tail")
    }

    func testFadeInEndingExactlyOnKeyframeDoesNotOvershoot() throws {
        let p = try plan(spec(2.4, 90, fade(4), .none))         // 2.4 + 4 = 6.4 is a keyframe
        try assertRange(p.head, 2.4, 6.4, "head")
        try assertRange(p.mid, 6.4, 89.6, "mid")
    }

    /// Replaces PlanTests.testTrimStartAndFadeOutSplitsHeadMidTail (exact values, no force unwraps).
    func testTrimStartAndFadeOutExactPlan() throws {
        let p = try plan(spec(1.5, 90, .none, fade(3)))
        XCTAssertFalse(p.isSingleSegment)
        XCTAssertEqual(p.firstFrame.seconds_, 1.5, accuracy: 0.001)
        XCTAssertEqual(p.endTime.seconds_, 90, accuracy: 0.001)
        try assertRange(p.head, 1.5, 3.2, "head")
        try assertRange(p.mid, 3.2, 86.4, "mid")
        try assertRange(p.tail, 86.4, 90, "tail")
        XCTAssertEqual(p.reencodedDuration, 5.3, accuracy: 0.001)
    }

    /// Replaces PlanTests.testVeryShortClipFallsBackToSingleSegment.
    func testVeryShortClipSingleSegmentExact() throws {
        let p = try plan(spec(10, 12, fade(0.5), fade(0.5)))
        XCTAssertTrue(p.isSingleSegment)
        try assertRange(p.head, 10, 12, "head")
        XCTAssertNil(p.mid)
        XCTAssertNil(p.tail)
        XCTAssertEqual(p.reencodedDuration, 2, accuracy: 0.001)
    }

    // MARK: End of file

    /// Strengthens PlanTests.testOutAtEndOfFileWithoutFadeCopiesToEnd.
    func testOutAtEOFWithoutFadeCopiesToEndWithNoHead() throws {
        let p = try plan(spec(3.2, 100))
        XCTAssertFalse(p.isSingleSegment)
        XCTAssertNil(p.head)
        XCTAssertNil(p.tail)
        try assertRange(p.mid, 3.2, 100, "mid")
        XCTAssertEqual(p.reencodedDuration, 0, accuracy: 1e-9)
    }

    func testOutWithinHalfFrameOfEOFCountsAsEOF() throws {
        let p = try plan(spec(3.2, 99.995))                 // 100 - 1/120 = 99.9917
        XCTAssertNil(p.tail)
        XCTAssertEqual(p.endTime.seconds_, 100, accuracy: 1e-6)
        try assertRange(p.mid, 3.2, 100, "mid")
    }

    func testOutJustMoreThanHalfFrameBeforeEOFIsNotEOF() throws {
        let p = try plan(spec(3.2, 99.99))                  // snaps to the 100 s frame but is a normal Out point
        try assertRange(p.mid, 3.2, 99.2, "mid")
        try assertRange(p.tail, 99.2, 100, "tail")
    }

    func testOutBeyondTrackEndClampsToTrackEnd() throws {
        let p = try plan(spec(3.2, 120))
        XCTAssertEqual(p.endTime.seconds_, 100, accuracy: 1e-6)
        XCTAssertNil(p.tail)
        try assertRange(p.mid, 3.2, 100, "mid")
    }

    func testOutAtEOFWithFadeStillReencodesTail() throws {
        let p = try plan(spec(3.2, 100, .none, fade(2)))
        XCTAssertFalse(p.isSingleSegment)
        XCTAssertNil(p.head)
        try assertRange(p.mid, 3.2, 96.0, "mid")
        try assertRange(p.tail, 96.0, 100, "tail")
    }

    // MARK: Head variants

    func testInOnKeyframeWithFadeInStillReencodesHead() throws {
        let p = try plan(spec(3.2, 90, fade(1), .none))
        try assertRange(p.head, 3.2, 6.4, "head")
        try assertRange(p.mid, 6.4, 89.6, "mid")
        try assertRange(p.tail, 89.6, 90, "tail")
    }

    func testInOnKeyframeWithOnlyFadeOutHasNoHead() throws {
        let p = try plan(spec(3.2, 90, .none, fade(3)))
        XCTAssertFalse(p.isSingleSegment)
        XCTAssertNil(p.head)
        try assertRange(p.mid, 3.2, 86.4, "mid")
        try assertRange(p.tail, 86.4, 90, "tail")
    }

    // MARK: Transition.effective (kind .none with a leftover duration)

    func testTransitionNoneIgnoresDuration() {
        XCTAssertEqual(Transition(kind: .none, duration: 3).effective, 0)
        XCTAssertEqual(Transition(kind: .fadeBlack, duration: -2).effective, 0)
        XCTAssertEqual(Transition(kind: .fadeWhite, duration: 1.5).effective, 1.5)
    }

    func testNoneTransitionWithDurationDoesNotAddReencode() throws {
        let leftover = Transition(kind: .none, duration: 3)
        let p = try plan(spec(3.2, 90, leftover, leftover))
        XCTAssertNil(p.head)                                 // no fade-in -> In on keyframe needs no head
        try assertRange(p.mid, 3.2, 89.6, "mid")             // keyframe <= 90, not <= 87
        try assertRange(p.tail, 89.6, 90, "tail")
        let p2 = try plan(spec(3.2, 100, .none, leftover))
        XCTAssertNil(p2.tail)                                // copies to EOF
    }

    func testNoneTransitionWithDurationDoesNotFadeAudio() {
        let leftover = Transition(kind: .none, duration: 3)
        let e = FadeEnvelope(start: leftover, end: leftover, firstFrame: 10, endTime: 100, frameDuration: 1.0 / 60)
        XCTAssertEqual(e.audioGain(at: 11), 1, accuracy: 1e-9)
        XCTAssertEqual(e.audioGain(at: 99), 1, accuracy: 1e-9)
        XCTAssertEqual(e.videoFactors(at: 10).fadeIn, 1)
        XCTAssertEqual(e.videoFactors(at: 100 - 1.0 / 60).fadeOut, 1)
    }

    // MARK: Fallbacks with a finite keyframe list

    func testInAfterLastKeyframeFallsBackToSingleSegment() throws {
        let k = WFListKeyframes.grid(last: 96.0)
        let p = try plan(spec(97, 99.5), k)
        XCTAssertTrue(p.isSingleSegment)
        try assertRange(p.head, 97, 99.5, "head")
        XCTAssertNil(p.mid)
        XCTAssertNil(p.tail)
    }

    func testNoKeyframeBeforeOutPointFallsBackToSingleSegment() throws {
        // head ends at keyframe 5.0 (< end 7) but there is no keyframe <= 7 - 3 = 4.
        let k = WFListKeyframes(keyframes: [5.0, 50.0])
        let p = try plan(spec(1, 7, .none, fade(3)), k)
        XCTAssertTrue(p.isSingleSegment)
        try assertRange(p.head, 1, 7, "head")
        XCTAssertNil(p.mid)
        XCTAssertNil(p.tail)
    }

    func testFiniteGridMatchesInfiniteGridInsideTheFile() throws {
        let p = try plan(spec(1.5, 90, .none, fade(3)), WFListKeyframes.grid(last: 99.2))
        try assertRange(p.head, 1.5, 3.2, "head")
        try assertRange(p.mid, 3.2, 86.4, "mid")
        try assertRange(p.tail, 86.4, 90, "tail")
    }

    func testFrameTimeNilFallsBackToRawTimes() throws {
        var k = WFListKeyframes.grid(last: 99.2)
        k.snapFrames = false
        let p = try plan(spec(1.003, 90.004, .none, .none), k)
        XCTAssertEqual(p.firstFrame.seconds_, 1.003, accuracy: 1e-4)   // raw time, not snapped to 61/60
        XCTAssertEqual(p.endTime.seconds_, 90.004, accuracy: 1e-4)
    }

    // MARK: Invalid ranges (replaces PlanTests.testInvalidRangeThrows)

    func testInvalidRangesThrowInvalidRange() {
        assertInvalidRange(spec(10, 5))
        assertInvalidRange(spec(10, 10))
        assertInvalidRange(spec(10.001, 10.005))   // valid before snapping, empty after (both snap to 601/60)
    }
}

// MARK: - Fade envelope

final class WFExportEnvelopeTests: XCTestCase {
    let fd = 1.0 / 60
    func envelope() -> FadeEnvelope {
        FadeEnvelope(start: Transition(kind: .fadeBlack, duration: 1), end: Transition(kind: .fadeBlack, duration: 3),
                     firstFrame: 10, endTime: 100, frameDuration: fd)
    }

    /// Replaces the fade part of EnvelopeTests.testAudioGainRampsAndNeverClicks.
    func testAudioGainExactCurveValues() {
        let e = envelope()
        let half = sin(Double.pi / 4)
        XCTAssertEqual(e.audioGain(at: 10), 0, accuracy: 1e-9)
        XCTAssertEqual(e.audioGain(at: 10.5), half, accuracy: 1e-9)
        XCTAssertEqual(e.audioGain(at: 11), 1, accuracy: 1e-9)
        XCTAssertEqual(e.audioGain(at: 97), 1, accuracy: 1e-9)
        XCTAssertEqual(e.audioGain(at: 98.5), half, accuracy: 1e-9)
        XCTAssertEqual(e.audioGain(at: 100), 0, accuracy: 1e-9)
    }

    func testAudioGainNeverClicks() {
        for e in [envelope(), FadeEnvelope(start: .none, end: .none, firstFrame: 10, endTime: 100, frameDuration: fd)] {
            let dt = 1.0 / 48000
            var prev = e.audioGain(at: 9.9)
            var maxStep = 0.0
            var t = 9.9 + dt
            var i = 0
            while t <= 100.1 {
                let g = e.audioGain(at: t)
                maxStep = max(maxStep, abs(g - prev))
                if t > 10, t <= 11 { XCTAssertGreaterThanOrEqual(g, prev - 1e-12, "fade-in not monotonic at \(t)"); if g < prev - 1e-12 { break } }
                if t >= 97, t < 100 { XCTAssertLessThanOrEqual(g, prev + 1e-12, "fade-out not monotonic at \(t)"); if g > prev + 1e-12 { break } }
                prev = g
                i += 1
                t = 9.9 + Double(i + 1) * dt
            }
            XCTAssertLessThan(maxStep, 0.01, "audio gain jumps by \(maxStep) in one sample")
        }
    }

    /// Replaces the no-transition part of EnvelopeTests.testAudioGainRampsAndNeverClicks.
    func testAntiClickRampWithoutTransition() {
        let none = FadeEnvelope(start: .none, end: .none, firstFrame: 10, endTime: 100, frameDuration: fd)
        let half = sin(Double.pi / 4)
        XCTAssertEqual(none.audioGain(at: 10.006), half, accuracy: 1e-6)
        XCTAssertEqual(none.audioGain(at: 99.994), half, accuracy: 1e-6)
        let onset = none.audioGain(at: 10.0001)
        XCTAssertGreaterThan(onset, 0)
        XCTAssertLessThan(onset, 0.1)
        XCTAssertEqual(none.audioGain(at: 10.012), 1, accuracy: 1e-9)
        XCTAssertEqual(none.audioGain(at: 50), 1, accuracy: 1e-9)
    }

    /// Replaces EnvelopeTests.testVideoFirstAndLastFramesAreFullyFaded with interior values.
    func testVideoFactorInteriorValues() {
        let e = envelope()
        XCTAssertEqual(e.videoFactors(at: 10).fadeIn, 0, accuracy: 1e-9)
        XCTAssertEqual(e.videoFactors(at: 10.5).fadeIn, 0.5 / (1 - fd), accuracy: 1e-9)
        XCTAssertEqual(e.videoFactors(at: 10 + 1 - fd).fadeIn, 1, accuracy: 1e-9)
        XCTAssertEqual(e.videoFactors(at: 100 - fd - 1.5).fadeOut, 1.5 / (3 - fd), accuracy: 1e-9)
        XCTAssertEqual(e.videoFactors(at: 100 - fd).fadeOut, 0, accuracy: 1e-9)
        XCTAssertEqual(e.videoFactors(at: 97 - fd).fadeOut, 1, accuracy: 1e-9)
        // The 1 s fade-in must not use the 3 s fade-out length or vice versa.
        XCTAssertEqual(e.videoFactors(at: 10.5).fadeOut, 1)
        XCTAssertEqual(e.videoFactors(at: 98).fadeIn, 1)
    }

    func testVideoFactorsClampOutsideTheClip() {
        let e = envelope()
        XCTAssertEqual(e.videoFactors(at: 5).fadeIn, 0)
        XCTAssertEqual(e.videoFactors(at: 101).fadeOut, 0)
    }

    func testOverlappingFadesOnShortClip() {
        let e = FadeEnvelope(start: Transition(kind: .fadeBlack, duration: 1.5), end: Transition(kind: .fadeWhite, duration: 1.5),
                             firstFrame: 0, endTime: 2, frameDuration: fd)
        let f = e.videoFactors(at: 1.0)
        XCTAssertEqual(f.fadeIn, 1.0 / (1.5 - fd), accuracy: 1e-9)
        XCTAssertEqual(f.fadeOut, (2 - fd - 1.0) / (1.5 - fd), accuracy: 1e-9)
        XCTAssertEqual(e.audioGain(at: 1.0), sin(Double.pi / 2 * (1 / 1.5)) * sin(Double.pi / 2 * (1 / 1.5)), accuracy: 1e-9)
    }
}

// MARK: - Pixel fades

final class WFExportPixelFadeTests: XCTestCase {
    func testPixelFormatMapping() {
        XCTAssertEqual(PixelFader(bitDepth: 8, fullRange: false).pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(PixelFader(bitDepth: 8, fullRange: true).pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        XCTAssertEqual(PixelFader(bitDepth: 10, fullRange: false).pixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(PixelFader(bitDepth: 10, fullRange: true).pixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
    }

    /// Strengthens PixelFadeTests.testLUTBlackFadeEndpoints.
    func testLUTIntermediateFactor8BitVideo() {
        let f = PixelFader(bitDepth: 8, fullRange: false)
        let l = f.luts(steps: [.init(factor: 0.5, kind: .fadeBlack)])
        XCTAssertEqual(l.y.count, 256)
        XCTAssertEqual(l.y[216], 116)
        XCTAssertEqual(l.c[240], 184)
        XCTAssertEqual(l.c[16], 72)
        let w = f.luts(steps: [.init(factor: 0.5, kind: .fadeWhite)])
        XCTAssertEqual(w.y[35], 135)
        XCTAssertEqual(w.c[240], 184)                  // chroma always goes to neutral
    }

    func testLUTLevels10BitAndFullRange() {
        let v10 = PixelFader(bitDepth: 10, fullRange: false)
        let b10 = v10.luts(steps: [.init(factor: 0, kind: .fadeBlack)])
        XCTAssertEqual(b10.y.count, 1024)
        XCTAssertEqual(b10.y[500], 64)
        XCTAssertEqual(b10.c[100], 512)
        XCTAssertEqual(v10.luts(steps: [.init(factor: 0, kind: .fadeWhite)]).y[100], 940)

        let f10 = PixelFader(bitDepth: 10, fullRange: true)
        XCTAssertEqual(f10.luts(steps: [.init(factor: 0, kind: .fadeBlack)]).y[700], 0)
        XCTAssertEqual(f10.luts(steps: [.init(factor: 0, kind: .fadeWhite)]).y[7], 1023)
        XCTAssertEqual(f10.luts(steps: [.init(factor: 0, kind: .fadeBlack)]).c[3], 512)

        let f8 = PixelFader(bitDepth: 8, fullRange: true)
        XCTAssertEqual(f8.luts(steps: [.init(factor: 0, kind: .fadeBlack)]).y[200], 0)
        XCTAssertEqual(f8.luts(steps: [.init(factor: 0, kind: .fadeWhite)]).y[20], 255)
        XCTAssertEqual(f8.luts(steps: [.init(factor: 0, kind: .fadeBlack)]).c[20], 128)
    }

    func testLUTStepsCompose() {
        let f = PixelFader(bitDepth: 8, fullRange: false)
        XCTAssertEqual(f.luts(steps: [.init(factor: 0.5, kind: .fadeBlack), .init(factor: 0.5, kind: .fadeBlack)]).y[216], 66)
        // black then white: 216 -> 116 -> 235 + 0.5 * (116 - 235) = 175.5 -> 176
        XCTAssertEqual(f.luts(steps: [.init(factor: 0.5, kind: .fadeBlack), .init(factor: 0.5, kind: .fadeWhite)]).y[216], 176)
        // kind .none and factor >= 1 are skipped
        let id = f.luts(steps: [.init(factor: 0, kind: .none), .init(factor: 1, kind: .fadeBlack), .init(factor: 1.5, kind: .fadeWhite)])
        XCTAssertEqual(id.y, (0...255).map { UInt16($0) })
        XCTAssertEqual(id.c, (0...255).map { UInt16($0) })
    }

    // MARK: apply() on real pixel buffers

    func makeBuffer(_ format: OSType, width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(nil, width, height, format, [kCVPixelBufferBytesPerRowAlignmentKey as String: 64] as CFDictionary, &pb)
        XCTAssertEqual(st, kCVReturnSuccess)
        return try XCTUnwrap(pb)
    }

    func fill(_ pb: CVPixelBuffer, tenBit: Bool, _ value: (Int, Int, Int) -> Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
            let rows = CVPixelBufferGetHeightOfPlane(pb, plane)
            let samples = CVPixelBufferGetWidthOfPlane(pb, plane) * (plane == 1 ? 2 : 1)
            for r in 0..<rows {
                if tenBit {
                    let p = (base + r * stride).assumingMemoryBound(to: UInt16.self)
                    for x in 0..<samples { p[x] = UInt16(value(plane, r, x)) << 6 }
                } else {
                    let p = (base + r * stride).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<samples { p[x] = UInt8(value(plane, r, x)) }
                }
            }
        }
    }

    func checkApply(bitDepth: Int, fullRange: Bool, width: Int, height: Int) throws {
        let fader = PixelFader(bitDepth: bitDepth, fullRange: fullRange)
        let tenBit = bitDepth == 10
        let maxV = tenBit ? 1023 : 255
        let src = try makeBuffer(fader.pixelFormat, width: width, height: height)
        let dst = try makeBuffer(fader.pixelFormat, width: width, height: height)
        fill(src, tenBit: tenBit) { plane, r, x in (plane * 97 + r * 31 + x * 7) % (maxV + 1) }
        fill(dst, tenBit: tenBit) { _, _, _ in tenBit ? 777 : 0xAA }         // sentinel: must all be overwritten
        CVBufferSetAttachment(src, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let steps: [PixelFader.Step] = [.init(factor: 0.5, kind: .fadeBlack), .init(factor: 0.8, kind: .fadeWhite)]
        fader.apply(src: src, dst: dst, steps: steps)
        let (lutY, lutC) = fader.luts(steps: steps)

        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, .readOnly) }
        var mismatches = 0
        for plane in 0..<2 {
            let s = CVPixelBufferGetBaseAddressOfPlane(src, plane)!, d = CVPixelBufferGetBaseAddressOfPlane(dst, plane)!
            let ss = CVPixelBufferGetBytesPerRowOfPlane(src, plane), ds = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
            let samples = CVPixelBufferGetWidthOfPlane(src, plane) * (plane == 1 ? 2 : 1)
            let lut = plane == 0 ? lutY : lutC
            for r in 0..<CVPixelBufferGetHeightOfPlane(src, plane) {
                for x in 0..<samples {
                    let got: Int, want: Int
                    if tenBit {
                        let sv = Int((s + r * ss).assumingMemoryBound(to: UInt16.self)[x] >> 6)
                        got = Int((d + r * ds).assumingMemoryBound(to: UInt16.self)[x])
                        want = Int(lut[sv]) << 6
                    } else {
                        let sv = Int((s + r * ss).assumingMemoryBound(to: UInt8.self)[x])
                        got = Int((d + r * ds).assumingMemoryBound(to: UInt8.self)[x])
                        want = Int(lut[sv])
                    }
                    if got != want {
                        mismatches += 1
                        if mismatches <= 3 { XCTFail("\(bitDepth)-bit plane \(plane) row \(r) sample \(x): got \(got), want \(want)") }
                    }
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "\(bitDepth)-bit full=\(fullRange): \(mismatches) samples differ from the LUT")
        let m = CVBufferCopyAttachment(dst, kCVImageBufferYCbCrMatrixKey, nil)
        XCTAssertEqual(m as? String, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, "colour tags carried across")
    }

    func testApply8BitVideoRangeWritesEveryLumaAndChromaSample() throws {
        try checkApply(bitDepth: 8, fullRange: false, width: 70, height: 6)   // 70 wide -> padded stride
    }

    func testApply8BitFullRange() throws {
        try checkApply(bitDepth: 8, fullRange: true, width: 64, height: 4)
    }

    func testApply10BitVideoRangeKeepsMSBAlignment() throws {
        try checkApply(bitDepth: 10, fullRange: false, width: 70, height: 6)
    }

    func testApply10BitFullRange() throws {
        try checkApply(bitDepth: 10, fullRange: true, width: 64, height: 4)
    }
}

// MARK: - Comparison, preflight, naming, timecodes

final class WFExportReportTests: XCTestCase {
    func facts(size: Int64) -> FileFacts {
        FileFacts(codec: "avc1", width: 1280, height: 720, frameRate: 30, videoBitRate: 3_000_000, audioCodec: "aac ", duration: 40, fileSize: size)
    }

    func testSizeRatioIsOutputOverOriginal() {
        XCTAssertEqual(FileComparison(original: facts(size: 1000), output: facts(size: 500)).sizeRatio, 0.5, accuracy: 1e-9)
        XCTAssertEqual(FileComparison(original: facts(size: 1000), output: facts(size: 860)).sizeRatio, 0.86, accuracy: 1e-9)
        XCTAssertEqual(FileComparison(original: facts(size: 0), output: facts(size: 860)).sizeRatio, 1)
    }

    func testLooksTooLargeThreshold() {
        XCTAssertFalse(FileComparison(original: facts(size: 1000), output: facts(size: 1150)).looksTooLarge)
        XCTAssertTrue(FileComparison(original: facts(size: 1000), output: facts(size: 1160)).looksTooLarge)
        XCTAssertFalse(FileComparison(original: facts(size: 1000), output: facts(size: 140)).looksTooLarge)
    }

    func testSummaryReportsPercentOfOriginal() {
        let s = FileComparison(original: facts(size: 1000), output: facts(size: 500)).summary
        XCTAssertTrue(s.hasSuffix("Size: 50.0% of original"), s)
    }

    func dummyPlan() -> ExportPlan {
        ExportPlan(firstFrame: .zero, endTime: CMTime(seconds: 100, preferredTimescale: 600), head: nil, mid: nil, tail: nil, isSingleSegment: false)
    }

    func testPreflightSummaryAndHeavyThreshold() {
        func pf(_ total: Double, _ re: Double) -> ExportEngine.Preflight { .init(plan: dummyPlan(), totalSeconds: total, reencodedSeconds: re) }
        XCTAssertEqual(pf(100, 0.04).summary, "Copies everything as-is")
        XCTAssertEqual(pf(100, 0).summary, "Copies everything as-is")
        XCTAssertEqual(pf(100, 5).summary, "Copies 95.0% as-is · re-encodes 5.0 s")
        XCTAssertEqual(pf(100, 5).copiedSeconds, 95, accuracy: 1e-9)
        XCTAssertEqual(pf(10, 12).copiedSeconds, 0)
        XCTAssertTrue(pf(600, 61).isHeavy)
        XCTAssertFalse(pf(700, 61).isHeavy, "61 s is under 10% of 700 s")
        XCTAssertFalse(pf(100, 60).isHeavy, "needs more than 60 s")
        XCTAssertFalse(pf(2400, 5.3).isHeavy)
    }

    func testUniqueOutputURLSuffixesAndExtensions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-wf-url-\(UUID().uuidString)")
        let other = dir.appendingPathComponent("Out")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("Sunday.mp4")
        let first = ExportEngine.uniqueOutputURL(for: src)
        XCTAssertEqual(first.path, dir.appendingPathComponent("Sunday - trimmed.mp4").path, "defaults to the source folder")
        try Data([0]).write(to: first)
        XCTAssertEqual(ExportEngine.uniqueOutputURL(for: src).lastPathComponent, "Sunday - trimmed 2.mp4")
        try Data([0]).write(to: dir.appendingPathComponent("Sunday - trimmed 2.mp4"))
        XCTAssertEqual(ExportEngine.uniqueOutputURL(for: src).lastPathComponent, "Sunday - trimmed 3.mp4")
        XCTAssertEqual(ExportEngine.uniqueOutputURL(for: src, in: other).path, other.appendingPathComponent("Sunday - trimmed.mp4").path)
        XCTAssertEqual(ExportEngine.uniqueOutputURL(for: dir.appendingPathComponent("x.mkv")).lastPathComponent, "x - trimmed.mp4")
        XCTAssertEqual(ExportEngine.uniqueOutputURL(for: dir.appendingPathComponent("x.m4v")).pathExtension.lowercased(), "m4v")
        XCTAssertEqual(ExportEngine.uniqueOutputURL(for: dir.appendingPathComponent("x.MOV")).pathExtension.lowercased(), "mov")
    }

    /// Replaces TimecodeTests.testRoundTrip with real round trips at non-default frame rates.
    func testTimecodeAtOtherFrameRates() {
        XCTAssertEqual(formatTimecode(3725.48, frameRate: 25), "01:02:05:12")
        XCTAssertEqual(formatTimecode(3725.5, frameRate: 25), "01:02:05:13")   // 12.5 frames rounds up
        XCTAssertEqual(formatTimecode(1.5, frameRate: 60), "00:00:01:30")
        XCTAssertEqual(parseTimecode("00:00:01:12", frameRate: 25)!, 1.48, accuracy: 1e-9)
        XCTAssertEqual(parseTimecode("00:00:01:30", frameRate: 60)!, 1.5, accuracy: 1e-9)
        for fps in [25.0, 30.0, 60.0] {
            for n in stride(from: 0, through: 4000, by: 7) {
                let s = Double(n) / fps
                let back = parseTimecode(formatTimecode(s, frameRate: fps), frameRate: fps)
                XCTAssertEqual(back ?? -1, s, accuracy: 1e-9, "fps \(fps) frame \(n)")
            }
        }
    }

    func testTimecodeEdgeCases() {
        XCTAssertEqual(formatTimecode(59.99, frameRate: 30), "00:01:00:00")     // frame carry
        XCTAssertEqual(formatTimecode(-5, frameRate: 30), "00:00:00:00")
        XCTAssertEqual(formatTimecode(.nan), "00:00:00:00")
        XCTAssertEqual(parseTimecode("1:02:03")!, 3723, accuracy: 1e-9)
        XCTAssertEqual(parseTimecode(" 12:30 ")!, 750, accuracy: 1e-9)
        XCTAssertNil(parseTimecode("1:2:3:4:5"))
        XCTAssertNil(parseTimecode(""))
        XCTAssertNil(parseTimecode("1::2"))
        XCTAssertNil(parseTimecode("00:00:01:xx"))
    }
}

// MARK: - NAL scanning (IDR detection)

final class WFExportNALScannerTests: XCTestCase {
    // Real H.264 SPS/PPS from a 64x64 libx264 stream, for format descriptions with different NAL length sizes.
    static let sps: [UInt8] = [0x67, 0x64, 0x00, 0x0A, 0xAC, 0xD9, 0x44, 0x26, 0xC0, 0x44, 0x00, 0x00, 0x03, 0x00, 0x04, 0x00, 0x00, 0x03, 0x00, 0xF0, 0x3C, 0x48, 0x96, 0x58]
    static let pps: [UInt8] = [0x68, 0xEB, 0xE3, 0xCB, 0x22, 0xC0]

    func h264Format(lengthSize: Int32) throws -> CMFormatDescription {
        var fd: CMFormatDescription?
        let st = Self.sps.withUnsafeBufferPointer { s in
            Self.pps.withUnsafeBufferPointer { p in
                var ptrs: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
                var sizes = [Self.sps.count, Self.pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: &ptrs,
                                                                           parameterSetSizes: &sizes, nalUnitHeaderLength: lengthSize, formatDescriptionOut: &fd)
            }
        }
        XCTAssertEqual(st, noErr)
        return try XCTUnwrap(fd)
    }

    /// Builds a length-prefixed access unit from (header byte, payload length) NAL units.
    func block(_ nals: [(UInt8, Int)], lengthSize: Int, lengthOverride: [Int: Int] = [:]) throws -> CMBlockBuffer {
        var bytes: [UInt8] = []
        for (i, (h, n)) in nals.enumerated() {
            let len = lengthOverride[i] ?? (n + 1)
            for k in (0..<lengthSize).reversed() { bytes.append(UInt8((len >> (8 * k)) & 0xFF)) }
            bytes.append(h)
            bytes.append(contentsOf: [UInt8](repeating: 0x88, count: n))
        }
        var bb: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                                          customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
                                                          flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb), kCMBlockBufferNoErr)
        let b = try XCTUnwrap(bb)
        bytes.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: b, offsetIntoDestination: 0, dataLength: bytes.count) }
        return b
    }

    func testH264IDRDetectionForAllLengthSizes() throws {
        for ls in [1, 2, 4] {
            let fd = try h264Format(lengthSize: Int32(ls))
            XCTAssertEqual(NALScanner.nalLengthSize(fd, isHEVC: false), ls)
            func idr(_ nals: [(UInt8, Int)], _ ov: [Int: Int] = [:]) throws -> Bool {
                NALScanner.containsIDR(block: try block(nals, lengthSize: ls, lengthOverride: ov), formatDescription: fd, isHEVC: false)
            }
            XCTAssertTrue(try idr([(0x65, 20)]), "IDR slice, len \(ls)")
            XCTAssertTrue(try idr([(0x09, 1), (0x06, 5), (0x67, 10), (0x68, 4), (0x65, 20)]), "AUD/SEI/SPS/PPS before IDR")
            XCTAssertFalse(try idr([(0x41, 20)]), "non-IDR slice")
            XCTAssertFalse(try idr([(0x06, 5), (0x41, 20), (0x65, 20)]), "first VCL decides")
            XCTAssertFalse(try idr([(0x22, 20)]), "slice partition A (type 2)")
            XCTAssertFalse(try idr([(0x09, 1), (0x65, 20)], [1: 200]), "truncated NAL length")
            XCTAssertFalse(try idr([(0x09, 1), (0x65, 20)], [0: 0]), "zero NAL length")
            XCTAssertFalse(try idr([(0x09, 1)]), "no VCL NAL")
        }
    }

    func testHEVCIDRDetectionRejectsCRA() throws {
        let fd = try h264Format(lengthSize: 4)       // only the length size is read from it
        func idr(_ types: [Int]) throws -> Bool {
            NALScanner.containsIDR(block: try block(types.map { (UInt8($0 << 1), 12) }, lengthSize: 4), formatDescription: fd, isHEVC: true)
        }
        XCTAssertTrue(try idr([19]), "IDR_W_RADL")
        XCTAssertTrue(try idr([20]), "IDR_N_LP")
        XCTAssertTrue(try idr([35, 39, 19]), "AUD + SEI before IDR")
        XCTAssertFalse(try idr([21]), "CRA is not a clean IDR")
        XCTAssertFalse(try idr([1]), "TRAIL_R")
        XCTAssertFalse(try idr([16]), "BLA")
        XCTAssertFalse(try idr([35, 1, 19]), "first VCL decides")
    }
}
