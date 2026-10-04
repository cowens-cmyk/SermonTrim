import Foundation
import AVFoundation
import CoreMedia

/// Writes the final file: video samples from [re-encoded head][copied middle][re-encoded tail] appended
/// to a single pass-through input, plus the audio track with fades applied.
final class Assembler: @unchecked Sendable {
    let asset: AVAsset
    let info: VideoSourceInfo
    let plan: ExportPlan
    let envelope: FadeEnvelope
    let segments: [SegmentSpec]
    let outputURL: URL
    let fileType: AVFileType
    let cancel: CancelToken

    init(asset: AVAsset, info: VideoSourceInfo, plan: ExportPlan, envelope: FadeEnvelope, segments: [SegmentSpec], outputURL: URL, fileType: AVFileType, cancel: CancelToken) {
        self.cancel = cancel
        self.asset = asset; self.info = info; self.plan = plan; self.envelope = envelope
        self.segments = segments; self.outputURL = outputURL; self.fileType = fileType
    }

    // MARK: Video sources

    private final class SampleSource {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let ptsShift: CMTime            // added to each sample's pts to land on the output timeline
        let keepRange: CMTimeRange?     // source-time filter (copied segments)
        var started = false

        init(asset: AVAsset, track: AVAssetTrack, readRange: CMTimeRange?, keepRange: CMTimeRange?, ptsShift: CMTime) throws {
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if let r = readRange { reader.timeRange = r }
            reader.add(output)
            self.keepRange = keepRange
            self.ptsShift = ptsShift
        }

        func start() throws {
            guard reader.startReading() else { throw ExportError.readerFailed(reader.error?.localizedDescription ?? "unknown") }
        }

