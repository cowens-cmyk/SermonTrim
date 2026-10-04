import Foundation
import AVFoundation
import AppKit
import Observation
import UniformTypeIdentifiers

enum ExportState {
    case idle
    case running(stage: String, fraction: Double)
    case done(ExportEngine.Result)
    case failed(String)
}

enum DetectState {
    case idle
    case working(String, Double?)
    case ready(DetectedMarkers)
    case failed(String)
}

@MainActor @Observable
final class AppModel {
    // File
    var url: URL?
    var asset: AVURLAsset?
    var videoInfo: VideoSourceInfo?
    let player = AVPlayer()
    var duration = 0.0
    var frameRate = 30.0
    var loadError: String?

    // Playhead
    var currentTime = 0.0
    var isPlaying = false

    // Trim
    var inTime = 0.0 { didSet { updatePlaybackLimit() } }
    var outTime = 0.0 { didSet { updatePlaybackLimit() } }
    var startKind: TransitionKind = .none
    var startDuration = 0.5
    var endKind: TransitionKind = .fadeBlack
    var endDuration = 3.0

    // UI
    var showInspector = true
    var bladeOpen = false
    var showFileImporter = false

    // Export
    var exportState: ExportState = .idle
    private var engine: ExportEngine?

    // Transcript / detection
    var transcript: Transcript?
    var detectState: DetectState = .idle
    var tailSeconds = 5.0
    private var timeObserver: Any?
    private var previewing = false

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = t.seconds_
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    var frameDuration: Double { 1 / max(frameRate, 1) }
    var hasFile: Bool { url != nil }
    var keptDuration: Double { max(0, outTime - inTime) }
    var isExporting: Bool { if case .running = exportState { return true }; return false }

    var spec: TrimSpec {
        TrimSpec(inTime: CMTime(seconds: inTime, preferredTimescale: 60000),
                 outTime: CMTime(seconds: outTime, preferredTimescale: 60000),
                 start: Transition(kind: startKind, duration: startDuration),
                 end: Transition(kind: endKind, duration: endDuration))
    }

