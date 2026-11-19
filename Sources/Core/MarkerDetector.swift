import Foundation
import FoundationModels

public struct MarkerSettings: Codable, Equatable, Sendable {
    public var tailSeconds: Double = 5
    /// Phrases that close the service intro (prayer, seating, kids dismissed): the speech right after them is likely the message.
    public var transitionPhrases: [String] = ["be seated", "have a seat", "you may be seated", "dismissed", "amen", "in jesus' name", "in jesus name"]
    public var endPhrases: [String] = [
        "amen", "in jesus' name", "in jesus name", "worship with us", "let's worship", "let us worship",
        "let's stand", "would you stand", "stand with me", "go in peace", "have a great week", "see you next week",
        "god bless you", "bless you",
    ]
    public var startPhrases: [String] = [
        "good morning", "good evening", "welcome", "open your bible", "open up your bible", "open your bibles", "turn with me",
        "turn to", "if you have a bible", "let's pray", "let us pray", "father god", "heavenly father", "this morning we",
        "today we", "let's open", "scripture", "chapter", "you may be seated", "have a seat", "be seated",
        "new series", "starting a new", "tonight we", "this evening we", "let me start",
    ]
    public init() {}
}

public struct MarkerCandidate: Identifiable, Sendable, Hashable {
    public enum Source: String, Sendable { case phrases = "Phrase match", ai = "Apple on-device AI" }
    public var id = UUID()
    public var time: Double
    public var score: Double
    public var reason: String
    public var context: String
    public var source: Source
    /// Up to 30 words said in the minute before a start (or after an end), to judge the cut.
    public var surrounding: String = ""
}

public struct DetectedMarkers: Sendable {
    public var starts: [MarkerCandidate] = []
    public var ends: [MarkerCandidate] = []
    public var usedAI = false
    public var notes: [String] = []
}

public enum MarkerDetector {
    // MARK: Heuristics

    public static func heuristicCandidates(transcript: Transcript, settings: MarkerSettings) -> DetectedMarkers {
        var result = DetectedMarkers()
        let sentences = transcript.sentences
        guard !sentences.isEmpty else { result.notes.append("The transcript is empty."); return result }
        result.starts = startCandidates(sentences: sentences, transcript: transcript, settings: settings)
        result.ends = endCandidates(sentences: sentences, transcript: transcript, settings: settings)
        return annotate(result, transcript: transcript)
    }

    /// Makes each candidate's text match its final time: what is said from a start (or up to an end) plus the
    /// 20 s on the other side of the cut.
    static func annotate(_ d: DetectedMarkers, transcript: Transcript) -> DetectedMarkers {
        var out = d
        let sentences = transcript.sentences
        for k in out.starts.indices {
            let t = out.starts[k].time
            if let i = sentences.firstIndex(where: { $0.end > t + 0.05 }) { out.starts[k].context = contextText(sentences, around: i, before: 0, after: 2) }
            out.starts[k].surrounding = transcript.words.filter { $0.end <= t + 0.05 && $0.start >= t - 60 }.suffix(30).map(\.text).joined(separator: " ")
        }
        for k in out.ends.indices {
            let t = out.ends[k].time
            if let i = sentences.lastIndex(where: { $0.start < t - 0.05 }) { out.ends[k].context = contextText(sentences, around: i, before: 2, after: 0) }
            out.ends[k].surrounding = transcript.words.filter { $0.start >= t - 0.05 && $0.end <= t + 60 }.prefix(30).map(\.text).joined(separator: " ")
        }
        return out
    }

    private static func contains(_ text: String, any phrases: [String]) -> [String] {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        return phrases.filter { t.contains($0) }
    }

    static func startCandidates(sentences: [Transcript.Sentence], transcript: Transcript, settings: MarkerSettings) -> [MarkerCandidate] {
        var scored: [MarkerCandidate] = []
        let limit = transcript.duration * 0.7
        let profile = SpeechProfile(transcript)
        for (i, s) in sentences.enumerated() where s.start <= limit {
            var score = 0.0
            var reasons: [String] = []
            let hits = contains(s.text, any: settings.startPhrases)
            if !hits.isEmpty {
                score += 1.5 + Double(min(hits.count, 3)) * 0.5
                reasons.append("says “\(hits[0])”")
            }
            let prevEnd = i > 0 ? sentences[i - 1].end : -100
            let gap = s.start - prevEnd
            if gap >= 8 { score += 2; reasons.append("follows \(Int(min(gap, 600))) s of quiet/music") }
            else if gap >= 4 { score += 1 }
            let following = transcript.words.filter { $0.start >= s.start && $0.start < s.start + 120 }.count
            if following >= 220 { score += 2; reasons.append("continuous speech follows") }
            else if following >= 140 { score += 1 }
            if i == 0 { score += 1 }
            // A sermon starts where sparse speech (songs, silence) turns into a long, dense run of one person talking.
            // Not credited when a closing line ("amen", "be seated") follows within a minute: that's the intro or the
            // opening prayer, and the message begins after it.
            let closesSoon = sentences[i...].prefix { $0.start < s.start + 60 }.contains { !contains($0.text, any: settings.transitionPhrases).isEmpty }
            let contrast = closesSoon ? 0 : profile.contrast(at: s.start)
            guard score + contrast >= 3 else { continue }
            score += startBonus(transcript, at: s.start)
            if contrast > 0.5 { score += contrast; reasons.append("speech gets much denser here") }
            let run = closesSoon ? 0 : profile.sustainedRunBonus(at: s.start)
            if run > 0 { score += run; if run >= 2 { reasons.append("starts a long stretch of talking") } }
            scored.append(MarkerCandidate(time: s.start, score: score, reason: reasons.joined(separator: ", "),
                                          context: contextText(sentences, around: i, before: 1, after: 3), source: .phrases))
        }
        return topDistinct(snapStarts(scored, sentences: sentences, settings: settings), minSeparation: 30, count: 4)
    }

