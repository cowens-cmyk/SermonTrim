import Foundation
import AVFoundation
import CoreMedia

// Headless Sermon Trim. Everything runs on this Mac, like the app.
//
//   smarttrim detect <video> [--json] [--no-ai] [--tail 5] [--fade-out black:3]
//   smarttrim trim <video> --in <TC> --out <TC> [--fade-in none|black:0.5] [--fade-out black:3]
//                  [-o <file> | --folder <dir>] [--overwrite] [--json] [--result <file.json>]
//   smarttrim detect-json <transcript.json> [--json] [--no-ai]
//   smarttrim batch <video>...
//   smarttrim <video> <in> <out> [--start black:0.5] [--end black:3] [-o output]      (older form, still works)
//
// Timecodes: HH:MM:SS:FF (frames at the video's own rate), HH:MM:SS(.s), MM:SS, or seconds.
// Exit codes: 0 done, 1 failed, 2 bad arguments. With --json, stdout carries exactly one JSON object; progress goes to stderr.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      smarttrim detect <video> [--json] [--no-ai] [--tail SECONDS] [--fade-out black:3]
      smarttrim trim <video> --in TC --out TC [--fade-in none|black:0.5|white:0.5] [--fade-out black:3]
                     [-o FILE | --folder DIR] [--overwrite] [--json] [--result FILE.json]
      smarttrim detect-json <transcript.json> [--json] [--no-ai]
      smarttrim batch <video>...
      smarttrim <video> <in> <out> [--start black:0.5] [--end black:3] [-o output]

    """.utf8))
    exit(2)
}

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func emitJSON(_ object: [String: Any], to path: String? = nil) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    if let path { try? data.write(to: URL(fileURLWithPath: path)) }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func parseTransition(_ s: String) -> Transition {
    let p = s.split(separator: ":").map(String.init)
    let kind: TransitionKind = p[0] == "black" ? .fadeBlack : p[0] == "white" ? .fadeWhite : .none
    return Transition(kind: kind, duration: p.count > 1 ? Double(p[1]) ?? 0 : 0)
}

/// Splits `args` into flags (with values) and positional arguments.
struct Options {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []
    init(_ args: ArraySlice<String>, valued: Set<String>, switches: Set<String>) {
        var it = args.makeIterator()
        while let a = it.next() {
            if valued.contains(a) { guard let v = it.next() else { usage() }; values[a] = v }
            else if switches.contains(a) { flags.insert(a) }
            else if a.hasPrefix("--") { eprint("unknown option \(a)"); usage() }
            else { positional.append(a) }
        }
    }
}

func run(_ body: @escaping @Sendable () async throws -> Int32, json: Bool) -> Never {
    Task {
        do { exit(try await body()) } catch {
            if json { emitJSON(["ok": false, "error": error.localizedDescription]) } else { eprint("ERROR: \(error.localizedDescription)") }
            exit(1)
        }
    }
    RunLoop.main.run()
    exit(0)
}

func candidateJSON(_ c: MarkerCandidate, frameRate: Double, isStart: Bool) -> [String: Any] {
    [
        "seconds": (c.time * 1000).rounded() / 1000,
        "timecode": formatTimecode(c.time, frameRate: frameRate),
        "sentence": c.context,
        isStart ? "before" : "after": c.surrounding,
        "reason": c.reason,
        "score": (c.score * 10).rounded() / 10,
        "source": c.source.rawValue,
    ]
}

func detectionJSON(_ d: DetectedMarkers, transcript: Transcript, frameRate: Double, tail: Double, fadeOut: Transition,
                   file: String?, transcriptPath: String?) -> [String: Any] {
    var o: [String: Any] = [
        "ok": true,
        "duration": transcript.duration,
        "frameRate": frameRate,
        "words": transcript.words.count,
        "usedAI": d.usedAI,
        "notes": d.notes,
        "starts": d.starts.map { candidateJSON($0, frameRate: frameRate, isStart: true) },
        "ends": d.ends.map { candidateJSON($0, frameRate: frameRate, isStart: false) },
    ]
    if let file { o["file"] = file }
    if let transcriptPath { o["transcript"] = transcriptPath }
    // Same rule as the app's "Use best guess": In 0.3 s before the first word; Out = last word + hold + fade.
    if let s = d.starts.first { o["suggestedIn"] = formatTimecode(max(0, s.time - 0.3), frameRate: frameRate) }
    if let e = d.ends.first { o["suggestedOut"] = formatTimecode(min(transcript.duration, e.time + tail + fadeOut.effective), frameRate: frameRate) }
    return o
}

func printDetection(_ d: DetectedMarkers, frameRate: Double) {
    print("AI used: \(d.usedAI) \(d.notes)")
    for c in d.starts { print(String(format: "START %@ score %.1f [%@] %@ :: %@", formatTimecode(c.time, frameRate: frameRate), c.score, c.source.rawValue, c.reason, String(c.context.prefix(160)))) }
    for c in d.ends { print(String(format: "END   %@ score %.1f [%@] %@ :: %@", formatTimecode(c.time, frameRate: frameRate), c.score, c.source.rawValue, c.reason, String(c.context.prefix(160)))) }
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { usage() }

switch command {
case "batch":
    guard argv.count >= 2 else { usage() }
    Task { @MainActor in
        let batch = BatchModel()
        batch.add(argv.dropFirst().map { URL(fileURLWithPath: $0) })
        batch.start(startFade: Transition(kind: .fadeBlack, duration: 0.5), endFade: Transition(kind: .fadeBlack, duration: 3), tail: 5, markerSettings: MarkerSettings())
        var last = ""
        while batch.running || batch.items.contains(where: { if case .waiting = $0.status { return true }; return false }) {
            try? await Task.sleep(for: .seconds(2))
            let line = batch.items.map { "\($0.url.lastPathComponent): \($0.status)" }.joined(separator: " | ")
            if line != last { last = line; print(line.prefix(220)) }
        }
        for i in batch.items {
            print("RESULT \(i.url.lastPathComponent) in=\(i.inTime.map { formatTimecode($0, frameRate: 60) } ?? "-") out=\(i.outTime.map { formatTimecode($0, frameRate: 60) } ?? "-") \(i.summary) status=\(i.status)")
        }
        exit(0)
    }
    RunLoop.main.run()

case "detect-json":
    let o = Options(argv.dropFirst(), valued: ["--tail", "--fade-out"], switches: ["--json", "--no-ai"])
    guard let path = o.positional.first else { usage() }
    let json = o.flags.contains("--json")
    run({
        let t = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var d = MarkerDetector.heuristicCandidates(transcript: t, settings: MarkerSettings())
        if !o.flags.contains("--no-ai") { d = await MarkerDetector.refineWithAI(transcript: t, detected: d, settings: MarkerSettings()) }
        if json {
            emitJSON(detectionJSON(d, transcript: t, frameRate: 30, tail: Double(o.values["--tail"] ?? "") ?? 5,
                                   fadeOut: parseTransition(o.values["--fade-out"] ?? "black:3"), file: nil, transcriptPath: path))
        } else { printDetection(d, frameRate: 30) }
        return 0
    }, json: json)

case "detect":
    let o = Options(argv.dropFirst(), valued: ["--tail", "--fade-out"], switches: ["--json", "--no-ai"])
    guard let path = o.positional.first else { usage() }
    let json = o.flags.contains("--json")
    run({
        let file = URL(fileURLWithPath: path)
        let info = try await SourceAnalyzer.analyze(asset: AVURLAsset(url: file))
        let t = try await TranscriptionService().transcribe(source: file) { s, f in eprint("  \(s) \(f.map { String(Int($0 * 100)) + "%" } ?? "")") }
        var settings = MarkerSettings()
        settings.tailSeconds = Double(o.values["--tail"] ?? "") ?? 5
        var d = MarkerDetector.heuristicCandidates(transcript: t, settings: settings)
        if !o.flags.contains("--no-ai") { d = await MarkerDetector.refineWithAI(transcript: t, detected: d, settings: settings) }
        if json {
            emitJSON(detectionJSON(d, transcript: t, frameRate: info.frameRate, tail: settings.tailSeconds,
                                   fadeOut: parseTransition(o.values["--fade-out"] ?? "black:3"), file: file.path,
                                   transcriptPath: try? TranscriptionService.cacheURL(for: file).path))
        } else {
            print("words: \(t.words.count)")
            printDetection(d, frameRate: info.frameRate)
        }
        return 0
    }, json: json)

case "trim":
    let o = Options(argv.dropFirst(), valued: ["--in", "--out", "--fade-in", "--fade-out", "-o", "--folder", "--result"],
                    switches: ["--json", "--overwrite"])
    guard let path = o.positional.first, let inText = o.values["--in"], let outText = o.values["--out"] else { usage() }
    let json = o.flags.contains("--json")
    run({
        let input = URL(fileURLWithPath: path)
        let info = try await SourceAnalyzer.analyze(asset: AVURLAsset(url: input))
        guard let tin = parseTimecode(inText, frameRate: info.frameRate), let tout = parseTimecode(outText, frameRate: info.frameRate), tout > tin else {
            throw NSError(domain: "smarttrim", code: 2, userInfo: [NSLocalizedDescriptionKey: "In (\(inText)) and Out (\(outText)) must be valid times with Out after In."])
        }
        let spec = TrimSpec(inTime: CMTime(seconds: tin, preferredTimescale: 60000), outTime: CMTime(seconds: tout, preferredTimescale: 60000),
                            start: parseTransition(o.values["--fade-in"] ?? "none"), end: parseTransition(o.values["--fade-out"] ?? "black:3"))
        let fm = FileManager.default
        var dest: URL
        if let out = o.values["-o"] { dest = URL(fileURLWithPath: (out as NSString).expandingTildeInPath) }
        else { dest = ExportEngine.uniqueOutputURL(for: input, in: o.values["--folder"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }) }
        if fm.fileExists(atPath: dest.path) {
            if o.flags.contains("--overwrite") { try fm.removeItem(at: dest) }
            else { dest = SermonNaming.uniqueURL(folder: dest.deletingLastPathComponent(), base: dest.deletingPathExtension().lastPathComponent, ext: dest.pathExtension) }
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Stage outside the (possibly iCloud-synced) destination, then move in one step — same as the app.
        let temp = SafeSave.stagingURL(near: dest.deletingLastPathComponent(), ext: dest.pathExtension.isEmpty ? "mp4" : dest.pathExtension)
        let t0 = Date()
        let lastPrint = Counter()
        var r = try await ExportEngine().export(source: input, output: temp, spec: spec) { p in
            let pct = Int(p.fraction * 100)
            if lastPrint.swap(pct) != pct, pct % 10 == 0 { eprint("  \(p.stage) \(pct)%") }
        }
        try SafeSave.move(temp, to: dest)
        r.outputURL = dest
        let elapsed = Date().timeIntervalSince(t0)
        if json || o.values["--result"] != nil {
            let result: [String: Any] = [
                "ok": true,
                "output": dest.path,
                "source": input.path,
                "in": formatTimecode(tin, frameRate: info.frameRate),
                "out": formatTimecode(tout, frameRate: info.frameRate),
                "duration": (r.report.output.duration * 1000).rounded() / 1000,
                "bytes": r.report.output.fileSize,
                "sizeRatioOfOriginal": (r.report.sizeRatio * 1000).rounded() / 1000,
                "reencodedSeconds": (r.plan.reencodedDuration * 10).rounded() / 10,
                "codec": r.report.output.codec,
                "elapsedSeconds": (elapsed * 10).rounded() / 10,
                "warning": r.report.looksTooLarge ? "Output is more than 15% larger than the original." : NSNull(),
            ]
            if json { emitJSON(result, to: o.values["--result"]) }
            else if let p = o.values["--result"] { emitJSON(result, to: p) }
        }
        if !json {
            r.log.forEach { print($0) }
            print(r.report.summary)
            print(String(format: "Elapsed %.1f s -> %@", elapsed, dest.path))
        }
        return 0
    }, json: json)

default:
    // Older positional form: smarttrim <input> <in-seconds> <out-seconds> [--start …] [--end …] [-o output]
    guard argv.count >= 3, let tin = parseTimecode(argv[1]), let tout = parseTimecode(argv[2]) else { usage() }
    let input = URL(fileURLWithPath: argv[0])
    var start = Transition.none, end = Transition.none
    var output = ExportEngine.uniqueOutputURL(for: input)
    var i = 3
    while i < argv.count {
        guard i + 1 < argv.count else { usage() }
        switch argv[i] {
        case "--start": start = parseTransition(argv[i + 1])
        case "--end": end = parseTransition(argv[i + 1])
        case "-o": output = URL(fileURLWithPath: argv[i + 1])
        default: usage()
        }
        i += 2
    }
    let spec = TrimSpec(inTime: CMTime(seconds: tin, preferredTimescale: 60000), outTime: CMTime(seconds: tout, preferredTimescale: 60000), start: start, end: end)
    let t0 = Date()
    let lastPrint = Counter()
    run({
        let r = try await ExportEngine().export(source: input, output: output, spec: spec) { p in
            let pct = Int(p.fraction * 100)
            if lastPrint.swap(pct) != pct, pct % 10 == 0 { print("  \(p.stage) \(pct)%") }
        }
        r.log.forEach { print($0) }
        print(r.report.summary)
        print(String(format: "Elapsed %.1f s -> %@", Date().timeIntervalSince(t0), r.outputURL.path))
        return 0
    }, json: false)
}

/// Thread-safe "last value" box for progress callbacks.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1
    func swap(_ v: Int) -> Int { lock.lock(); defer { lock.unlock() }; let old = value; value = v; return old }
}
