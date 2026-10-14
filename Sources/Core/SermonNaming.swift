import Foundation
import AVFoundation

/// Sermon info entered by the user. Drives the output filename, the speaker's Finder tag, and embedded file metadata.
public struct SermonInfo: Equatable, Sendable {
    public var title: String
    public var date: Date
    public var speaker: String
    public init(title: String = "", date: Date = Date(), speaker: String = "") {
        self.title = title; self.date = date; self.speaker = speaker
    }
}

public enum SermonNaming {
    public static var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    /// The Sunday nearest to `date`: Mon–Wed go back to the previous Sunday, Thu–Sat go forward to the next one.
    public static func closestSunday(to date: Date, calendar: Calendar = SermonNaming.gregorian) -> Date {
        let start = calendar.startOfDay(for: date)
        let sinceSunday = calendar.component(.weekday, from: start) - 1        // Sunday = 0
        let delta = sinceSunday <= 3 ? -sinceSunday : 7 - sinceSunday
        return calendar.date(byAdding: .day, value: delta, to: start) ?? start
    }

    /// "10.4.26" — month and day without leading zeros, two-digit year.
    public static func dateString(_ date: Date, calendar: Calendar = SermonNaming.gregorian) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.month ?? 0).\(c.day ?? 0).\(String(format: "%02d", (c.year ?? 0) % 100))"
    }

    /// Keeps the title readable but safe as a filename.
    public static func sanitize(_ title: String) -> String {
        var t = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        t = t.components(separatedBy: CharacterSet.controlCharacters).joined()
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return String(t.prefix(120))
    }

    /// "The Lord Sees (10.4.26)", or nil when there is no title yet.
    public static func baseName(for info: SermonInfo) -> String? {
        let t = sanitize(info.title)
        return t.isEmpty ? nil : "\(t) (\(dateString(info.date)))"
    }

    /// First free URL for `base.ext` in `folder` ("Base 2.ext", "Base 3.ext"… if taken). Never overwrites.
    public static func uniqueURL(folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    public static func fileExtension(for source: URL) -> String {
        let e = source.pathExtension.lowercased()
        return ["mp4", "mov", "m4v"].contains(e) ? e : "mp4"
    }

    public static var desktop: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }
}

public enum Tagging {
    /// "Rick" or "Rick, Will" → one Finder tag per speaker.
    public static func speakers(from text: String) -> [String] {
        text.split(whereSeparator: { ",;&".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Sets Finder tags (the ones you filter by in Finder / Spotlight). Replaces any existing tags on the file.
    public static func apply(_ tags: [String], to url: URL) throws {
        try (url as NSURL).setResourceValue(tags as NSArray, forKey: .tagNamesKey)
    }

    public static func tags(of url: URL) -> [String] {
        ((try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames) ?? []
    }
}

enum EmbeddedMetadata {
    /// Title / artist / date written inside the video file so other apps (QuickTime, Finder info, podcast tools) see them.
    static func items(for info: SermonInfo) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let i = AVMutableMetadataItem()
            i.identifier = id
            i.value = value as NSString
            i.dataType = kCMMetadataBaseDataType_UTF8 as String
            i.extendedLanguageTag = "und"
            return i
        }
        var out: [AVMetadataItem] = []
        let title = SermonNaming.sanitize(info.title)
        if !title.isEmpty { out.append(item(.commonIdentifierTitle, title)) }
        let speaker = Tagging.speakers(from: info.speaker).joined(separator: ", ")
        if !speaker.isEmpty {
            out.append(item(.commonIdentifierArtist, speaker))
            out.append(item(.iTunesMetadataArtist, speaker))          // MP4 / M4V (©ART)
            out.append(item(.quickTimeUserDataArtist, speaker))       // MOV
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        out.append(item(.commonIdentifierCreationDate, f.string(from: info.date)))
        return out
    }
}
