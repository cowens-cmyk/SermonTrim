import XCTest
import AVFoundation

/// Builds synthetic transcripts: every word lasts 0.3 s and words start 0.4 s apart (150 words a minute).
private struct WFScript {
    var words: [TranscriptWord] = []

    /// Says `text` starting at `t` and returns the time just after the last word (last word start + 0.4).
    @discardableResult
    mutating func say(_ text: String, at t: Double) -> Double {
        var cur = t
        for w in text.split(separator: " ") { words.append(.init(text: String(w), start: cur, end: cur + 0.3)); cur += 0.4 }
        return cur
    }

    /// Repeats `line` (0.3 s between sentences) until `until`, returning the time after the last word.
    mutating func repeatLine(_ line: String, from t: Double, until: Double) -> Double {
        var cur = t
        while cur < until { cur = say(line, at: cur + 0.3) }
        return cur
    }

    func transcript(duration: Double) -> Transcript { Transcript(words: words, duration: duration) }
}

private func sentence(_ text: String, _ start: Double, _ end: Double) -> Transcript.Sentence {
    Transcript.Sentence(text: text, start: start, end: end)
}

private func candidate(_ time: Double, score: Double, reason: String = "") -> MarkerCandidate {
    MarkerCandidate(time: time, score: score, reason: reason, context: "", source: .phrases)
}

private let sermonLine = "And this is a long thought about how God keeps his promises to his people."

// MARK: - Transcript.sentences

final class WFDetectionSentenceTests: XCTestCase {
    /// Kills the mutant that moved the pause check after `cur.append(w)` (it then compared a word with itself).
    func testLongPauseSplitsUnpunctuatedSpeech() {
        let words: [TranscriptWord] = [
            .init(text: "so", start: 0, end: 0.3), .init(text: "friends", start: 0.4, end: 0.7),
            .init(text: "today", start: 3.0, end: 3.3), .init(text: "we", start: 3.4, end: 3.7),
        ]
        let s = Transcript(words: words, duration: 10).sentences
        XCTAssertEqual(s.map(\.text), ["so friends", "today we"])
        XCTAssertEqual(s.first?.end ?? -1, 0.7, accuracy: 1e-9)
        XCTAssertEqual(s.last?.start ?? -1, 3.0, accuracy: 1e-9)
    }

    func testPauseOfExactlyTwoSecondsDoesNotSplit() {
        let words: [TranscriptWord] = [.init(text: "so", start: 0, end: 0.5), .init(text: "friends", start: 2.5, end: 2.8)]
        XCTAssertEqual(Transcript(words: words, duration: 5).sentences.map(\.text), ["so friends"])
    }

    func testQuestionAndExclamationMarksEndSentences() {
        var sc = WFScript()
        sc.say("Are you ready? Yes! Let us begin. and then more", at: 0)
        let s = sc.transcript(duration: 10).sentences
        XCTAssertEqual(s.map(\.text), ["Are you ready?", "Yes!", "Let us begin.", "and then more"])
    }

    func testEmptyWordListHasNoSentences() {
        XCTAssertTrue(Transcript(words: [], duration: 100).sentences.isEmpty)
        let d = MarkerDetector.heuristicCandidates(transcript: Transcript(words: [], duration: 100), settings: MarkerSettings())
        XCTAssertTrue(d.starts.isEmpty)
        XCTAssertTrue(d.ends.isEmpty)
        XCTAssertEqual(d.notes, ["The transcript is empty."])
    }
}

// MARK: - runStart / snapStarts

final class WFDetectionSnapTests: XCTestCase {
    let settings = MarkerSettings()

    /// Kills the mutant that checks `sentences[j]` instead of `sentences[j - 1]` for the boundary phrase.
    func testRunStartStopsRightAfterTheBoundarySentence() {
        let s = [
            sentence("What a powerful name it is.", 0, 2),
            sentence("Amen.", 2.5, 3),
            sentence("My name is Will.", 3.5, 5),
            sentence("We have a lot to cover.", 5.5, 7),
        ]
        XCTAssertEqual(MarkerDetector.runStart(sentences: s, index: 3, boundaries: settings.transitionPhrases), 2)
        XCTAssertEqual(MarkerDetector.runStart(sentences: s, index: 2, boundaries: settings.transitionPhrases), 2)
    }