    static func endCandidates(sentences: [Transcript.Sentence], transcript: Transcript, settings: MarkerSettings) -> [MarkerCandidate] {
        var scored: [MarkerCandidate] = []
        let from = transcript.duration * 0.6
        for (i, s) in sentences.enumerated() where s.end >= from {
            let hits = contains(s.text, any: settings.endPhrases)
            guard !hits.isEmpty else { continue }
            var score = 1.5 + Double(min(hits.count, 3)) * 0.5
            var reasons = ["says “\(hits[0])”"]
            let nextStart = i + 1 < sentences.count ? sentences[i + 1].start : transcript.duration + 30
            let gap = nextStart - s.end
            if gap >= 6 { score += 2; reasons.append("then \(Int(min(gap, 600))) s without speech") }
            else if gap >= 3 { score += 1 }
            let after = transcript.words.filter { $0.start > s.end && $0.start < s.end + 90 }.count
            if after < 40 { score += 1.5; reasons.append("little speech afterwards") }
            score += (s.end / max(transcript.duration, 1)) * 1.5          // favour later in the file
            score += endBonus(transcript, at: s.end)
            scored.append(MarkerCandidate(time: s.end, score: score, reason: reasons.joined(separator: ", "),
                                          context: contextText(sentences, around: i, before: 3, after: 1), source: .phrases))
        }
        return topDistinct(scored, minSeparation: 45, count: 4)
    }

    static func topDistinct(_ items: [MarkerCandidate], minSeparation: Double, count: Int) -> [MarkerCandidate] {
        var chosen: [MarkerCandidate] = []
        for c in items.sorted(by: { $0.score > $1.score }) {
            if chosen.allSatisfy({ abs($0.time - c.time) >= minSeparation }) { chosen.append(c) }
            if chosen.count == count { break }
        }
        return chosen
    }

    static func contextText(_ s: [Transcript.Sentence], around i: Int, before: Int, after: Int) -> String {
        let lo = max(0, i - before), hi = min(s.count - 1, i + after)
        return s[lo...hi].map(\.text).joined(separator: " ")
    }

    /// Index of the sentence where this continuous stretch of speech begins: walks back until a pause of 12 s or more,
    /// or a closing phrase such as "amen" / "kids can be dismissed".
    static func runStart(sentences: [Transcript.Sentence], index i: Int, boundaries: [String]) -> Int {
        var j = i
        while j > 0 {
            if sentences[j].start - sentences[j - 1].end >= 12 { break }
            let prev = sentences[j - 1].text.lowercased().replacingOccurrences(of: "’", with: "'")
            if boundaries.contains(where: { prev.contains($0) }) { break }
            j -= 1
        }
        return j
    }

    /// Moves each start candidate back to the beginning of its stretch of speech and merges duplicates.
    static func snapStarts(_ items: [MarkerCandidate], sentences: [Transcript.Sentence], settings: MarkerSettings) -> [MarkerCandidate] {
        var out: [MarkerCandidate] = []
        for var c in items {
            if let i = sentences.lastIndex(where: { $0.start <= c.time + 0.5 }) {
                let j = runStart(sentences: sentences, index: i, boundaries: settings.transitionPhrases)
                if j < i, c.time - sentences[j].start < 25 * 60 {
                    c.time = sentences[j].start
                    c.reason += (c.reason.isEmpty ? "" : "; ") + "start of this stretch of speech"
                }
            }
            if let i = sentences.lastIndex(where: { $0.start <= c.time + 0.5 }), i > 0,
               sentences[i].start - sentences[i - 1].end >= 8, sentences[i].start - sentences[i - 1].end < 90 {
                let before = sentences[max(0, i - 3)..<i].map(\.text).joined(separator: " ").lowercased()
                if ["be seated", "have a seat", "dismissed"].contains(where: { before.contains($0) }) {
                    c.score += 4
                    c.reason += (c.reason.isEmpty ? "" : "; ") + "follows “be seated / dismissed”"
                } else if ["amen", "in jesus' name", "in jesus name"].contains(where: { before.replacingOccurrences(of: "’", with: "'").contains($0) }) {
                    c.score += 3
                    c.reason += (c.reason.isEmpty ? "" : "; ") + "follows a prayer’s “amen”"
                }
            }
            if let k = out.firstIndex(where: { abs($0.time - c.time) < 1 }) {
                if c.score > out[k].score { out[k] = c }
            } else { out.append(c) }
        }
        return out.sorted { $0.score > $1.score }
    }

