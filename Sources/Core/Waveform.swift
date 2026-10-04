import Foundation
import AVFoundation

/// Coarse loudness envelope for the timeline. Reads audio at a low sample rate, so a 90-minute file takes seconds.
public enum Waveform {
    public static func peaks(asset: AVAsset, buckets: Int = 1600) async -> [Float] {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let duration = try? await asset.load(.duration).seconds_, duration > 0,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let rate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var peaks = [Float](repeating: 0, count: buckets)
        let totalSamples = duration * rate
        var index = 0.0
        while let sb = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return [] }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMSampleBufferGetNumSamples(sb)
            var data = [Int16](repeating: 0, count: n)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 2, destination: &data) == kCMBlockBufferNoErr else { continue }
            for s in data {
                let b = min(buckets - 1, Int(index / totalSamples * Double(buckets)))
                let v = Float(abs(Int(s))) / 32768
                if v > peaks[b] { peaks[b] = v }
                index += 1
            }
        }
        // Gentle companding so quiet speech is still visible next to loud music.
        let top = max(peaks.max() ?? 1, 0.05)
        return peaks.map { pow($0 / top, 0.6) }
    }
}