        /// Next sample in decode order, with its output-timeline PTS.
        func next() -> (CMSampleBuffer, CMTime)? {
            while let sb = output.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sb) == 0 { continue }       // reader marker buffers carry no media
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                if let k = keepRange, !(CMTimeCompare(pts, k.start) >= 0 && CMTimeCompare(pts, k.end) < 0) { continue }
                return (sb, CMTimeAdd(pts, ptsShift))
            }
            return nil
        }
    }

    private func makeSources() async throws -> [SampleSource] {
        var out: [SampleSource] = []
        for seg in segments {
            switch seg {
            case .copied(let range):
                out.append(try SampleSource(asset: asset, track: info.track, readRange: range, keepRange: range,
                                            ptsShift: CMTimeMultiply(plan.firstFrame, multiplier: -1)))
            case .encoded(let url, let sourceStart):
                let a = AVURLAsset(url: url)
                guard let t = try await a.loadTracks(withMediaType: .video).first else { throw ExportError.readerFailed("missing temp track") }
                out.append(try SampleSource(asset: a, track: t, readRange: nil, keepRange: nil,
                                            ptsShift: CMTimeSubtract(sourceStart, plan.firstFrame)))
            }
        }
        return out
    }

    /// How many frames of display delay the copied stream needs between decode time and presentation time.
    private func measureReorderDelay() throws -> Int {
        guard case .copied(let range)? = segments.first(where: { if case .copied = $0 { return true } else { return false } }) else { return 0 }
        let probeEnd = CMTimeMinimum(range.end, CMTimeAdd(range.start, CMTime(seconds: 8, preferredTimescale: 600)))
        let probe = try SampleSource(asset: asset, track: info.track, readRange: CMTimeRange(start: range.start, end: probeEnd),
                                     keepRange: CMTimeRange(start: range.start, end: probeEnd), ptsShift: .zero)
        try probe.start()
        let frame = info.frameDuration.seconds_
        var j = 0
        var firstPTS: Double?
        var maxLag = 0.0
        while let (sb, pts) = probe.next() {
            let p = pts.seconds_
            if firstPTS == nil { firstPTS = p }
            // decode slot j sits at j frames after the first sample; display time is p - first.
            maxLag = max(maxLag, Double(j) - (p - firstPTS!) / frame)
            j += 1
            _ = sb
        }
        probe.reader.cancelReading()
        return max(0, Int(maxLag.rounded(.up)))
    }

    // MARK: Run

    func run(progress: @escaping @Sendable (Double) -> Void) async throws -> [String] {
        var log: [String] = []
        let sources = try await makeSources()
        for s in sources { try s.start() }
        let reorder = try measureReorderDelay()
        log.append("Stream-copy reorder delay: \(reorder) frames")

        // Peek the first sample for the writer's format hint.
        guard let firstPeek = sources.first.flatMap({ $0.next() }) else { throw ExportError.readerFailed("no video samples") }
        let formatHint = CMSampleBufferGetFormatDescription(firstPeek.0)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw ExportError.writerFailed("cannot add video input") }
        writer.add(vIn)

        // Audio
        let audio = try await AudioPipeline.make(asset: asset, plan: plan, envelope: envelope)
        var aIn: AVAssetWriterInput?
        if let audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audio.writerSettings)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw ExportError.writerFailed("cannot add audio input") }
            writer.add(input)
            aIn = input
        }

        guard writer.startWriting() else { throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: .zero)
        try audio?.start()

        let frameDur = info.frameDuration
        let totalSeconds = max(0.001, CMTimeSubtract(plan.endTime, plan.firstFrame).seconds_)
        let progressBox = ProgressBox()
        let errBox = ErrorBox()
        let group = DispatchGroup()

        // Video pump
        group.enter()
        let vQueue = DispatchQueue(label: "assemble-video")
        var sourceIndex = 0
        var pending: (CMSampleBuffer, CMTime)? = firstPeek
        var nextDTS = CMTimeMultiply(frameDur, multiplier: Int32(-reorder))
        var copiedCount = 0
        var videoDone = false
        vIn.requestMediaDataWhenReady(on: vQueue) {
            while vIn.isReadyForMoreMediaData && !videoDone {
                if self.cancel.isCancelled { errBox.set(ExportError.cancelled); videoDone = true; break }
                var item = pending
                pending = nil
                while item == nil && sourceIndex < sources.count {
                    item = sources[sourceIndex].next()
                    if item == nil { sourceIndex += 1 }
                }
                guard let (sb, pts) = item else { videoDone = true; break }
                var dur = CMSampleBufferGetDuration(sb)
                if !dur.isValid || dur.seconds_ <= 0 { dur = frameDur }
                let dts = nextDTS
                nextDTS = CMTimeAdd(nextDTS, dur)
                if CMTimeCompare(dts, pts) > 0 {
                    errBox.set(ExportError.unsupported("variable frame timing (decode time passed display time)"))
                    videoDone = true
                    break
                }
                var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts, decodeTimeStamp: dts)
                var out: CMSampleBuffer?
                let st = CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
                guard st == noErr, let retimed = out else { errBox.set(ExportError.writerFailed("retime failed \(st)")); videoDone = true; break }
                if !vIn.append(retimed) {
                    errBox.set(ExportError.writerFailed(writer.error?.localizedDescription ?? "video append failed"))
                    videoDone = true
                    break
                }
                copiedCount += 1
                if copiedCount % 120 == 0 { progressBox.video = min(1, pts.seconds_ / totalSeconds); progress(progressBox.combined) }
            }
            if videoDone {
                vIn.markAsFinished()
                group.leave()
            }
        }

        // Audio pump
        if let audio, let aIn {
            group.enter()
            let aQueue = DispatchQueue(label: "assemble-audio")
            var audioDone = false
            aIn.requestMediaDataWhenReady(on: aQueue) {
                while aIn.isReadyForMoreMediaData && !audioDone {
                    if self.cancel.isCancelled { errBox.set(ExportError.cancelled); audioDone = true; break }
                    guard let sb = audio.nextBuffer() else { audioDone = true; break }
                    if !aIn.append(sb) {
                        errBox.set(ExportError.writerFailed(writer.error?.localizedDescription ?? "audio append failed"))
                        audioDone = true
                        break
                    }
                }
                if audioDone {
                    aIn.markAsFinished()
                    group.leave()
                }
            }
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { c.resume() }
        }

        if let e = errBox.get() {
            sources.forEach { $0.reader.cancelReading() }
            audio?.cancel()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw e
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
        log.append("Wrote \(copiedCount) video samples")
        progress(1)
        return log
    }
}

final class ProgressBox: @unchecked Sendable {
    var video = 0.0
    var combined: Double { video }
}

final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func set(_ e: Error) { lock.lock(); if error == nil { error = e }; lock.unlock() }
    func get() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
}
