import Foundation
import AVFoundation
import CoreMedia

/// Smart-render export: stream-copies the bulk of the video, re-encodes only the few seconds that need it.
public final class ExportEngine: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (ExportProgress) -> Void

    public struct Result: Sendable {
        public var outputURL: URL
        public var plan: ExportPlan
        public var report: FileComparison
        public var log: [String]
    }

    public let cancelToken = CancelToken()
    public init() {}
    public func cancel() { cancelToken.cancel() }

    public static func uniqueOutputURL(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + " - trimmed"
        let ext = ["mp4", "mov", "m4v"].contains(source.pathExtension.lowercased()) ? source.pathExtension : "mp4"
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    public func export(source: URL, output: URL, spec: TrimSpec, progress: @escaping ProgressHandler) async throws -> Result {
        var log: [String] = []
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let info = try await SourceAnalyzer.analyze(asset: asset)
        let keyframes = AssetKeyframeProvider(asset: asset, info: info)
        let trackEnd = info.timeRange.end
        let plan = try ExportPlan.make(spec: spec, trackEnd: trackEnd, frameDuration: info.frameDuration, keyframes: keyframes)
        let envelope = FadeEnvelope(start: spec.start, end: spec.end,
                                    firstFrame: plan.firstFrame.seconds_, endTime: plan.endTime.seconds_,
                                    frameDuration: info.frameDuration.seconds_)
        func fmt(_ r: CMTimeRange?) -> String { r.map { String(format: "%.3f–%.3f s", $0.start.seconds_, $0.end.seconds_) } ?? "—" }
        log.append("Plan: head(re-encode) \(fmt(plan.head)) | middle(copy) \(fmt(plan.mid)) | tail(re-encode) \(fmt(plan.tail))")

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("SermonTrim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let ext = output.pathExtension.lowercased() == "mp4" ? "mp4" : "mov"

        // Stage 1: re-encode the head and tail.
        let encoder = SegmentEncoder(asset: asset, info: info, envelope: envelope, cancel: cancelToken)
        var segments: [SegmentSpec] = []
        let reencodeTotal = max(0.001, plan.reencodedDuration)
        var doneSeconds = 0.0
        func stageProgress(_ extra: Double) { progress(.init(stage: "Re-encoding fades", fraction: 0.25 * min(1, (doneSeconds + extra) / reencodeTotal))) }

        if let head = plan.head {
            let url = tmpDir.appendingPathComponent("head.\(ext)")
            let base = doneSeconds
            let n = try await encoder.encode(range: head, to: url) { f in progress(.init(stage: "Re-encoding start", fraction: 0.25 * min(1, (base + f * head.duration.seconds_) / reencodeTotal))) }
            doneSeconds += head.duration.seconds_
            log.append("Head: \(n) frames re-encoded")
            segments.append(.encoded(url: url, sourceStart: head.start))
        }
        if let mid = plan.mid { segments.append(.copied(range: mid)) }
        if let tail = plan.tail {
            let url = tmpDir.appendingPathComponent("tail.\(ext)")
            let base = doneSeconds
            let n = try await encoder.encode(range: tail, to: url) { f in progress(.init(stage: "Re-encoding end", fraction: 0.25 * min(1, (base + f * tail.duration.seconds_) / reencodeTotal))) }
            doneSeconds += tail.duration.seconds_
            log.append("Tail: \(n) frames re-encoded")
            segments.append(.encoded(url: url, sourceStart: tail.start))
        }
        stageProgress(0)

        // Stage 2: assemble.
        try? FileManager.default.removeItem(at: output)
        let assembler = Assembler(asset: asset, info: info, plan: plan, envelope: envelope, segments: segments,
                                  outputURL: output, fileType: ext == "mp4" ? .mp4 : .mov, cancel: cancelToken)
        let assembleLog = try await assembler.run { f in progress(.init(stage: "Writing file", fraction: 0.25 + 0.75 * f)) }
        log.append(contentsOf: assembleLog)
        progress(.init(stage: "Done", fraction: 1))

        let report = try await FileComparison.compare(original: source, output: output)
        return Result(outputURL: output, plan: plan, report: report, log: log)
    }
}

enum SegmentSpec {
    case encoded(url: URL, sourceStart: CMTime)   // re-encoded temp file; its timeline starts at 0
    case copied(range: CMTimeRange)               // stream copy straight from the source
}
