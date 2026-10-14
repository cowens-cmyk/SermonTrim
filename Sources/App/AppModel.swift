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
    var loadErrorIsPermission = false
    var waveform: [Float] = []

    // Playhead
    var currentTime = 0.0
    var isPlaying = false

    // Trim
    var inTime = 0.0 { didSet { pointsChanged() } }
    var outTime = 0.0 { didSet { pointsChanged() } }
    var startKind: TransitionKind = .none { didSet { settingsChanged() } }
    var startDuration = 0.5 { didSet { settingsChanged() } }
    var endKind: TransitionKind = .fadeBlack { didSet { settingsChanged() } }
    var endDuration = 3.0 { didSet { settingsChanged() } }
    var tailSeconds = 5.0 { didSet { saveSettings() } }

    // Sermon info → filename, speaker tag, embedded metadata
    var sermonTitle = ""
    var sermonDate = SermonNaming.closestSunday(to: Date())
    var speaker = ""
    var recentSpeakers: [String] = []
    var outputFolder: URL = SermonNaming.desktop { didSet { saveSettings() } }

    // UI
    var showInspector = true
    var bladeOpen = false
    var showBatch = false
    var preflight: ExportEngine.Preflight?

    // Export
    var exportState: ExportState = .idle
    private var engine: ExportEngine?

    // Transcript / detection
    var transcript: Transcript?
    var detectState: DetectState = .idle

    // Undo
    var undoManager: UndoManager?
    private var lastUndoStamp = Date.distantPast
    private var lastUndoName = ""
    private var suppressUndo = false

    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var previewing = false
    private var refreshTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var loadingSettings = false

    init() {
        loadSettings()
        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = t.seconds_
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

    // MARK: Persistence of the user's usual settings

    private func loadSettings() {
        loadingSettings = true
        defer { loadingSettings = false }
        let d = UserDefaults.standard
        if let k = d.string(forKey: "startKind"), let v = TransitionKind(rawValue: k) { startKind = v }
        if let k = d.string(forKey: "endKind"), let v = TransitionKind(rawValue: k) { endKind = v }
        if d.object(forKey: "startDuration") != nil { startDuration = d.double(forKey: "startDuration") }
        if d.object(forKey: "endDuration") != nil { endDuration = d.double(forKey: "endDuration") }
        if d.object(forKey: "tailSeconds") != nil { tailSeconds = d.double(forKey: "tailSeconds") }
        recentSpeakers = d.stringArray(forKey: "recentSpeakers") ?? []
        speaker = d.string(forKey: "lastSpeaker") ?? ""
        if let path = d.string(forKey: "outputFolder"), FileManager.default.fileExists(atPath: path) { outputFolder = URL(fileURLWithPath: path, isDirectory: true) }
    }

    private func saveSettings() {
        guard !loadingSettings else { return }
        let d = UserDefaults.standard
        d.set(startKind.rawValue, forKey: "startKind"); d.set(endKind.rawValue, forKey: "endKind")
        d.set(startDuration, forKey: "startDuration"); d.set(endDuration, forKey: "endDuration")
        d.set(tailSeconds, forKey: "tailSeconds")
        d.set(outputFolder.path, forKey: "outputFolder")
    }

    private func settingsChanged() { saveSettings(); pointsChanged() }

    // MARK: Sermon info

    var sermonInfo: SermonInfo { SermonInfo(title: sermonTitle, date: sermonDate, speaker: speaker) }

    var outputExtension: String { url.map { SermonNaming.fileExtension(for: $0) } ?? "mp4" }

    /// What the exported file will be called (before any " 2" for duplicates).
    var outputFileName: String {
        if let base = SermonNaming.baseName(for: sermonInfo) { return "\(base).\(outputExtension)" }
        guard let url else { return "" }
        return "\(url.deletingPathExtension().lastPathComponent) - trimmed.\(outputExtension)"
    }

    var outputFolderName: String { outputFolder == SermonNaming.desktop ? "Desktop" : outputFolder.lastPathComponent }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = outputFolder
        panel.prompt = "Choose"
        panel.message = "Where should trimmed videos be saved?"
        if panel.runModal() == .OK, let u = panel.url { outputFolder = u }
    }

    func useClosestSunday(to date: Date) { sermonDate = SermonNaming.closestSunday(to: date) }

    private func rememberSpeaker() {
        let names = Tagging.speakers(from: speaker)
        guard !names.isEmpty else { return }
        var list = recentSpeakers
        for n in names { list.removeAll { $0.caseInsensitiveCompare(n) == .orderedSame }; list.insert(n, at: 0) }
        recentSpeakers = Array(list.prefix(12))
        UserDefaults.standard.set(recentSpeakers, forKey: "recentSpeakers")
        UserDefaults.standard.set(speaker, forKey: "lastSpeaker")
    }

    // MARK: Opening

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a sermon video to trim"
        if panel.runModal() == .OK, let u = panel.url { open(u) }
    }

    func openBatchPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        panel.message = "Choose sermon videos to trim automatically"
        if panel.runModal() == .OK, !panel.urls.isEmpty { batch.add(panel.urls); showBatch = true }
    }

    let batch = BatchModel()

    func open(_ url: URL?, points: (Double, Double)? = nil) {
        guard let url else { return }
        Task { await load(url, points: points) }
    }

    private func load(_ url: URL, points: (Double, Double)?) async {
        player.pause()
        loadError = nil
        exportState = .idle
        detectState = .idle
        transcript = nil
        waveform = []
        preflight = nil
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let info = try await SourceAnalyzer.analyze(asset: asset)
            let dur = try await asset.load(.duration).seconds_
            self.url = url
            self.asset = asset
            self.videoInfo = info
            self.duration = dur
            self.frameRate = info.frameRate
            suppressUndo = true
            self.inTime = points?.0 ?? 0
            self.outTime = points?.1 ?? dur
            suppressUndo = false
            undoManager?.removeAllActions()
            sermonTitle = ""
            let fileDate = (try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]))
            sermonDate = SermonNaming.closestSunday(to: fileDate?.creationDate ?? fileDate?.contentModificationDate ?? Date())
            self.currentTime = 0
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            seek(to: self.inTime)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            if let cached = TranscriptionService().cachedTranscript(for: url) { self.transcript = cached }
            pointsChanged(immediate: true)
            waveformTask?.cancel()
            waveformTask = Task {
                let peaks = await Waveform.peaks(asset: asset)
                if !Task.isCancelled, self.url == url { self.waveform = peaks }
            }
        } catch {
            let e = ErrorExplainer.explain(error, operation: "Opening the video", input: url)
            loadError = e.message
            loadErrorIsPermission = e.isPermission
        }
    }

    // MARK: Transport

    private func pointsChanged(immediate: Bool = false) {
        updatePlaybackLimit()
        guard hasFile else { return }
        refreshTask?.cancel()
        refreshTask = Task {
            if !immediate { try? await Task.sleep(for: .milliseconds(250)) }
            if Task.isCancelled { return }
            await refreshDerivedState()
        }
    }

    /// Updates the fade preview and the copy-vs-re-encode summary after edits settle.
    private func refreshDerivedState() async {
        guard let asset, let info = videoInfo, outTime > inTime else { return }
        let s = spec
        preflight = try? ExportEngine.preflight(asset: asset, info: info, spec: s)
        await applyPreviewComposition(asset: asset, info: info)
    }

    private func updatePlaybackLimit() {
        guard !previewing else { return }
        player.currentItem?.forwardPlaybackEndTime = outTime > 0 ? CMTime(seconds: outTime, preferredTimescale: 60000) : .invalid
    }

    /// Makes the player show the fades live (video opacity ramps over black/white, plus an audio volume ramp).
    private func applyPreviewComposition(asset: AVURLAsset, info: VideoSourceInfo) async {
        guard let item = player.currentItem else { return }
        guard startKind != .none || endKind != .none else {
            item.videoComposition = nil
            item.audioMix = nil
            return
        }
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60000) }
        let (transform, natural) = (try? await info.track.load(.preferredTransform, .naturalSize)) ?? (.identity, CGSize(width: info.width, height: info.height))
        let rendered = natural.applying(transform)
        let end = t(duration)
        let a = inTime
        let b = min(inTime + (startKind == .none ? 0 : startDuration), outTime)
        let outStart = max(outTime - (endKind == .none ? 0 : endDuration), b)
        let fadeInBG = startKind == .fadeWhite ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
        let fadeOutBG = endKind == .fadeWhite ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)

        var instructions: [AVMutableVideoCompositionInstruction] = []
        func add(_ from: Double, _ to: Double, ramp: (Float, Float)?, bg: CGColor) {
            guard to - from > 0.0005 else { return }
            let range = CMTimeRange(start: t(from), end: t(to))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: info.track)
            layer.setTransform(transform, at: range.start)
            if let ramp { layer.setOpacityRamp(fromStartOpacity: ramp.0, toEndOpacity: ramp.1, timeRange: range) }
            let ins = AVMutableVideoCompositionInstruction()
            ins.timeRange = range
            ins.backgroundColor = bg
            ins.layerInstructions = [layer]
            instructions.append(ins)
        }
        add(0, a, ramp: nil, bg: fadeInBG)
        add(a, b, ramp: startKind == .none ? nil : (0, 1), bg: fadeInBG)
        add(b, outStart, ramp: nil, bg: fadeInBG)
        add(outStart, outTime, ramp: endKind == .none ? nil : (1, 0), bg: fadeOutBG)
        add(outTime, duration, ramp: nil, bg: fadeOutBG)
        guard !instructions.isEmpty else { return }
        _ = end

        let comp = AVMutableVideoComposition()
        comp.instructions = instructions
        comp.frameDuration = info.frameDuration
        comp.renderSize = CGSize(width: abs(rendered.width), height: abs(rendered.height))
        item.videoComposition = comp

        if let audio = try? await asset.loadTracks(withMediaType: .audio).first {
            let params = AVMutableAudioMixInputParameters(track: audio)
            params.setVolume(1, at: .zero)
            if startKind != .none, b > a { params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: t(a), end: t(b))) }
            if endKind != .none, outTime > outStart { params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: t(outStart), end: t(outTime))) }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
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

    /// Plays the first few seconds after the In point (with the fade-in shown).
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

    // MARK: Markers (with undo)

    private func registerPointsUndo(_ name: String) {
        guard !suppressUndo, let um = undoManager else { return }
        if name == lastUndoName, Date().timeIntervalSince(lastUndoStamp) < 0.8 { lastUndoStamp = Date(); return }   // one step per drag
        lastUndoName = name
        lastUndoStamp = Date()
        let old = (inTime, outTime)
        um.registerUndo(withTarget: self) { $0.restorePoints(old) }
        um.setActionName(name)
    }

    private func restorePoints(_ p: (Double, Double)) {
        let current = (inTime, outTime)
        undoManager?.registerUndo(withTarget: self) { $0.restorePoints(current) }
        lastUndoStamp = .distantPast
        suppressUndo = true
        inTime = p.0
        outTime = p.1
        suppressUndo = false
    }

    func setIn(_ t: Double? = nil) {
        registerPointsUndo("Set In")
        let v = snap(t ?? currentTime)
        inTime = min(max(0, v), max(0, outTime - frameDuration))
    }

    func setOut(_ t: Double? = nil) {
        registerPointsUndo("Set Out")
        let v = snap(t ?? currentTime)
        outTime = max(min(duration, v), inTime + frameDuration)
    }

    func snap(_ t: Double) -> Double { (t * frameRate).rounded() / frameRate }

    // Blade: cut at the playhead, then choose which side to drop.
    func openBlade() { guard hasFile else { return }; player.pause(); bladeOpen = true }
    func bladeRemoveBefore() { registerPointsUndo("Blade"); suppressUndo = true; setIn(currentTime); suppressUndo = false; bladeOpen = false }
    func bladeRemoveAfter() { registerPointsUndo("Blade"); suppressUndo = true; setOut(currentTime); suppressUndo = false; bladeOpen = false }

    // MARK: Export

    func export() {
        guard let url, !isExporting else { return }
        if let pf = preflight, pf.isHeavy {
            let alert = NSAlert()
            alert.messageText = "This export will re-encode \(Int(pf.reencodedSeconds)) seconds"
            alert.informativeText = "There aren't clean keyframes near your cut points, so a long stretch has to be re-encoded and the file may get larger. Move the In/Out points a little, or continue."
            alert.addButton(withTitle: "Export Anyway")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        player.pause()
        let fm = FileManager.default
        try? fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let folder = outputFolder
        let info = sermonInfo
        let hasTitle = SermonNaming.baseName(for: info) != nil
        let output: URL
        if let base = SermonNaming.baseName(for: info) {
            output = SermonNaming.uniqueURL(folder: folder, base: base, ext: SermonNaming.fileExtension(for: url))
        } else {
            output = ExportEngine.uniqueOutputURL(for: url, in: folder)
        }
        let engine = ExportEngine()
        self.engine = engine
        exportState = .running(stage: "Preparing", fraction: 0)
        let spec = self.spec
        Task {
            do {
                let result = try await engine.export(source: url, output: output, spec: spec, sermon: hasTitle ? info : nil) { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.isExporting else { return }
                        self.exportState = .running(stage: p.stage, fraction: p.fraction)
                    }
                }
                let tags = Tagging.speakers(from: info.speaker)
                if !tags.isEmpty { try? Tagging.apply(tags, to: result.outputURL) }
                rememberSpeaker()
                exportState = .done(result)
                NSSound(named: "Glass")?.play()
            } catch ExportError.cancelled {
                exportState = .idle
            } catch {
                let e = ErrorExplainer.explain(error, operation: "Export", input: url, outputFolder: output.deletingLastPathComponent())
                exportState = .failed(e.message)
                if e.isPermission { NSWorkspace.shared.open(ErrorExplainer.privacySettingsURL) }
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
                d = await MarkerDetector.refineWithAI(transcript: t, detected: d, settings: settings)
                detectState = .ready(d)
            } catch {
                detectState = .failed(ErrorExplainer.explain(error, operation: "Finding the start and end", input: url).message)
            }
        }
    }

    func applyStart(_ c: MarkerCandidate) { setIn(max(0, c.time - 0.3)); seek(to: inTime) }

    /// Out point = last word + a quiet hold, then the fade runs after the hold.
    func outTime(forEnd c: MarkerCandidate) -> Double {
        min(duration, c.time + tailSeconds + (endKind == .none ? 0 : endDuration))
    }
    func applyEnd(_ c: MarkerCandidate) { setOut(outTime(forEnd: c)); seek(to: max(inTime, outTime - endDuration - 2)) }

    func applyBestGuess() {
        guard case .ready(let d) = detectState else { return }
        registerPointsUndo("Use Suggestions")
        suppressUndo = true
        if endKind == .none { endKind = .fadeBlack }
        if let s = d.starts.first { setIn(max(0, s.time - 0.3)) }
        if let e = d.ends.first { setOut(outTime(forEnd: e)) }
        suppressUndo = false
        seek(to: inTime)
    }
}
