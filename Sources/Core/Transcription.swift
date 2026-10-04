import Foundation
import AVFoundation
import Speech
import CryptoKit

public struct TranscriptWord: Codable, Sendable, Hashable {
    public var text: String
    public var start: Double
    public var end: Double
}

public struct Transcript: Codable, Sendable {
    public var words: [TranscriptWord]
    public var duration: Double

    /// Words grouped into sentences (split on terminal punctuation or long pauses).
    public var sentences: [Sentence] {
        var out: [Sentence] = []
        var cur: [TranscriptWord] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            out.append(Sentence(text: cur.map(\.text).joined(separator: " "), start: f.start, end: l.end))
            cur = []
        }
        for w in words {
            if let last = cur.last, w.start - last.end > 2.0 { flush() }
            cur.append(w)
            if let c = w.text.last, ".?!".contains(c) { flush() }
        }
        flush()
        return out
    }

    public struct Sentence: Sendable, Hashable {
        public var text: String
        public var start: Double
        public var end: Double
    }

    /// Plain text of everything said between two times.
    public func text(from a: Double, to b: Double) -> String {
        words.filter { $0.start >= a && $0.end <= b }.map(\.text).joined(separator: " ")
    }
}

public enum TranscriptionError: LocalizedError {
    case noAudio
    case unsupportedLocale
    public var errorDescription: String? {
        switch self {
        case .noAudio: return "The file has no audio to transcribe."
        case .unsupportedLocale: return "On-device speech recognition isn't available for this language on this Mac."
        }
    }
}

/// Fully on-device transcription with Apple's SpeechAnalyzer. No audio leaves the Mac.
public final class TranscriptionService: @unchecked Sendable {
    public typealias Status = @Sendable (String, Double?) -> Void

    public init() {}

    public static func cacheURL(for source: URL) throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("SermonTrim/Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(source.lastPathComponent)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(hash).json")
    }

    public func cachedTranscript(for source: URL) -> Transcript? {
        guard let url = try? Self.cacheURL(for: source), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    public func transcribe(source: URL, locale: Locale = Locale(identifier: "en-US"), status: @escaping Status) async throws -> Transcript {
        if let cached = cachedTranscript(for: source) { status("Loaded saved transcript", 1); return cached }

        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw TranscriptionError.noAudio }
        let duration = try await asset.load(.duration).seconds_

        // 1. Pull the audio out into a temporary file.
        status("Extracting audio…", nil)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("SermonTrim-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await Self.extractAudio(asset: asset, to: tmp)

        // 2. Make sure the on-device model for the language is present.
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw TranscriptionError.unsupportedLocale }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status("Downloading the speech model (one time)…", nil)
            try await request.downloadAndInstall()
        }

        // 3. Run the analyzer and collect word timings.
        status("Transcribing on this Mac…", 0)
        let file = try AVAudioFile(forReading: tmp)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [TranscriptWord] in
            var words: [TranscriptWord] = []
            var lastPercent = -1
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    words.append(TranscriptWord(text: text, start: range.start.seconds_, end: range.end.seconds_))
                }
                if duration > 0, let last = words.last, Int(last.end / duration * 100) != lastPercent {
                    lastPercent = Int(last.end / duration * 100)
                    status("Transcribing on this Mac…", min(0.99, last.end / duration))
                }
            }
            return words
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        let words = try await collector.value
        let transcript = Transcript(words: words, duration: duration)
        if let url = try? Self.cacheURL(for: source), let data = try? JSONEncoder().encode(transcript) { try? data.write(to: url) }
        status("Transcript ready", 1)
        return transcript
    }

    static func extractAudio(asset: AVAsset, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw TranscriptionError.noAudio }
        try await session.export(to: url, as: .m4a)
    }
}