    // MARK: Opening

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a sermon video to trim"
        if panel.runModal() == .OK, let u = panel.url { open(u) }
    }

    func open(_ url: URL?) {
        guard let url else { return }
        Task { await load(url) }
    }

    private func load(_ url: URL) async {
        player.pause()
        loadError = nil
        exportState = .idle
        detectState = .idle
        transcript = nil
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let info = try await SourceAnalyzer.analyze(asset: asset)
            let dur = try await asset.load(.duration).seconds_
            self.url = url
            self.asset = asset
            self.videoInfo = info
            self.duration = dur
            self.frameRate = info.frameRate
            self.inTime = 0
            self.outTime = dur
            self.currentTime = 0
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            updatePlaybackLimit()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            if let cached = TranscriptionService().cachedTranscript(for: url) { self.transcript = cached }
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Transport

    private func updatePlaybackLimit() {
        guard !previewing else { return }
        player.currentItem?.forwardPlaybackEndTime = outTime > 0 ? CMTime(seconds: outTime, preferredTimescale: 60000) : .invalid
    }

    func seek(to seconds: Double) {
        let t = min(max(0, seconds), duration)
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.rate != 0 { player.pause(); isPlaying = false; return }
        if currentTime < inTime - 0.001 || currentTime >= outTime - 0.001 { seek(to: inTime) }
        player.play()
        isPlaying = true
    }

    func step(frames: Int) {
        player.pause()
        player.currentItem?.step(byCount: frames)
    }

    func jump(seconds: Double) { player.pause(); seek(to: currentTime + seconds) }

    /// Plays the first few seconds after the In point.
    func previewStart() { preview(from: inTime, to: min(outTime, inTime + max(4, startDuration + 2))) }
    /// Plays the last few seconds before the Out point, including the fade.
    func previewEnd() { preview(from: max(inTime, outTime - max(6, endDuration + 3)), to: outTime) }

    private func preview(from a: Double, to b: Double) {
        previewing = true
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: b, preferredTimescale: 60000)
        seek(to: a)
        player.play()
        previewing = false
    }

    // MARK: Markers

    func setIn(_ t: Double? = nil) {
        let v = snap(t ?? currentTime)
        inTime = min(max(0, v), max(0, outTime - frameDuration))
    }

    func setOut(_ t: Double? = nil) {
        let v = snap(t ?? currentTime)
        outTime = max(min(duration, v), inTime + frameDuration)
    }

    func snap(_ t: Double) -> Double { (t * frameRate).rounded() / frameRate }

    // Blade: cut at the playhead, then choose which side to drop.
    func openBlade() { guard hasFile else { return }; player.pause(); bladeOpen = true }
    func bladeRemoveBefore() { setIn(currentTime); bladeOpen = false }
    func bladeRemoveAfter() { setOut(currentTime); bladeOpen = false }

    // MARK: Export

    func export() {
        guard let url, !isExporting else { return }
        player.pause()
        let output = ExportEngine.uniqueOutputURL(for: url)
        let engine = ExportEngine()
        self.engine = engine
        exportState = .running(stage: "Preparing", fraction: 0)
        let spec = self.spec
        Task {
            do {
                let result = try await engine.export(source: url, output: output, spec: spec) { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.isExporting else { return }
                        self.exportState = .running(stage: p.stage, fraction: p.fraction)
                    }
                }
                exportState = .done(result)
            } catch ExportError.cancelled {
                exportState = .idle
            } catch {
                exportState = .failed(error.localizedDescription)
            }
            self.engine = nil
        }
    }

    func cancelExport() { engine?.cancel() }

    func revealOutput() {
        if case .done(let r) = exportState { NSWorkspace.shared.activateFileViewerSelecting([r.outputURL]) }
    }

    // MARK: Detection

    var markerSettings: MarkerSettings {
        var s = MarkerSettings()
        s.tailSeconds = tailSeconds
        let defaults = UserDefaults.standard
        if let t = defaults.string(forKey: "endPhrases") { s.endPhrases = Self.lines(t) }
        if let t = defaults.string(forKey: "startPhrases") { s.startPhrases = Self.lines(t) }
        return s
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    func detect() {
        guard let url else { return }
        detectState = .working("Starting…", nil)
        let settings = markerSettings
        Task {
            do {
                let t: Transcript
                if let existing = transcript { t = existing } else {
                    t = try await TranscriptionService().transcribe(source: url) { [weak self] stage, f in
                        Task { @MainActor in self?.detectState = .working(stage, f) }
                    }
                    transcript = t
                }
                detectState = .working("Finding the start and end…", nil)
                var d = MarkerDetector.heuristicCandidates(transcript: t, settings: settings)
                d = await MarkerDetector.refineWithAI(transcript: t, detected: d)
                detectState = .ready(d)
            } catch {
                detectState = .failed(error.localizedDescription)
            }
        }
    }

    func applyStart(_ c: MarkerCandidate) { setIn(c.time - 0.3); seek(to: inTime) }
    /// Out point = last word + a quiet hold, then the fade runs after the hold.
    func outTime(forEnd c: MarkerCandidate) -> Double {
        min(duration, c.time + tailSeconds + (endKind == .none ? 0 : endDuration))
    }
    func applyEnd(_ c: MarkerCandidate) { setOut(outTime(forEnd: c)); seek(to: max(inTime, outTime - endDuration - 2)) }

    func applyBestGuess() {
        guard case .ready(let d) = detectState else { return }
        if let s = d.starts.first { setIn(max(0, s.time - 0.3)) }
        if endKind == .none { endKind = .fadeBlack }
        if let e = d.ends.first { setOut(outTime(forEnd: e)) }
        seek(to: inTime)
    }
}
