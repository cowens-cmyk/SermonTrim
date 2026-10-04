import Foundation
import CoreVideo

/// Applies a fade directly to 4:2:0 bi-planar YCbCr pixels (no RGB round trip, so the picture outside the
/// fade keeps its exact colour). Works on encoded code values, which matches how NLEs do "dip to black".
public struct PixelFader {
    public let bitDepth: Int
    public let fullRange: Bool

    public init(bitDepth: Int, fullRange: Bool) {
        self.bitDepth = bitDepth
        self.fullRange = fullRange
    }

    public var pixelFormat: OSType {
        switch (bitDepth, fullRange) {
        case (10, true): return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case (10, false): return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (_, true): return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        default: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }

    private var levels: (black: Double, white: Double, neutral: Double, maxV: Int) {
        if bitDepth == 10 {
            return fullRange ? (0, 1023, 512, 1023) : (64, 940, 512, 1023)
        }
        return fullRange ? (0, 255, 128, 255) : (16, 235, 128, 255)
    }

    public struct Step { public var factor: Double; public var kind: TransitionKind }

    public func luts(steps: [Step]) -> (y: [UInt16], c: [UInt16]) {
        let l = levels
        var y = (0...l.maxV).map { Double($0) }
        var c = y
        for s in steps where s.factor < 1 && s.kind != .none {
            let target = s.kind == .fadeWhite ? l.white : l.black
            y = y.map { target + s.factor * ($0 - target) }
            c = c.map { l.neutral + s.factor * ($0 - l.neutral) }
        }
        // y/c are now functions of the *original index*; build final tables by index.
        return (y.map { UInt16(min(Double(l.maxV), max(0, $0.rounded()))) },
                c.map { UInt16(min(Double(l.maxV), max(0, $0.rounded()))) })
    }

    /// Writes a faded copy of `src` into `dst`. Both must share size and pixel format.
    public func apply(src: CVPixelBuffer, dst: CVPixelBuffer, steps: [Step]) {
        let (lutY, lutC) = luts(steps: steps)
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }
        for plane in 0..<2 {
            guard let s = CVPixelBufferGetBaseAddressOfPlane(src, plane),
                  let d = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else { continue }
            let rows = CVPixelBufferGetHeightOfPlane(src, plane)
            let width = CVPixelBufferGetWidthOfPlane(src, plane) * (plane == 1 ? 2 : 1)
            let sStride = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
            let dStride = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
            let lut = plane == 0 ? lutY : lutC
            for r in 0..<rows {
                if bitDepth == 8 {
                    let sp = (s + r * sStride).assumingMemoryBound(to: UInt8.self)
                    let dp = (d + r * dStride).assumingMemoryBound(to: UInt8.self)
                    lut.withUnsafeBufferPointer { l in
                        for x in 0..<width { dp[x] = UInt8(truncatingIfNeeded: l[Int(sp[x])]) }
                    }
                } else {
                    let sp = (s + r * sStride).assumingMemoryBound(to: UInt16.self)
                    let dp = (d + r * dStride).assumingMemoryBound(to: UInt16.self)
                    lut.withUnsafeBufferPointer { l in
                        for x in 0..<width { dp[x] = l[Int(sp[x] >> 6)] << 6 }
                    }
                }
            }
        }
        // Carry colour tags across so the encoder labels the frames correctly.
        CVBufferPropagateAttachments(src, dst)
    }
}