    func testRunStartStopsAtATwelveSecondPause() {
        let s = [
            sentence("Some song lyrics here.", 0, 5),
            sentence("Still singing.", 5.5, 8),
            sentence("My name is Will.", 20, 22),          // 12 s after the previous sentence
            sentence("We have a lot to cover.", 22.5, 25),
        ]
        XCTAssertEqual(MarkerDetector.runStart(sentences: s, index: 3, boundaries: settings.transitionPhrases), 2)
        // 11.9 s is not enough: the walk continues back to the beginning.
        var t = s
        t[2] = sentence("My name is Will.", 19.9, 22)
        XCTAssertEqual(MarkerDetector.runStart(sentences: t, index: 3, boundaries: settings.transitionPhrases), 0)
    }

    func testRunStartNormalizesCurlyApostropheAndCase() {
        let s = [
            sentence("Father we thank you.", 0, 2),
            sentence("IN JESUS’ NAME WE PRAY.", 2.5, 4),
            sentence("My name is Will.", 4.5, 6),
            sentence("We have a lot to cover.", 6.5, 8),
        ]
        XCTAssertEqual(MarkerDetector.runStart(sentences: s, index: 3, boundaries: settings.transitionPhrases), 2)
    }

    func testSnapMovesCandidateToStartOfStretch() {
        let s = [
            sentence("You can be seated and kids can be dismissed.", 0, 4),
            sentence("My name is Will.", 6, 8),
            sentence("We have a lot to cover.", 8.5, 10),
            sentence("Turn to Genesis chapter 30.", 10.5, 12),
        ]
        let out = MarkerDetector.snapStarts([candidate(10.5, score: 5, reason: "says “chapter”")], sentences: s, settings: settings)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].time, 6, accuracy: 1e-9)
        XCTAssertEqual(out[0].score, 5, accuracy: 1e-9)    // 2 s gap: no "be seated" bonus
        XCTAssertEqual(out[0].reason, "says “chapter”; start of this stretch of speech")
    }

    func testSnapRefusedWhenItWouldMoveMoreThan25Minutes() {
        // One sentence every 10 s with 0.5 s gaps, no boundary phrases, for 30 minutes.
        let s = stride(from: 0.0, to: 1800, by: 10).map { sentence("And the story goes on.", $0, $0 + 9.5) }
        let far = MarkerDetector.snapStarts([candidate(1500, score: 5)], sentences: s, settings: settings)
        XCTAssertEqual(far.first?.time ?? -1, 1500, accuracy: 1e-9)
        XCTAssertFalse(far.first?.reason.contains("start of this stretch") ?? true)
        let near = MarkerDetector.snapStarts([candidate(1490, score: 5)], sentences: s, settings: settings)
        XCTAssertEqual(near.first?.time ?? -1, 0, accuracy: 1e-9)
    }

    func testCandidatesSnappingToTheSameSentenceMergeKeepingHigherScore() {
        let s = [
            sentence("Amen.", 0, 1),
            sentence("My name is Will.", 1.5, 3),
            sentence("Let us look at the text.", 3.5, 6),
            sentence("Turn to Genesis chapter 30.", 6.5, 9),
        ]
        let out = MarkerDetector.snapStarts([candidate(3.5, score: 3, reason: "low"), candidate(6.5, score: 7, reason: "high")],
                                            sentences: s, settings: settings)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].time, 1.5, accuracy: 1e-9)
        XCTAssertEqual(out[0].score, 7, accuracy: 1e-9)
        XCTAssertTrue(out[0].reason.hasPrefix("high"))
    }

    /// Kills the mutant that removed `c.score += 4` from the "follows be seated / dismissed" bonus.
    func testBeSeatedBonusAddsFourPoints() {
        let s = [
            sentence("You can be seated and kids can be dismissed.", 0, 100),
            sentence("My name is Will.", 120, 122),
            sentence("We have a lot to cover.", 122.5, 125),
        ]
        let out = MarkerDetector.snapStarts([candidate(120, score: 5, reason: "x")], sentences: s, settings: settings)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].time, 120, accuracy: 1e-9)
        XCTAssertEqual(out[0].score, 9, accuracy: 1e-9)
        XCTAssertEqual(out[0].reason, "x; follows “be seated / dismissed”")
    }

    func testBeSeatedBonusOnlyForGapsFrom8To90Seconds() {
        func score(gap: Double) -> Double {
            let s = [sentence("Please have a seat.", 0, 10), sentence("My name is Will.", 10 + gap, 12 + gap)]
            return MarkerDetector.snapStarts([candidate(10 + gap, score: 5)], sentences: s, settings: settings).first?.score ?? -1
        }
        XCTAssertEqual(score(gap: 7.5), 5, accuracy: 1e-9)
        XCTAssertEqual(score(gap: 8), 9, accuracy: 1e-9)
        XCTAssertEqual(score(gap: 89.5), 9, accuracy: 1e-9)
        XCTAssertEqual(score(gap: 90), 5, accuracy: 1e-9)
    }

    func testBeSeatedBonusNeedsTheSeatingPhrase() {
        let s = [sentence("Thank you all for singing.", 0, 10), sentence("My name is Will.", 30, 32)]
        let out = MarkerDetector.snapStarts([candidate(30, score: 5)], sentences: s, settings: settings)
        XCTAssertEqual(out.first?.score ?? -1, 5, accuracy: 1e-9)
    }

    /// Replaces StartSnapTests.testStartSnapsBackToTheBeginningOfTheMessage: here only snapping can produce the
    /// right answer, because the first sermon sentence has no start phrase and follows the seating line by just 2 s.
    func testStartSnapsBackToTheBeginningOfTheMessage_strict() throws {
        var sc = WFScript()
        // A song lyric at the top of the file, then a minute of music before the closing prayer.
        var t = sc.say("What a powerful name it is.", at: 0)
        t = sc.say("God we thank you. In Jesus name we pray. Amen. You can be seated and kids you can be dismissed.", at: 60)
        let sermonStart = t + 2
        t = sc.say("My name is Will and I am glad to be here with you.", at: sermonStart)
        t = sc.repeatLine(sermonLine, from: t, until: sermonStart + 4 * 60)
        let scripture = t + 1
        t = sc.say("Turn to Genesis chapter 30.", at: scripture)
        t = sc.repeatLine(sermonLine, from: t, until: sermonStart + 40 * 60)
        t = sc.say("In Jesus name we pray. Amen.", at: t)
        let tr = sc.transcript(duration: t + 200)
        let first = try XCTUnwrap(MarkerDetector.heuristicCandidates(transcript: tr, settings: MarkerSettings()).starts.first)
        XCTAssertEqual(first.time, sermonStart, accuracy: 0.01)
        XCTAssertTrue(first.reason.contains("start of this stretch of speech"), first.reason)

        // And directly: a hand-made candidate at the scripture reading snaps to exactly the sermon start.
        let snapped = MarkerDetector.snapStarts([candidate(scripture, score: 5)], sentences: tr.sentences, settings: MarkerSettings())
        XCTAssertEqual(try XCTUnwrap(snapped.first).time, sermonStart, accuracy: 1e-9)
    }
}

