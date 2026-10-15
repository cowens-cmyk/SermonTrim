import XCTest
import AVFoundation

/// Naming / tagging / metadata unit tests that strengthen SermonNamingTests and ErrorExplainerTests.
final class WFAppFlowNamingTests: XCTestCase {
    let cal = SermonNaming.gregorian
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 15) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }

    var dir: URL!
    override func setUpWithError() throws { dir = try WFScratch.make("naming") }
    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(at: dir) } }

    // MARK: uniqueURL (replaces SermonNamingTests.testUniqueURLNeverOverwrites, which only had one collision)

    func testUniqueURLSkipsEveryTakenNumberAndNeverOverwrites() throws {
        let base = "The Lord Sees (10.4.26)"
        let a = dir.appendingPathComponent("\(base).mp4"), b = dir.appendingPathComponent("\(base) 2.mp4")
        try Data([1]).write(to: a)
        try Data([2]).write(to: b)
        XCTAssertEqual(SermonNaming.uniqueURL(folder: dir, base: base, ext: "mp4").lastPathComponent, "\(base) 3.mp4")
        try Data([3]).write(to: dir.appendingPathComponent("\(base) 3.mp4"))
        XCTAssertEqual(SermonNaming.uniqueURL(folder: dir, base: base, ext: "mp4").lastPathComponent, "\(base) 4.mp4")
        XCTAssertEqual(try Data(contentsOf: a), Data([1]), "existing files are untouched")
        XCTAssertEqual(try Data(contentsOf: b), Data([2]))
        XCTAssertEqual(SermonNaming.uniqueURL(folder: dir, base: base, ext: "mov").lastPathComponent, "\(base).mov", "other extensions don't collide")
    }

    // MARK: fileExtension

    func testFileExtensionLowercasesCameraExtensionsAndFallsBackToMP4() {
        XCTAssertEqual(SermonNaming.fileExtension(for: URL(fileURLWithPath: "/x/IMG_1234.MOV")), "mov")
        XCTAssertEqual(SermonNaming.fileExtension(for: URL(fileURLWithPath: "/x/clip.MP4")), "mp4")
        XCTAssertEqual(SermonNaming.fileExtension(for: URL(fileURLWithPath: "/x/clip.M4v")), "m4v")
        XCTAssertEqual(SermonNaming.fileExtension(for: URL(fileURLWithPath: "/x/clip.m4v")), "m4v")
        XCTAssertEqual(SermonNaming.fileExtension(for: URL(fileURLWithPath: "/x/clip.mkv")), "mp4")
        XCTAssertEqual(SermonNaming.fileExtension(for: URL(fileURLWithPath: "/x/noextension")), "mp4")
    }

    // MARK: baseName / sanitize

    func testBaseNameIsBuiltFromTheSanitizedTitle() {
        let d = date(2026, 10, 4)
        XCTAssertEqual(SermonNaming.baseName(for: SermonInfo(title: "  Faith/Works:   Part 1.  ", date: d)), "Faith-Works- Part 1 (10.4.26)")
        XCTAssertEqual(SermonNaming.baseName(for: SermonInfo(title: ".hidden", date: d)), "hidden (10.4.26)", "a leading dot would hide the file")
        XCTAssertNil(SermonNaming.baseName(for: SermonInfo(title: " .. ", date: d)))
        let name = SermonNaming.baseName(for: SermonInfo(title: "A/B", date: d))!
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func testSanitizeCapsLengthAndStripsControlCharacters() {
        XCTAssertEqual(SermonNaming.sanitize(String(repeating: "a", count: 200)).count, 120)
        XCTAssertEqual(SermonNaming.sanitize(String(repeating: "é", count: 130)).count, 120)
        XCTAssertEqual(SermonNaming.sanitize("A\u{0}B\u{7}C"), "ABC")
        XCTAssertEqual(SermonNaming.sanitize("Grace\nUpon\tGrace"), "GraceUponGrace", "newlines/tabs are control characters and are removed")
        // A long title pasted from a transcript still gives a filename under the 255-byte limit.
        let base = SermonNaming.baseName(for: SermonInfo(title: String(repeating: "Word ", count: 100), date: date(2026, 10, 4)))!
        XCTAssertLessThan("\(base) 99.mp4".utf8.count, 255)
    }

    // MARK: dateString (replaces SermonNamingTests.testYourExample)

    func testBaseNameAndDateStringFormat() {
        XCTAssertEqual(SermonNaming.baseName(for: SermonInfo(title: "The Lord Sees", date: date(2026, 10, 4))), "The Lord Sees (10.4.26)")
        XCTAssertEqual(SermonNaming.dateString(date(2005, 3, 6)), "3.6.05", "two-digit year is zero padded")
        XCTAssertEqual(SermonNaming.dateString(date(2100, 1, 1)), "1.1.00")
        XCTAssertEqual(SermonNaming.dateString(date(2027, 12, 25)), "12.25.27")
    }

    // MARK: Tagging

    func testSpeakersSplitOnSemicolonsAndIgnoreBareSeparators() {
        XCTAssertEqual(Tagging.speakers(from: "Rick; Will"), ["Rick", "Will"])
        XCTAssertEqual(Tagging.speakers(from: " , ; & "), [])
        XCTAssertEqual(Tagging.speakers(from: "Rick,,Will"), ["Rick", "Will"])
    }

    // MARK: closestSunday with a pinned calendar

    func testClosestSundayAcrossDSTAndNearMidnight() {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int, _ min: Int = 0) -> Date { c.date(from: DateComponents(year: y, month: m, day: day, hour: h, minute: min))! }
        func check(_ input: Date, _ y: Int, _ m: Int, _ day: Int, line: UInt = #line) {
            let r = SermonNaming.closestSunday(to: input, calendar: c)
            let comps = c.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: r)
            XCTAssertEqual(comps.weekday, 1, line: line)
            XCTAssertEqual(comps.hour, 0, line: line)
            XCTAssertEqual(comps.minute, 0, line: line)
            XCTAssertEqual([comps.year, comps.month, comps.day], [y, m, day], line: line)
        }
        check(d(2026, 11, 4, 12), 2026, 11, 1)          // DST ends Sun Nov 1 2026
        check(d(2026, 3, 5, 12), 2026, 3, 8)            // DST starts Sun Mar 8 2026
        check(d(2026, 3, 8, 23, 59), 2026, 3, 8)        // late on the DST Sunday itself
        check(d(2026, 10, 10, 23, 59), 2026, 10, 11)    // late Saturday evening → next day
        check(d(2026, 10, 7, 23, 59), 2026, 10, 4)      // late Wednesday → back
        check(d(2026, 10, 8, 0, 0), 2026, 10, 11)       // Thursday midnight → forward
    }

    // MARK: EmbeddedMetadata

    func testEmbeddedMetadataJoinsSpeakersAndSkipsEmptyTitle() async throws {
        let info = SermonInfo(title: "", date: date(2026, 10, 4), speaker: "Rick; Will")
        let items = EmbeddedMetadata.items(for: info)
        var byID: [AVMetadataIdentifier: String] = [:]
        for i in items { if let id = i.identifier { byID[id] = try await i.load(.stringValue) } }
        XCTAssertNil(byID[.commonIdentifierTitle], "no title item for an empty title")
        XCTAssertEqual(byID[.commonIdentifierArtist], "Rick, Will")
        XCTAssertEqual(byID[.iTunesMetadataArtist], "Rick, Will")
        XCTAssertEqual(byID[.quickTimeUserDataArtist], "Rick, Will")
        XCTAssertNotNil(byID[.commonIdentifierCreationDate])

        let titled = EmbeddedMetadata.items(for: SermonInfo(title: "  The  Lord Sees ", date: date(2026, 10, 4), speaker: ""))
        var ids: [AVMetadataIdentifier] = []
        var title: String?
        for i in titled { if let id = i.identifier { ids.append(id); if id == .commonIdentifierTitle { title = try await i.load(.stringValue) } } }
        XCTAssertEqual(title, "The Lord Sees", "title is sanitized")
        XCTAssertFalse(ids.contains(.commonIdentifierArtist), "no artist without a speaker")
    }

}
