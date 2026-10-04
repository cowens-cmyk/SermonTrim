import Foundation
import CoreMedia

/// Describes which parts of the source are copied untouched and which are re-encoded.
///
///   source:  |--------- keep ----------------------------------------|
///   output:  [ head (re-encode) ][ mid (stream copy) ][ tail (re-encode) ]
///
/// The head runs from the In point to the next IDR keyframe (past the fade-in if there is one).
/// The tail runs from the last IDR keyframe before the fade-out to the Out point.
/// Everything between is copied byte-for-byte.
public struct ExportPlan: Sendable {
    public var firstFrame: CMTime        // In point snapped to a frame
    public var endTime: CMTime           // Out point (exclusive), snapped to a frame
    public var head: CMTimeRange?        // re-encoded
    public var mid: CMTimeRange?         // stream-copied
    public var tail: CMTimeRange?        // re-encoded
    public var isSingleSegment: Bool

    public var reencodedDuration: Double {
        (head?.duration.seconds_ ?? 0) + (tail?.duration.seconds_ ?? 0)
    }

    public static func make(spec: TrimSpec, trackEnd: CMTime, frameDuration: CMTime, keyframes: KeyframeProvider) throws -> ExportPlan {
        guard CMTimeCompare(spec.inTime, spec.outTime) < 0 else { throw ExportError.invalidRange }
        let half = CMTimeMultiplyByFloat64(frameDuration, multiplier: 0.5)
        let first = keyframes.frameTime(atOrAfter: spec.inTime) ?? spec.inTime
        let atEOF = CMTimeCompare(spec.outTime, CMTimeSubtract(trackEnd, half)) >= 0
        let end = atEOF ? trackEnd : (keyframes.frameTime(atOrAfter: spec.outTime) ?? spec.outTime)
        guard CMTimeCompare(first, end) < 0 else { throw ExportError.invalidRange }

        let ds = CMTime(seconds: spec.start.effective, preferredTimescale: 60000)
        let de = CMTime(seconds: spec.end.effective, preferredTimescale: 60000)

        // Head boundary
        var headEnd: CMTime? = nil
        if spec.start.effective == 0, let k = keyframes.keyframe(atOrAfter: first), CMTimeCompare(k, first) == 0 {
            headEnd = first                                   // In point is already a clean keyframe
        } else {
            headEnd = keyframes.keyframe(atOrAfter: CMTimeAdd(first, ds))
        }

        // Tail boundary
        var tailStart: CMTime? = nil                           // nil + atEOF => copy to the end of the file
        if atEOF && de == .zero {
            tailStart = nil
        } else {
            tailStart = keyframes.keyframe(atOrBefore: CMTimeSubtract(end, de))
        }

        // Fallback: everything in one re-encoded segment (very short clip, or no usable keyframes).
        func single() -> ExportPlan {
            ExportPlan(firstFrame: first, endTime: end,
                       head: CMTimeRange(start: first, end: end), mid: nil, tail: nil, isSingleSegment: true)
        }
        guard let hEnd = headEnd else { return single() }
        if CMTimeCompare(hEnd, end) >= 0 { return single() }

        let midEnd: CMTime
        if let ts = tailStart {
            if CMTimeCompare(hEnd, ts) > 0 { return single() }
            midEnd = ts
        } else if atEOF && de == .zero {
            midEnd = trackEnd
        } else {
            return single()                                    // no keyframe before the Out point
        }

        let head = CMTimeCompare(hEnd, first) > 0 ? CMTimeRange(start: first, end: hEnd) : nil
        let mid = CMTimeCompare(midEnd, hEnd) > 0 ? CMTimeRange(start: hEnd, end: midEnd) : nil
        let tail: CMTimeRange? = (tailStart != nil && CMTimeCompare(end, midEnd) > 0) ? CMTimeRange(start: midEnd, end: end) : nil
        return ExportPlan(firstFrame: first, endTime: end, head: head, mid: mid, tail: tail, isSingleSegment: false)
    }
}

/// Fade curves shared by video and audio so they stay in sync.
public struct FadeEnvelope: Sendable {
    public var start: Transition
    public var end: Transition
    public var firstFrame: Double
    public var endTime: Double
    public var frameDuration: Double

    /// Audio never starts or stops abruptly, even with no transition: a few ms ramp avoids clicks.
    static let minAudioRamp = 0.012

    /// Video fade amounts (1 = untouched picture, 0 = fully faded). The first/last frame is fully faded.
    public func videoFactors(at t: Double) -> (fadeIn: Double, fadeOut: Double) {
        var fin = 1.0, fout = 1.0
        let ds = start.effective, de = end.effective
        if ds > 0 { fin = ds > frameDuration ? clamp((t - firstFrame) / (ds - frameDuration)) : 1 }
        if de > 0 { fout = de > frameDuration ? clamp((endTime - frameDuration - t) / (de - frameDuration)) : 1 }
        return (fin, fout)
    }

    /// Audio gain at time t (seconds on the source timeline). Smooth, equal-power-style curve.
    public func audioGain(at t: Double) -> Double {
        let ds = max(start.effective, Self.minAudioRamp)
        let de = max(end.effective, Self.minAudioRamp)
        let gin = sin(Double.pi / 2 * clamp((t - firstFrame) / ds))
        let gout = sin(Double.pi / 2 * clamp((endTime - t) / de))
        return gin * gout
    }

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
}