// MARK: - startCandidates

final class WFDetectionStartTests: XCTestCase {
    let settings = MarkerSettings()

    /// "Amen." at 0 (qualifies only through the i == 0 and gap bonuses), another "Amen." at 100 (scores 2, dropped),
    /// then a "Welcome." `gap` seconds after that. Little speech follows, so nothing gets a continuous-speech bonus.
    func starts(welcomeGap gap: Double) -> [MarkerCandidate] {
        var sc = WFScript()
        sc.words = [.init(text: "Amen.", start: 0, end: 0.5), .init(text: "Amen.", start: 100, end: 100.5)]
        sc.say("Welcome.", at: 100.5 + gap)
        let tr = sc.transcript(duration: 1000)
        return MarkerDetector.startCandidates(sentences: tr.sentences, transcript: tr, settings: settings)
    }

    func testFirstSentenceQualifiesThroughTheFirstSentenceBonus() {
        let s = starts(welcomeGap: 1)
        XCTAssertEqual(s.count, 1)        // the "Welcome." 1 s later scores 2 and is dropped
        XCTAssertEqual(s.first?.time ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(s.first?.score ?? -1, 3, accuracy: 1e-9)
    }

    func testFourSecondGapReachesTheThreshold() {
        XCTAssertFalse(starts(welcomeGap: 3.9).contains { abs($0.time - 104.4) < 0.01 })
        let c = starts(welcomeGap: 4).first { abs($0.time - 104.5) < 0.01 }
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.score ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(c?.reason, "says “welcome”")
    }

    func testEightSecondGapScoresMoreAndSaysSo() {
        let c = starts(welcomeGap: 8).first { abs($0.time - 108.5) < 0.01 }
        XCTAssertEqual(c?.score ?? -1, 4, accuracy: 1e-9)
        XCTAssertEqual(c?.reason, "says “welcome”, follows 8 s of quiet/music")
    }

    func testStartsAfter70PercentAreIgnored() {
        var sc = WFScript()
        sc.say("Amen.", at: 0)
        let late = 750.0
        var t = sc.say("Good morning and welcome. Open your bible to chapter 3.", at: late)
        t = sc.repeatLine(sermonLine, from: t, until: 990)
        let tr = sc.transcript(duration: 1000)
        let s = MarkerDetector.startCandidates(sentences: tr.sentences, transcript: tr, settings: settings)
        XCTAssertFalse(s.contains { $0.time >= 700 }, "\(s.map(\.time))")
        // The same speech at 60% is found.
        var sc2 = WFScript()
        sc2.say("Amen.", at: 0)
        t = sc2.say("Good morning and welcome. Open your bible to chapter 3.", at: 600)
        _ = sc2.repeatLine(sermonLine, from: t, until: 990)
        let tr2 = sc2.transcript(duration: 1000)
        XCTAssertTrue(MarkerDetector.startCandidates(sentences: tr2.sentences, transcript: tr2, settings: settings).contains { abs($0.time - 600) < 0.01 })
    }

    /// Announcements with "good morning / welcome" compete with the real sermon start after "be seated".
    func testSermonStartBeatsAnnouncementGreeting() throws {
        var sc = WFScript()
        var t = sc.say("What a powerful name it is.", at: 30)
        let announcements = t + 60
        t = sc.say("Good morning and welcome to Hope Church.", at: announcements)
        t = sc.repeatLine("We have a picnic next Sunday after the service and everyone is invited to come.", from: t, until: announcements + 180)
        t = sc.say("Let's pray. Father we thank you for this day. In Jesus name we pray. Amen. You can be seated.", at: t + 0.3)
        let sermon = t + 10
        t = sc.say("Turn with me to John chapter 3.", at: sermon)
        t = sc.repeatLine(sermonLine, from: t, until: sermon + 35 * 60)
        t = sc.say("In Jesus name we pray. Amen.", at: t)
        let tr = sc.transcript(duration: t + 300)
        let d = MarkerDetector.heuristicCandidates(transcript: tr, settings: settings)
        let first = try XCTUnwrap(d.starts.first)
        XCTAssertEqual(first.time, sermon, accuracy: 0.01)
        XCTAssertTrue(first.reason.contains("be seated"), first.reason)
        XCTAssertTrue(d.starts.contains { abs($0.time - announcements) < 0.01 }, "announcements should remain an alternate")
    }
}

// MARK: - endCandidates

final class WFDetectionEndTests: XCTestCase {
    let settings = MarkerSettings()

