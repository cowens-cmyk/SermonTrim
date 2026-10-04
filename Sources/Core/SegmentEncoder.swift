import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

/// Decodes a short stretch of the source, applies fades, and re-encodes it with settings that match the source.
/// Output timestamps are relative to the segment start (first frame at 0).
final class SegmentEncoder: @unchecked Sendable {
    let asset: AVAsset
    let info: VideoSourceInfo
    let envelope: FadeEnvelope
    let cancel: CancelToken

    init(asset: AVAsset, info: VideoSourceInfo, envelope: FadeEnvelope, cancel: CancelToken) {
        self.cancel = cancel
        self.asset = asset
        self.info = info
        self.envelope = envelope
    }

    private static func fileType(for url: URL) -> AVFileType { url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov }

    func videoSettings() -> [String: Any] {
        let fps = info.frameRate
        var bitrate = info.estimatedBitRate > 0 ? info.estimatedBitRate : Double(info.width * info.height) * fps * 0.07
        bitrate = max(bitrate * 1.5, 2_000_000)           // a touch above the source so the one re-encode is clean
        var props: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitrate),
            AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
            AVVideoMaxKeyFrameIntervalKey: Int(fps.rounded()) * 10,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if info.isHEVC {
            props[AVVideoProfileLevelKey] = info.bitDepth == 10 ? (kVTProfileLevel_HEVC_Main10_AutoLevel as String) : (kVTProfileLevel_HEVC_Main_AutoLevel as String)
        } else {
            props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            props[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        }
        var s: [String: Any] = [
            AVVideoCodecKey: info.isHEVC ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: info.width,
            AVVideoHeightKey: info.height,
            AVVideoCompressionPropertiesKey: props,
        ]
        let ext = CMFormatDescriptionGetExtensions(info.formatDescription) as? [String: Any] ?? [:]
        if let p = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
           let t = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
           let m = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String {
            s[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: p, AVVideoTransferFunctionKey: t, AVVideoYCbCrMatrixKey: m,
            ]
        }
        return s
    }

    /// Re-encodes source range `range` into `url`. Returns the number of frames written.
    func encode(range: CMTimeRange, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        try? FileManager.default.removeItem(at: url)
        let fader = PixelFader(bitDepth: info.bitDepth, fullRange: info.isFullRange)
        let pixelFormat = fader.pixelFormat

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: info.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ])
        output.alwaysCopiesSampleData = false
        reader.timeRange = range
        guard reader.canAdd(output) else { throw ExportError.readerFailed("cannot add video output") }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: url, fileType: Self.fileType(for: url))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings())
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: info.width,
            kCVPixelBufferHeightKey as String: info.height,
        ])
        guard writer.canAdd(input) else { throw ExportError.writerFailed("cannot add video input") }
        writer.add(input)

        guard reader.startReading() else { throw ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown") }
        guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "segment-encode")
        let envelope = self.envelope
        let start = range.start
        let end = range.end
        let halfFrame = CMTimeMultiplyByFloat64(info.frameDuration, multiplier: 0.5)
        let startThreshold = CMTimeSubtract(start, halfFrame)
        let total = max(range.duration.seconds_, 0.001)
        var count = 0
        var failure: Error?

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished {
                    if self.cancel.isCancelled { failure = ExportError.cancelled; finished = true; break }
                    guard let sb = output.copyNextSampleBuffer() else { finished = true; break }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                    if CMTimeCompare(pts, startThreshold) < 0 { continue }     // pre-roll frames before the In point
                    if CMTimeCompare(pts, end) >= 0 { continue }
                    guard let src = CMSampleBufferGetImageBuffer(sb), let pool = adaptor.pixelBufferPool else { continue }
                    var dstOpt: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dstOpt)
                    guard let dst = dstOpt else { failure = ExportError.writerFailed("no pixel buffer"); finished = true; break }
                    let t = pts.seconds_
                    let f = envelope.videoFactors(at: t)
                    fader.apply(src: src, dst: dst, steps: [
                        .init(factor: f.fadeIn, kind: envelope.start.kind),
                        .init(factor: f.fadeOut, kind: envelope.end.kind),
                    ])
                    let outPTS = CMTimeSubtract(pts, start)
                    if !adaptor.append(dst, withPresentationTime: outPTS) {
                        failure = ExportError.writerFailed(writer.error?.localizedDescription ?? "append failed")
                        finished = true
                        break
                    }
                    count += 1
                    progress(min(1, CMTimeSubtract(pts, start).seconds_ / total))
                }
                if finished {
                    input.markAsFinished()
                    cont.resume()
                }
            }
        }

        if let failure {
            reader.cancelReading()
            writer.cancelWriting()
            throw failure
        }
        if reader.status == .failed { writer.cancelWriting(); throw ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown") }
        await writer.finishWriting()
        if writer.status != .completed { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown") }
        return count
    }
}
