import Foundation
import AVFoundation
import CoreMedia

// smarttrim <input> <in-seconds> <out-seconds> [--start black|white|none:SECONDS] [--end black|white|none:SECONDS] [-o output]
func usage() -> Never {
    print("usage: smarttrim <input> <in> <out> [--start black:0.5] [--end black:3] [-o output]")
    exit(2)
}
var args = Array(CommandLine.arguments.dropFirst())
if args.first == "detect", args.count >= 2 {
    let file = URL(fileURLWithPath: args[1])
    Task {
        do {
            let t = try await TranscriptionService().transcribe(source: file) { s, f in print("  \(s) \(f.map { String(Int($0 * 100)) + "%" } ?? "")") }
            print("words: \(t.words.count)")
            var d = MarkerDetector.heuristicCandidates(transcript: t, settings: MarkerSettings())
            d = await MarkerDetector.refineWithAI(transcript: t, detected: d)
            print("AI used: \(d.usedAI) \(d.notes)")
            for c in d.starts { print(String(format: "START %@ score %.1f [%@] %@ :: %@", MarkerDetector.clock(c.time), c.score, c.source.rawValue, c.reason, String(c.context.prefix(160)))) }
            for c in d.ends { print(String(format: "END   %@ score %.1f [%@] %@ :: %@", MarkerDetector.clock(c.time), c.score, c.source.rawValue, c.reason, String(c.context.prefix(160)))) }
            exit(0)
        } catch { print("ERROR: \(error)"); exit(1) }
    }
    RunLoop.main.run()
}
guard args.count >= 3, let tin = parseTimecode(args[1]), let tout = parseTimecode(args[2]) else { usage() }
let input = URL(fileURLWithPath: args[0])
args.removeFirst(3)
func parseTransition(_ s: String) -> Transition {
    let p = s.split(separator: ":").map(String.init)
    let kind: TransitionKind = p[0] == "black" ? .fadeBlack : p[0] == "white" ? .fadeWhite : .none
    return Transition(kind: kind, duration: p.count > 1 ? Double(p[1]) ?? 0 : 0)
}
var start = Transition.none, end = Transition.none
var output = ExportEngine.uniqueOutputURL(for: input)
var i = 0
while i < args.count {
    switch args[i] {
    case "--start": start = parseTransition(args[i + 1]); i += 2
    case "--end": end = parseTransition(args[i + 1]); i += 2
    case "-o": output = URL(fileURLWithPath: args[i + 1]); i += 2
    default: usage()
    }
}
let spec = TrimSpec(inTime: CMTime(seconds: tin, preferredTimescale: 60000), outTime: CMTime(seconds: tout, preferredTimescale: 60000), start: start, end: end)
let t0 = Date()
var lastPrint = -1
Task {
    do {
        let r = try await ExportEngine().export(source: input, output: output, spec: spec) { p in
            let pct = Int(p.fraction * 100)
            if pct != lastPrint && pct % 10 == 0 { lastPrint = pct; print("  \(p.stage) \(pct)%") }
        }
        r.log.forEach { print($0) }
        print(r.report.summary)
        print(String(format: "Elapsed %.1f s -> %@", Date().timeIntervalSince(t0), r.outputURL.path))
        exit(0)
    } catch {
        print("ERROR: \(error.localizedDescription)")
        exit(1)
    }
}
RunLoop.main.run()
