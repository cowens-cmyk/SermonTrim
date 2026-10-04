import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

/// Decodes the source audio, applies fade gains, and hands PCM to the writer's AAC encoder.
/// The audio is trimmed to exactly the same frame-snapped window as the video.
final class AudioPipeline: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let writerSettings: [String: Any]
    let envelope: FadeEnvelope
    let sampleRate: Double
    let channels: Int
    let firstFrame: Double
    let totalFrames: Int64
    private var emittedUpTo: Int64 = 0
    private var finished = false

    private init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, writerSettings: [String: Any],
                 envelope: FadeEnvelope, sampleRate: Double, channels: Int, firstFrame: Double, totalFrames: Int64) {
        self.reader = reader; self.output = output; self.writerSettings = writerSettings
        self.envelope = envelope; self.sampleRate = sampleRate; self.channels = channels
        self.firstFrame = firstFrame; self.totalFrames = totalFrames
    }

    static func make(asset: AVAsset, plan: ExportPlan, envelope: FadeEnvelope) async throws -> AudioPipeline? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let (descs, rate) = try await track.load(.formatDescriptions, .estimatedDataRate)
        guard let fd = descs.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return nil }
        let sr = asbd.mSampleRate
        let ch = Int(asbd.mChannelsPerFrame)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: ch,
        ])
        output.alwaysCopiesSampleData = false
        let margin = CMTime(seconds: 0.3, preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: CMTimeSubtract(plan.firstFrame, margin), end: CMTimeAdd(plan.endTime, margin))
        guard reader.canAdd(output) else { throw ExportError.readerFailed("cannot add audio output") }
        reader.add(output)

        // AAC at (about) the source bitrate.
        var bitrate = Int((Double(rate) / 8000).rounded()) * 8000
        let lo = ch == 1 ? 64_000 : 96_000
        let hi = ch == 1 ? 160_000 : 320_000 * max(1, ch / 2)
        bitrate = min(hi, max(lo, bitrate))
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: ch,
            AVEncoderBitRateKey: bitrate,
        ]
        var layout = AudioChannelLayout()
        switch ch {
        case 1: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        case 2: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        default: break
        }
        if ch <= 2 { settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size) }

        let total = Int64(((plan.endTime.seconds_ - plan.firstFrame.seconds_) * sr).rounded())
        return AudioPipeline(reader: reader, output: output, writerSettings: settings, envelope: envelope,
                             sampleRate: sr, channels: ch, firstFrame: plan.firstFrame.seconds_, totalFrames: total)
    }

    func start() throws {
        guard reader.startReading() else { throw ExportError.readerFailed(reader.error?.localizedDescription ?? "audio") }
    }

    func cancel() { reader.cancelReading() }

    /// Next gain-adjusted PCM buffer on the output timeline (0 = first video frame), or nil at the end.
    func nextBuffer() -> CMSampleBuffer? {
        while !finished {
            guard let sb = output.copyNextSampleBuffer() else { finished = true; return nil }
            let n = CMSampleBufferGetNumSamples(sb)
            guard n > 0, let block = CMSampleBufferGetDataBuffer(sb), let fd = CMSampleBufferGetFormatDescription(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds_
            let s0 = Int64(((pts - firstFrame) * sampleRate).rounded())      // output index of this buffer's first frame
            let lo = Int(max(0, -s0))
            let hi = Int(min(Int64(n), totalFrames - s0))
            if hi <= 0 { finished = true; return nil }
            if hi <= lo { continue }

            var data = [Float](repeating: 0, count: n * channels)
            let bytes = n * channels * MemoryLayout<Float>.size
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: min(bytes, CMBlockBufferGetDataLength(block)), destination: &data) == kCMBlockBufferNoErr else { continue }

            let keep = hi - lo
            var out = [Float](repeating: 0, count: keep * channels)
            for i in 0..<keep {
                let frameIndex = Int(s0) + lo + i
                let t = firstFrame + Double(frameIndex) / sampleRate
                let g = Float(envelope.audioGain(at: t))
                let srcBase = (lo + i) * channels
                let dstBase = i * channels
                for c in 0..<channels { out[dstBase + c] = data[srcBase + c] * g }
            }
            return Self.makeBuffer(out, frames: keep, formatDescription: fd, pts: CMTime(value: s0 + Int64(lo), timescale: CMTimeScale(sampleRate)))
        }
        return nil
    }

    private static func makeBuffer(_ samples: [Float], frames: Int, formatDescription: CMFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let st = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard st == kCMBlockBufferNoErr else { return nil }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: formatDescription,
                                                                    sampleCount: frames, presentationTimeStamp: pts,
                                                                    packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