    /// Kills the mutant that flipped `after < 40` to `after > 40`.
    func testLittleSpeechAfterwardsBonusGoesToTheQuietEnding() throws {
        var sc = WFScript()
        var t = sc.repeatLine(sermonLine, from: 0, until: 1800)
        let midAmen = sc.say("Amen.", at: t + 0.3) - 0.1
        t = sc.repeatLine(sermonLine, from: midAmen, until: 2400)
        let finalAmen = sc.say("Amen.", at: t + 0.3) - 0.1
        let tr = sc.transcript(duration: 2700)
        let ends = MarkerDetector.endCandidates(sentences: tr.sentences, transcript: tr, settings: settings)
        let final = try XCTUnwrap(ends.first { abs($0.time - finalAmen) < 0.01 })
        let mid = try XCTUnwrap(ends.first { abs($0.time - midAmen) < 0.01 })
        XCTAssertTrue(final.reason.contains("little speech afterwards"), final.reason)
        XCTAssertFalse(mid.reason.contains("little speech afterwards"), mid.reason)
        XCTAssertEqual(ends.first?.time ?? -1, finalAmen, accuracy: 0.01)
        XCTAssertGreaterThan(final.score, mid.score + 4)
    }

    func testEndsBefore60PercentAreNotConsidered() {
        var sc = WFScript()
        var t = sc.repeatLine(sermonLine, from: 0, until: 900)
        t = sc.say("In Jesus name we pray. Amen.", at: t + 0.3)
        let tr = sc.transcript(duration: 3000)    // long worship set afterwards, not transcribed
        XCTAssertTrue(MarkerDetector.endCandidates(sentences: tr.sentences, transcript: tr, settings: settings).isEmpty)
        _ = t
    }

