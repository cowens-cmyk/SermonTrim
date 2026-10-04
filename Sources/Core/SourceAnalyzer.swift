import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Everything the engine needs to know about the source video track.
public struct VideoSourceInfo: @unchecked Sendable {
    public let track: AVAssetTrack
    public let formatDescription: CMFormatDescription
    public let codec: CMVideoCodecType
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let frameDuration: CMTime
    public let estimatedBitRate: Double
    public let bitDepth: Int
    public let isFullRange: Bool
    public let timeRange: CMTimeRange

    public var isHEVC: Bool { codec == kCMVideoCodecType_HEVC }
    public var isH264: Bool { codec == kCMVideoCodecType_H264 }
}

public enum SourceAnalyzer {
    public static func analyze(asset: AVAsset) async throws -> VideoSourceInfo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideoTrack }
        let (descs, nominal, rate, minDur, range) = try await track.load(
            .formatDescriptions, .nominalFrameRate, .estimatedDataRate, .minFrameDuration, .timeRange)
        guard let fd = descs.first else { throw ExportError.noVideoTrack }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        let codec = CMFormatDescriptionGetMediaSubType(fd)
        guard codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC else {
            throw ExportError.unsupported("video codec \(fourCC(codec)) (only H.264 and HEVC are supported)")
        }
        var fps = Double(nominal)
        if fps <= 0 { fps = minDur.isValid && minDur.seconds_ > 0 ? 1 / minDur.seconds_ : 30 }
        var frameDuration = minDur
        if !frameDuration.isValid || frameDuration.seconds_ <= 0 {
            frameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        }
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
        let depth = (ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int) ?? 8
        let full = (ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool) ?? false
        return VideoSourceInfo(
            track: track, formatDescription: fd, codec: codec,
            width: Int(dims.width), height: Int(dims.height),
            frameRate: fps, frameDuration: frameDuration,
            estimatedBitRate: Double(rate), bitDepth: depth >= 10 ? 10 : 8,
            isFullRange: full, timeRange: range)
    }

    public static func fourCC(_ v: FourCharCode) -> String {
        let bytes = [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }
}

/// Finds IDR keyframes — the only safe places to start or stop a stream copy.
public protocol KeyframeProvider {
    /// The latest safe keyframe with presentation time <= t (nil if none).
    func keyframe(atOrBefore t: CMTime) -> CMTime?
    /// The earliest safe keyframe with presentation time >= t (nil if none, e.g. past the last GOP).
    func keyframe(atOrAfter t: CMTime) -> CMTime?
    /// The presentation time of the first frame at or after t (frame-accurate snapping).
    func frameTime(atOrAfter t: CMTime) -> CMTime?
}

public final class AssetKeyframeProvider: KeyframeProvider, @unchecked Sendable {
    private let asset: AVAsset
    private let info: VideoSourceInfo
    private let generator: AVSampleBufferGenerator

    public init(asset: AVAsset, info: VideoSourceInfo) {
        self.asset = asset
        self.info = info
        self.generator = AVSampleBufferGenerator(asset: asset, timebase: nil)
    }

    private func cursor(at t: CMTime) -> AVSampleCursor? {
        info.track.makeSampleCursor(presentationTimeStamp: t)
    }

    public func frameTime(atOrAfter t: CMTime) -> CMTime? {
        guard let c = cursor(at: t) else { return nil }
        let half = CMTimeMultiplyByFloat64(info.frameDuration, multiplier: 0.5)
        var guardCount = 0
        // Cursor lands on the sample displayed at t; make sure we are not before it.
        while CMTimeCompare(c.presentationTimeStamp, CMTimeSubtract(t, half)) < 0, guardCount < 8 {
            if c.stepInPresentationOrder(byCount: 1) == 0 { return nil }
            guardCount += 1
        }
        return c.presentationTimeStamp
    }

    public func keyframe(atOrBefore t: CMTime) -> CMTime? {
        guard let c = cursor(at: t) else { return nil }
        var steps = 0
        while steps < 100_000 {
            if c.currentSampleSyncInfo.sampleIsFullSync.boolValue, isIDR(c),
               CMTimeCompare(c.presentationTimeStamp, t) <= 0 {
                return c.presentationTimeStamp
            }
            if c.stepInDecodeOrder(byCount: -1) == 0 { return nil }
            steps += 1
        }
        return nil
    }

    public func keyframe(atOrAfter t: CMTime) -> CMTime? {
        guard let c = cursor(at: t) else { return nil }
        var steps = 0
        while steps < 100_000 {
            if c.currentSampleSyncInfo.sampleIsFullSync.boolValue, isIDR(c),
               CMTimeCompare(c.presentationTimeStamp, t) >= 0 {
                return c.presentationTimeStamp
            }
            if c.stepInDecodeOrder(byCount: 1) == 0 { return nil }
            steps += 1
        }
        return nil
    }

    /// Looks at the NAL units of the sample to confirm it is an IDR picture (a clean random-access point).
    private func isIDR(_ cursor: AVSampleCursor) -> Bool {
        let request = AVSampleBufferRequest(start: cursor)
        request.maxSampleCount = 1
        request.direction = .forward
        guard let sb = try? generator.makeSampleBuffer(for: request),
              let block = CMSampleBufferGetDataBuffer(sb),
              let fd = CMSampleBufferGetFormatDescription(sb) else { return false }
        return NALScanner.containsIDR(block: block, formatDescription: fd, isHEVC: info.isHEVC)
    }
}

enum NALScanner {
    static func nalLengthSize(_ fd: CMFormatDescription, isHEVC: Bool) -> Int {
        var size: Int32 = 4
        if isHEVC {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &size)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &size)
        }
        return Int(size)
    }

    static func containsIDR(block: CMBlockBuffer, formatDescription fd: CMFormatDescription, isHEVC: Bool) -> Bool {
        let lengthSize = nalLengthSize(fd, isHEVC: isHEVC)
        let total = CMBlockBufferGetDataLength(block)
        var offset = 0
        var nalCount = 0
        while offset + lengthSize < total, nalCount < 16 {
            var lenBytes = [UInt8](repeating: 0, count: lengthSize)
            guard CMBlockBufferCopyDataBytes(block, atOffset: offset, dataLength: lengthSize, destination: &lenBytes) == kCMBlockBufferNoErr else { return false }
            let nalLen = lenBytes.reduce(0) { ($0 << 8) | Int($1) }
            guard nalLen > 0, offset + lengthSize + nalLen <= total else { return false }
            var header: UInt8 = 0
            guard CMBlockBufferCopyDataBytes(block, atOffset: offset + lengthSize, dataLength: 1, destination: &header) == kCMBlockBufferNoErr else { return false }
            if isHEVC {
                let type = Int((header >> 1) & 0x3F)
                if type == 19 || type == 20 { return true }   // IDR_W_RADL / IDR_N_LP
                if type < 32 { return false }                 // first VCL NAL decides
            } else {
                let type = Int(header & 0x1F)
                if type == 5 { return true }                  // IDR slice
                if type >= 1 && type <= 4 { return false }
            }
            offset += lengthSize + nalLen
            nalCount += 1
        }
        return false
    }
}
