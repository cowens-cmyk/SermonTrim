import Foundation
import AVFoundation
import CoreMedia
import Observation

/// Runs the whole pipeline (transcribe → detect → export) for several files in a row.
@MainActor @Observable
final class BatchModel {
    enum Status {
        case waiting
        case working(String, Double?)
        case done
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var status: Status = .waiting
        var inTime: Double?
        var outTime: Double?
        var output: URL?
        var ratio: Double?
        var summary = ""
    }

    var items: [Item] = []
    var running = false
    private var task: Task<Void, Never>?
    private var engine: ExportEngine?

    func add(_ urls: [URL]) {
        for u in urls where !items.contains(where: { $0.url == u }) { items.append(Item(url: u)) }
    }

    func clearFinished() {
        guard !running else { return }
        items.removeAll { if case .waiting = $0.status { return false }; return true }
    }

    func cancel() { task?.cancel(); engine?.cancel() }

    func start(startFade: Transition, endFade: Transition, tail: Double, markerSettings: MarkerSettings) {
        guard !running else { return }
        running = true
        task = Task {
            for i in items.indices {
                if Task.isCancelled { break }
                guard case .waiting = items[i].status else { continue }
                await process(index: i, startFade: startFade, endFade: endFade, tail: tail, markerSettings: markerSettings)
            }
            running = false
        }
    }

    private func set(_ i: Int, _ s: Status) { if items.indices.contains(i) { items[i].status = s } }

    private func process(index i: Int, startFade: Transition, endFade: Transition, tail: Double, markerSettings: MarkerSettings) async {
        let url = items[i].url
        do {
            set(i, .working("Reading file…", nil))
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds_

            let service = TranscriptionService()
            let transcript = try await service.transcribe(source: url) { [weak self] stage, f in
                Task { @MainActor in self?.set(i, .working(stage, f)) }
            }
            set(i, .working("Finding the start and end…", nil))
            var d = MarkerDetector.heuristicCandidates(transcript: transcript, settings: markerSettings)
            d = await MarkerDetector.refineWithAI(transcript: transcript, detected: d)

            guard d.starts.first != nil || d.ends.first != nil else {
                set(i, .failed("Couldn't find where the message starts or ends. Open it in the editor.")); return
            }
            let inT = max(0, (d.starts.first?.time ?? 0) - 0.3)
            let outT = d.ends.first.map { min(duration, $0.time + tail + endFade.effective) } ?? duration
            items[i].inTime = inT
            items[i].outTime = outT
            guard outT - inT > 120 else { set(i, .failed("The detected section is only \(Int(outT - inT)) s long. Open it in the editor.")); return }

            let engine = ExportEngine()
            self.engine = engine
            let spec = TrimSpec(inTime: CMTime(seconds: inT, preferredTimescale: 60000), outTime: CMTime(seconds: outT, preferredTimescale: 60000),
                                start: startFade, end: endFade)
            let result = try await engine.export(source: url, output: ExportEngine.uniqueOutputURL(for: url), spec: spec) { [weak self] p in
                Task { @MainActor in self?.set(i, .working(p.stage, p.fraction)) }
            }
            self.engine = nil
            items[i].output = result.outputURL
            items[i].ratio = result.report.sizeRatio
            items[i].summary = "\(ByteCountFormatter.string(fromByteCount: result.report.output.fileSize, countStyle: .file)) · \(Int(result.report.sizeRatio * 100))% of original"
            set(i, .done)
        } catch ExportError.cancelled {
            set(i, .failed("Cancelled"))
        } catch is CancellationError {
            set(i, .failed("Cancelled"))
        } catch {
            set(i, .failed(error.localizedDescription))
        }
    }
}