    func testEndBonusPenalisesFastSpeechAfterwards() {
        var quiet = WFScript()
        _ = quiet.repeatLine(sermonLine, from: 0, until: 600)
        var busy = quiet
        busy.say(String(repeating: "word ", count: 400), at: 605)   // 150 words a minute right after
        let a = MarkerDetector.endBonus(quiet.transcript(duration: 1000), at: 600)
        let b = MarkerDetector.endBonus(busy.transcript(duration: 1000), at: 600)
        XCTAssertGreaterThan(a, 1)
        XCTAssertEqual(a - b, 1.5, accuracy: 1e-9)
    }

    func testCurlyApostropheAndCaseMatchEndPhrases() throws {
        var sc = WFScript()
        let t = sc.repeatLine(sermonLine, from: 0, until: 700)
        let end = sc.say("NOW LET’S STAND TOGETHER.", at: t + 0.3) - 0.1
        let tr = sc.transcript(duration: 800)
        let c = try XCTUnwrap(MarkerDetector.endCandidates(sentences: tr.sentences, transcript: tr, settings: settings).first)
        XCTAssertEqual(c.time, end, accuracy: 0.01)
        XCTAssertTrue(c.reason.hasPrefix("says “let's stand”"), c.reason)
    }
}

// MARK: - Sermon-only files (replaces MessageOnlyTests.testSermonOnlyFileStartsNearTheBeginning)

final class WFDetectionMessageOnlyTests: XCTestCase {
    let line = "So friends today we are going to talk about grace and how God meets us right where we are."

    func detect(speechFrom start: Double, chatter: Bool) -> (DetectedMarkers, amenEnd: Double, fileEnd: Double) {
        var sc = WFScript()
        var t = start - 0.3
        t = sc.repeatLine(line, from: t, until: start + 45 * 60)
        t = sc.say("In Jesus name we pray.", at: t + 0.3)
        t = sc.say("Amen.", at: t + 0.3)
        let amenEnd = t - 0.1
        if chatter { t = sc.repeatLine("Thanks for coming everyone and grab a coffee on the way out.", from: amenEnd + 5 - 0.3, until: amenEnd + 65) }
        let tr = sc.transcript(duration: t + 4)
        return (MarkerDetector.heuristicCandidates(transcript: tr, settings: MarkerSettings()), amenEnd, t + 4)
    }