    /// Words per minute spoken in a window (songs and silence score low, a sermon scores high).
    static func speechRate(_ t: Transcript, from a: Double, to b: Double) -> Double {
        let hi = min(b, t.duration), lo = max(0, a)
        guard hi - lo > 5 else { return 0 }
        let n = t.words.filter { $0.start >= lo && $0.start < hi }.count
        return Double(n) / ((hi - lo) / 60)
    }

    /// Bonus (0...3) for a start candidate followed by a long run of continuous speech.
    static func startBonus(_ t: Transcript, at time: Double) -> Double {
        min(3, max(0, (speechRate(t, from: time, to: time + 20 * 60) - 60) / 40))
    }

    /// Bonus for an end candidate preceded by sermon-like speech and followed by quiet/music.
    static func endBonus(_ t: Transcript, at time: Double) -> Double {
        let before = min(3, max(0, (speechRate(t, from: time - 5 * 60, to: time) - 60) / 40))
        let after = speechRate(t, from: time + 5, to: time + 120)
        return before - (after > 140 ? 1.5 : 0)
    }

    /// Word counts per second, so speech density over any window is O(1).
    struct SpeechProfile {
        private var prefix: [Int]       // prefix[i] = words starting before second i
        let duration: Double
        private(set) var threshold = 60.0
        private(set) var longestRun = 0.0

        init(_ t: Transcript) {
            duration = t.duration
            let n = max(1, Int(t.duration.rounded(.up)) + 1)
            var counts = [Int](repeating: 0, count: n + 1)
            for w in t.words { counts[min(n, max(0, Int(w.start) + 1))] += 1 }
            for i in 1...n { counts[i] += counts[i - 1] }
            prefix = counts
            // "Talking" = at least 60% of the file's busy pace (90th percentile of minute-long windows).
            let rates = stride(from: 0.0, to: max(0, duration - 60), by: 30).map { rate(from: $0, to: $0 + 60) }.sorted()
            if !rates.isEmpty { threshold = max(60, rates[Int(Double(rates.count - 1) * 0.9)] * 0.6) }
            longestRun = stride(from: 0.0, to: duration, by: 30).map { runLength(from: $0) }.max() ?? 0
        }

        func words(from a: Double, to b: Double) -> Int {
            let n = prefix.count - 1
            let lo = min(n, max(0, Int(a.rounded()))), hi = min(n, max(0, Int(b.rounded())))
            return hi > lo ? prefix[hi] - prefix[lo] : 0
        }

        /// Words per minute in [a, b), clipped to the file.
        func rate(from a: Double, to b: Double) -> Double {
            let lo = max(0, a), hi = min(b, duration)
            guard hi - lo >= 5 else { return 0 }
            return Double(words(from: lo, to: hi)) / ((hi - lo) / 60)
        }

        /// How long continuous talking lasts from `t`: minute windows every 30 s, ending after 90 s below the threshold.
        func runLength(from t: Double) -> Double {
            guard rate(from: t, to: t + 60) >= threshold else { return 0 }
            var end = t, misses = 0, k = 0.0
            while t + k * 30 < duration {
                let a = t + k * 30
                if rate(from: a, to: a + 60) >= threshold { end = min(duration, a + 60); misses = 0 } else { misses += 1; if misses >= 3 { break } }
                k += 1
            }
            return end - t
        }

        /// 0...3: the next 5 minutes are much denser than the previous 3 (singing or silence turning into a talk).
        func contrast(at t: Double) -> Double {
            let before = rate(from: t - 180, to: t), after = min(rate(from: t, to: t + 60), rate(from: t, to: t + 300))
            return min(3, max(0, (after - before - 40) / 25))
        }

        /// 0...4: how close the talk starting here comes to the longest talk in the file (the sermon is usually the longest).
        func sustainedRunBonus(at t: Double) -> Double {
            guard longestRun >= 5 * 60 else { return 0 }
            return 4 * min(1, runLength(from: t) / longestRun)
        }
    }

