import XCTest
import AVFoundation
import CoreMedia

final class SermonNamingTests: XCTestCase {
    let cal = SermonNaming.gregorian
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 15))! }

    func testYourExample() {
        let info = SermonInfo(title: "The Lord Sees", date: date(2026, 10, 4), speaker: "Rick")
        XCTAssertEqual(SermonNaming.baseName(for: info), "The Lord Sees (10.4.26)")
        XCTAssertEqual(SermonNaming.dateString(date(2026, 1, 9)), "1.9.26")
        XCTAssertEqual(SermonNaming.dateString(date(2027, 12, 25)), "12.25.27")
    }

    func testClosestSundayForEveryWeekday() {
        // Oct 4 2026 is a Sunday.
        let sunday = date(2026, 10, 4)
        XCTAssertEqual(SermonNaming.closestSunday(to: date(2026, 10, 4)), cal.startOfDay(for: sunday))
        for d in 5...7 { XCTAssertEqual(SermonNaming.closestSunday(to: date(2026, 10, d)), cal.startOfDay(for: sunday), "Mon–Wed go back") }
        for d in 8...10 { XCTAssertEqual(SermonNaming.closestSunday(to: date(2026, 10, d)), cal.startOfDay(for: date(2026, 10, 11)), "Thu–Sat go forward") }
        XCTAssertEqual(SermonNaming.closestSunday(to: date(2026, 10, 3)), cal.startOfDay(for: sunday))   // Saturday → next day
    }

    func testSanitizeKeepsTitlesReadableAndSafe() {
        XCTAssertEqual(SermonNaming.sanitize("  The   Lord Sees  "), "The Lord Sees")
        XCTAssertEqual(SermonNaming.sanitize("Faith/Works: Part 1."), "Faith-Works- Part 1")
        XCTAssertEqual(SermonNaming.sanitize("..."), "")
        XCTAssertNil(SermonNaming.baseName(for: SermonInfo(title: "   ")))
    }

    func testUniqueURLNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-name-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = SermonNaming.uniqueURL(folder: dir, base: "The Lord Sees (10.4.26)", ext: "mp4")
        XCTAssertEqual(first.lastPathComponent, "The Lord Sees (10.4.26).mp4")
        try Data([0]).write(to: first)
        XCTAssertEqual(SermonNaming.uniqueURL(folder: dir, base: "The Lord Sees (10.4.26)", ext: "mp4").lastPathComponent, "The Lord Sees (10.4.26) 2.mp4")
    }

    func testSpeakersBecomeSeparateTags() {
        XCTAssertEqual(Tagging.speakers(from: "Rick"), ["Rick"])
        XCTAssertEqual(Tagging.speakers(from: " Rick , Will & Sam "), ["Rick", "Will", "Sam"])
        XCTAssertEqual(Tagging.speakers(from: "  "), [])
    }

    func testFinderTagsRoundTrip() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("st-tag-\(UUID().uuidString).mp4")
        try Data([1]).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        try Tagging.apply(["Rick"], to: f)
        XCTAssertEqual(Tagging.tags(of: f), ["Rick"])
    }
}

final class SermonExportTests: XCTestCase {
    var ffmpeg: String? { ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) } }

    func testExportEmbedsTitleSpeakerAndDate() async throws {
        guard let ffmpeg else { throw XCTSkip("ffmpeg not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("st-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-f", "lavfi", "-i", "sine=frequency=440", "-t", "20",
                       "-c:v", "libx264", "-g", "60", "-pix_fmt", "yuv420p", "-c:a", "aac", src.path]
        try p.run(); p.waitUntilExit()

        let cal = SermonNaming.gregorian
        let info = SermonInfo(title: "The Lord Sees", date: cal.date(from: DateComponents(year: 2026, month: 10, day: 4))!, speaker: "Rick")
        let out = SermonNaming.uniqueURL(folder: dir, base: SermonNaming.baseName(for: info)!, ext: "mp4")
        let spec = TrimSpec(inTime: CMTime(seconds: 1, preferredTimescale: 600), outTime: CMTime(seconds: 18, preferredTimescale: 600),
                            start: .none, end: Transition(kind: .fadeBlack, duration: 2))
        _ = try await ExportEngine().export(source: src, output: out, spec: spec, sermon: info) { _ in }
        try Tagging.apply(Tagging.speakers(from: info.speaker), to: out)

        XCTAssertEqual(out.lastPathComponent, "The Lord Sees (10.4.26).mp4")
        XCTAssertEqual(Tagging.tags(of: out), ["Rick"])
        let asset = AVURLAsset(url: out)
        var title: String?, artist: String?
        for fmt in try await asset.load(.availableMetadataFormats) {
            for i in try await asset.loadMetadata(for: fmt) {
                let v = try await i.load(.stringValue)
                if i.commonKey == .commonKeyTitle || i.identifier == .iTunesMetadataSongName { title = v }
                if i.commonKey == .commonKeyArtist || i.identifier == .iTunesMetadataArtist || i.identifier == .quickTimeUserDataArtist { artist = v }
            }
        }
        XCTAssertEqual(title, "The Lord Sees")
        XCTAssertEqual(artist, "Rick")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "original is left untouched")
    }
}