    func testSermonOnlyFile_endLandsOnAmenNotThePrayer() throws {
        let (d, amen, _) = detect(speechFrom: 1.2, chatter: false)
        XCTAssertEqual(try XCTUnwrap(d.starts.first).time, 1.2, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(d.ends.first).time, amen, accuracy: 0.05)
    }

    func testSermonOnlyFile_speechAtZero() throws {
        let (d, amen, _) = detect(speechFrom: 0, chatter: false)
        XCTAssertEqual(try XCTUnwrap(d.starts.first).time, 0, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(d.ends.first).time, amen, accuracy: 0.05)
    }

    func testSermonOnlyFile_instrumentalPreRoll() throws {
        let (d, amen, _) = detect(speechFrom: 20, chatter: false)
        XCTAssertEqual(try XCTUnwrap(d.starts.first).time, 20, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(d.ends.first).time, amen, accuracy: 0.05)
    }

    func testSermonOnlyFile_trailingChatterAfterAmen() throws {
        let (d, amen, fileEnd) = detect(speechFrom: 1.2, chatter: true)
        let end = try XCTUnwrap(d.ends.first).time
        XCTAssertEqual(end, amen, accuracy: 0.05)
        XCTAssertLessThan(end, fileEnd - 60)
    }
}

// MARK: - TranscriptionService.extractAudio damaged tail

final class WFDetectionExtractAudioTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") else { throw XCTSkip("ffmpeg not installed") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-wfdet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { if let dir { try? FileManager.default.removeItem(at: dir) } }

    /// An AAC file with the index up front, cut to `keep` of its bytes, so decoding fails part way through.
    func truncatedAudio(seconds: Int, keep: Double) throws -> URL {
        let full = dir.appendingPathComponent("full-\(seconds).m4a")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=16000", "-t", "\(seconds)",
                       "-c:a", "aac", "-b:a", "32k", "-movflags", "+faststart", full.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let data = try Data(contentsOf: full)
        let cut = dir.appendingPathComponent("cut-\(seconds).m4a")
        try data.prefix(Int(Double(data.count) * keep)).write(to: cut)
        return cut
    }

    /// Kills the mutant that turned `||` into `&&`: a 60 s file damaged from about 30 s is within 120 s of the end.
    func testShortFileWithDamagedSecondHalfIsStillTranscribed() async throws {
        let src = try truncatedAudio(seconds: 60, keep: 0.5)
        let out = dir.appendingPathComponent("short.caf")
        try await TranscriptionService.extractAudio(asset: AVURLAsset(url: src), to: out)
        let f = try AVAudioFile(forReading: out)
        let secs = Double(f.length) / f.processingFormat.sampleRate
        XCTAssertGreaterThan(secs, 10)
        XCTAssertLessThan(secs, 55)    // proves the reader really stopped early
    }

    func testLongFileDamagedWellBeforeTheEndThrowsAudioStops() async throws {
        let src = try truncatedAudio(seconds: 300, keep: 0.3)
        do {
            try await TranscriptionService.extractAudio(asset: AVURLAsset(url: src), to: dir.appendingPathComponent("long.caf"))
            XCTFail("expected audioStops")
        } catch TranscriptionError.audioStops(let at, let total, _) {
            XCTAssertEqual(total, 300, accuracy: 1)
            XCTAssertLessThan(at, total - 120)
            XCTAssertGreaterThan(at, 10)
        }
    }

    func testUndamagedFileExtractsFully() async throws {
        let src = try truncatedAudio(seconds: 20, keep: 1.0)
        let out = dir.appendingPathComponent("full.caf")
        try await TranscriptionService.extractAudio(asset: AVURLAsset(url: src), to: out)
        let f = try AVAudioFile(forReading: out)
        XCTAssertEqual(Double(f.length) / f.processingFormat.sampleRate, 20, accuracy: 0.5)
    }
}