    // MARK: On-device AI refinement

    public static var aiAvailable: Bool { SystemLanguageModel.default.availability == .available }

    @Generable
    struct SentenceChoice {
        @Guide(description: "The number of the chosen sentence, or 0 if none of them fits.")
        var sentenceNumber: Int
        @Guide(description: "Confidence from 0 to 1.")
        var confidence: Double
    }

    /// Asks Apple's on-device model to pick the exact sentence near each phrase-based candidate.
    public static func refineWithAI(transcript: Transcript, detected: DetectedMarkers, settings: MarkerSettings = MarkerSettings()) async -> DetectedMarkers {
        var out = detected
        guard aiAvailable else { out.notes.append("Apple Intelligence isn't available, so only phrase matching was used."); return out }
        let sentences = transcript.sentences
        var refinedStarts: [MarkerCandidate] = []
        var refinedEnds: [MarkerCandidate] = []

        for c in detected.starts.prefix(4) {
            if var r = await ask(kind: .start, near: c, sentences: sentences) {
                // The model says 100% for almost everything, so it only refines a candidate; it can't outrank a better one.
                r.score = c.score + r.score
                // If a greeting that begins this stretch of speech sits just before the AI's pick, start there.
                if let greet = detected.starts.first(where: { $0.time < r.time && r.time - $0.time <= 25 }) {
                    r.time = greet.time
                    r.reason += "; includes the opening greeting"
                }
                refinedStarts.append(r)
            }
        }
        for c in detected.ends.prefix(4) {
            if var r = await ask(kind: .end, near: c, sentences: sentences) {
                r.score = c.score + r.score
                refinedEnds.append(r)
            }
        }
        if !refinedStarts.isEmpty || !refinedEnds.isEmpty { out.usedAI = true }
        // AI answers go first (they carry a confidence-based score), phrase candidates remain as alternates.
        out.starts = dedupe(snapStarts(merge(ai: refinedStarts, phrases: detected.starts), sentences: sentences, settings: settings))
        out.ends = dedupe(merge(ai: refinedEnds, phrases: detected.ends))
        return annotate(out, transcript: transcript)
    }

    private static func dedupe(_ items: [MarkerCandidate]) -> [MarkerCandidate] {
        var out: [MarkerCandidate] = []
        for c in items.sorted(by: { $0.score > $1.score }) where out.allSatisfy({ abs($0.time - c.time) > 20 }) { out.append(c) }
        return Array(out.prefix(4))
    }

    private static func merge(ai: [MarkerCandidate], phrases: [MarkerCandidate]) -> [MarkerCandidate] {
        var all = ai.sorted { $0.score > $1.score }
        for p in phrases where all.allSatisfy({ abs($0.time - p.time) > 15 }) { all.append(p) }
        return all
    }

    enum Kind { case start, end }

    private static func ask(kind: Kind, near c: MarkerCandidate, sentences: [Transcript.Sentence]) async -> MarkerCandidate? {
        guard let idx = sentences.firstIndex(where: { abs((kind == .start ? $0.start : $0.end) - c.time) < 0.5 }) else { return nil }
        let lo = max(0, idx - 15), hi = min(sentences.count - 1, idx + 25)
        let window = Array(sentences[lo...hi])
        let numbered = window.enumerated().map { n, s in
            "\(n + 1). [\(clock(s.start))] \(s.text.split(separator: " ").prefix(30).joined(separator: " "))"
        }.joined(separator: "\n")
        let instructions: String
        let question: String
        switch kind {
        case .start:
            instructions = "You analyse transcripts of church service recordings. A sermon (the message) is the pastor teaching, usually after a greeting, announcements or worship songs."
            question = "Which numbered sentence is where the pastor begins the sermon message itself (not announcements, not a song, not a welcome to guests)? If the greeting leads straight into the message, choose the first sentence of the message."
        case .end:
            instructions = "You analyse transcripts of church service recordings. A sermon ends with a closing statement or prayer, often finishing with 'amen', before worship music or a dismissal."
            question = "Which numbered sentence is the very last sentence of the sermon message (such as the closing prayer's 'amen' or the final closing line, before worship or dismissal)?"
        }
        do {
            let session = LanguageModelSession(model: .default, instructions: instructions)
            let response = try await session.respond(to: "\(question)\n\nTranscript:\n\(numbered)", generating: SentenceChoice.self)
            let choice = response.content
            guard choice.sentenceNumber >= 1, choice.sentenceNumber <= window.count else { return nil }
            let s = window[choice.sentenceNumber - 1]
            let time = kind == .start ? s.start : s.end
            return MarkerCandidate(time: time, score: 1 + choice.confidence * 2, reason: "AI picked this sentence (confidence \(Int(choice.confidence * 100))%)",
                                   context: s.text, source: .ai)
        } catch {
            return nil
        }
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}
