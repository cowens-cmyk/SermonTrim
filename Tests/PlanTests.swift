import XCTest
import CoreMedia

/// Keyframes every 3.2 s on a 60 fps timeline.
struct FakeKeyframes: KeyframeProvider {
    let gop = 3.2
    let fps = 60.0
    func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60000) }
    func keyframe(atOrBefore t: CMTime) -> CMTime? { let v = t.seconds_; return v < 0 ? nil : self.t((v / gop + 1e-9).rounded(.down) * gop) }
    func keyframe(atOrAfter t: CMTime) -> CMTime? { self.t(((t.seconds_ / gop) - 1e-9).rounded(.up) * gop) }
    func frameTime(atOrAfter t: CMTime) -> CMTime? { self.t(((t.seconds_ * fps) - 1e-6).rounded(.up) / fps) }
}

final class PlanTests: XCTestCase {
    let frame = CMTime(value: 1, timescale: 60)
    let end = CMTime(seconds: 100, preferredTimescale: 60000)
    func spec(_ a: Double, _ b: Double, _ s: Transition = .none, _ e: Transition = .none) -> TrimSpec {
        TrimSpec(inTime: CMTime(seconds: a, preferredTimescale: 60000), outTime: CMTime(seconds: b, preferredTimescale: 60000), start: s, end: e)
    }
    func plan(_ s: TrimSpec) throws -> ExportPlan { try ExportPlan.make(spec: s, trackEnd: end, frameDuration: frame, keyframes: FakeKeyframes()) }

    func testTrimStartAndFadeOutSplitsHeadMidTail() throws {
        let p = try plan(spec(1.5, 90, .none, Transition(kind: .fadeBlack, duration: 3)))
        XCTAssertFalse(p.isSingleSegment)
        XCTAssertEqual(p.head!.start.seconds_, 1.5, accuracy: 0.001)
        XCTAssertEqual(p.head!.end.seconds_, 3.2, accuracy: 0.001)         // next keyframe
        XCTAssertEqual(p.mid!.start.seconds_, 3.2, accuracy: 0.001)
        XCTAssertEqual(p.tail!.end.seconds_, 90, accuracy: 0.001)
        XCTAssertLessThanOrEqual(p.tail!.start.seconds_, 87)               // keyframe at or before out - fade
        XCTAssertGreaterThan(p.tail!.start.seconds_, 83)
        XCTAssertEqual(p.mid!.end.seconds_, p.tail!.start.seconds_, accuracy: 0.001)
        XCTAssertLessThan(p.reencodedDuration, 8)
    }

    func testCutOnKeyframesNeedsNoReencode() throws {
        let p = try plan(spec(3.2, 64, .none, .none))
        XCTAssertNil(p.head)
        XCTAssertNil(p.tail)
        XCTAssertEqual(p.mid!.duration.seconds_, 60.8, accuracy: 0.001)
    }

    func testFadeInLongerThanGopExtendsHeadToLaterKeyframe() throws {
        let p = try plan(spec(1.0, 90, Transition(kind: .fadeBlack, duration: 4), .none))
        XCTAssertGreaterThanOrEqual(p.head!.end.seconds_, 5.0)             // must cover the whole fade
    }

    func testVeryShortClipFallsBackToSingleSegment() throws {
        let p = try plan(spec(10, 12, Transition(kind: .fadeBlack, duration: 0.5), Transition(kind: .fadeBlack, duration: 0.5)))
        XCTAssertTrue(p.isSingleSegment)
        XCTAssertEqual(p.head!.duration.seconds_, 2, accuracy: 0.05)
    }

    func testOutAtEndOfFileWithoutFadeCopiesToEnd() throws {
        let p = try plan(spec(3.2, 100))
        XCTAssertNil(p.tail)
        XCTAssertEqual(p.mid!.end.seconds_, 100, accuracy: 0.001)
    }

    func testInvalidRangeThrows() {
        XCTAssertThrowsError(try plan(spec(10, 5)))
    }
}

