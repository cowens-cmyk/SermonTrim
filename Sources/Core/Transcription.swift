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
    case stage(String, Error)
    case audioStops(at: Double, of: Double, Error)
    public var errorDescription: String? {
        switch self {
        case .audioStops(let at, let total, let underlying):
            func clock(_ t: Double) -> String { String(format: "%d:%02d:%02d", Int(t) / 3600, Int(t) / 60 % 60, Int(t) % 60) }
            return "The audio in this video becomes unreadable at \(clock(at)) (the video is \(clock(total)) long), so the start and end can't be found reliably. The video itself can still be trimmed by hand.\n\nDetails: \(ErrorExplainer.code(underlying))"
        case .stage(let what, let underlying):
            let hint: String
            switch what {
            case "downloading the speech model": hint = "The first run downloads Apple's speech model, which needs an internet connection and some free space. Connect to the internet and try again."
            case "reading the audio": hint = "The audio track couldn't be read. If the video is on an external or network drive, copy it to this Mac and try again."
            default: hint = "Try again; if it keeps happening, copy the video to this Mac first."
            }
            return "Transcription stopped while \(what). \(hint)\n\nDetails: \(ErrorExplainer.code(underlying))"
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
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("SermonTrim-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try await Self.extractAudio(asset: asset, to: tmp)
        } catch let e as TranscriptionError {
            throw e
        } catch {
            throw TranscriptionError.stage("reading the audio", error)
        }

        // 2. Make sure the on-device model for the language is present.
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw TranscriptionError.unsupportedLocale }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                status("Downloading the speech model (one time)…", nil)
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.stage("downloading the speech model", error)
        }

        // 3. Run the analyzer and collect word timings.
        status("Transcribing on this Mac…", 0)
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: tmp) } catch { throw TranscriptionError.stage("reading the audio", error) }
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
            throw TranscriptionError.stage("transcribing", error)
        }
        let words: [TranscriptWord]
        do { words = try await collector.value } catch { throw TranscriptionError.stage("transcribing", error) }
        let transcript = Transcript(words: words, duration: duration)
        if let url = try? Self.cacheURL(for: source), let data = try? JSONEncoder().encode(transcript) { try? data.write(to: url) }
        status("Transcript ready", 1)
        return transcript
    }

    /// Writes 16 kHz mono 16-bit PCM — small, universal, and exactly what speech recognition wants.
    /// Decodes the audio track directly, so it works for odd channel layouts and formats where an export session fails.
    static func extractAudio(asset: AVAsset, to url: URL) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw TranscriptionError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TranscriptionError.noAudio }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TranscriptionError.noAudio }
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let total = try await asset.load(.duration).seconds_
        var lastPTS = 0.0
        while let sb = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            lastPTS = max(lastPTS, CMSampleBufferGetPresentationTimeStamp(sb).seconds)
            let n = CMSampleBufferGetNumSamples(sb)
            guard n > 0, let block = CMSampleBufferGetDataBuffer(sb),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { continue }
            buffer.frameLength = AVAudioFrameCount(n)
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 2, destination: buffer.int16ChannelData![0])
            guard status == kCMBlockBufferNoErr else { continue }
            try file.write(from: buffer)
        }
        if reader.status == .failed {
            // Some recordings (notably live-stream downloads) have a damaged last few seconds of audio.
            // That's harmless here: keep everything that decoded, unless the damage starts well before the end.
            if lastPTS >= total * 0.97 || total - lastPTS < 120 { return }
            throw TranscriptionError.audioStops(at: lastPTS, of: total, reader.error ?? TranscriptionError.noAudio)
        }
    }
}