final class EnvelopeTests: XCTestCase {
    func envelope() -> FadeEnvelope {
        FadeEnvelope(start: Transition(kind: .fadeBlack, duration: 1), end: Transition(kind: .fadeBlack, duration: 3),
                     firstFrame: 10, endTime: 100, frameDuration: 1.0 / 60)
    }
    func testVideoFirstAndLastFramesAreFullyFaded() {
        let e = envelope()
        XCTAssertEqual(e.videoFactors(at: 10).fadeIn, 0, accuracy: 1e-9)
        XCTAssertEqual(e.videoFactors(at: 100 - 1.0 / 60).fadeOut, 0, accuracy: 1e-9)
        XCTAssertEqual(e.videoFactors(at: 50).fadeIn, 1)
        XCTAssertEqual(e.videoFactors(at: 50).fadeOut, 1)
    }
    func testAudioGainRampsAndNeverClicks() {
        let e = envelope()
        XCTAssertEqual(e.audioGain(at: 10), 0, accuracy: 1e-9)
        XCTAssertEqual(e.audioGain(at: 100), 0, accuracy: 1e-9)
        XCTAssertEqual(e.audioGain(at: 50), 1, accuracy: 1e-9)
        XCTAssertGreaterThan(e.audioGain(at: 98), 0.2)
        XCTAssertLessThan(e.audioGain(at: 99.5), 0.5)
        var none = e; none.start = .none; none.end = .none
        XCTAssertEqual(none.audioGain(at: 10), 0, accuracy: 1e-9)          // tiny anti-click ramp even with no fade
        XCTAssertEqual(none.audioGain(at: 10.05), 1, accuracy: 1e-9)
    }
}

final class TimecodeTests: XCTestCase {
    func testRoundTrip() {
        XCTAssertEqual(formatTimecode(3725.5, frameRate: 30), "01:02:05:15")
        XCTAssertEqual(parseTimecode("01:02:05:15", frameRate: 30)!, 3725.5, accuracy: 0.001)
        XCTAssertEqual(parseTimecode("12:30")!, 750, accuracy: 0.001)
        XCTAssertEqual(parseTimecode("2.5")!, 2.5, accuracy: 0.001)
        XCTAssertNil(parseTimecode("abc"))
    }
}

final class PixelFadeTests: XCTestCase {
    func testLUTBlackFadeEndpoints() {
        let f = PixelFader(bitDepth: 8, fullRange: false)
        let full = f.luts(steps: [.init(factor: 1, kind: .fadeBlack)])
        XCTAssertEqual(full.y[120], 120)
        let black = f.luts(steps: [.init(factor: 0, kind: .fadeBlack)])
        XCTAssertEqual(black.y[200], 16)
        XCTAssertEqual(black.c[40], 128)
        let white = f.luts(steps: [.init(factor: 0, kind: .fadeWhite)])
        XCTAssertEqual(white.y[30], 235)
    }
}

final class MarkerTests: XCTestCase {
    /// ~2 minutes of intro chatter, then a long steady sermon, an "amen", then quiet.
    func transcript() -> Transcript {
        var words: [TranscriptWord] = []
        func say(_ text: String, at t: Double, perSecond: Double = 2.6) -> Double {
            var cur = t
            for w in text.split(separator: " ") { words.append(.init(text: String(w), start: cur, end: cur + 0.3)); cur += 1 / perSecond }
            return cur
        }
        _ = say("Welcome everyone. Please silence your phones.", at: 5)
        var t = say("All right, good morning everybody. Open your Bibles to Genesis chapter 29.", at: 130)
        while t < 130 + 40 * 60 { t = say("And the story goes on and on today friends because God is faithful to us always.", at: t + 0.2) }
        t = say("In Jesus name we pray. Amen.", at: t)
        return Transcript(words: words, duration: t + 120)
    }

    func testPhraseCandidatesFindStartAndEnd() {
        let t = transcript()
        let d = MarkerDetector.heuristicCandidates(transcript: t, settings: MarkerSettings())
        XCTAssertEqual(d.starts.first?.time ?? 0, 130, accuracy: 3)
        let lastWord = t.words.last!.end
        XCTAssertEqual(d.ends.first?.time ?? 0, lastWord, accuracy: 3)
    }
}
