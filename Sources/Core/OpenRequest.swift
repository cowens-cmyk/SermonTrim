import Foundation

/// A request from outside the app to open a video, optionally with In/Out points and auto-detect.
///
/// Accepted forms:
/// - a file URL (Finder, `open -a "Sermon Trim" video.mp4`, drag onto the Dock icon)
/// - `sermontrim://open?path=/path/to/video.mp4&in=00:44:01:20&out=01:23:08:07&detect=1`
/// - launch arguments: `"Sermon Trim" /path/to/video.mp4 [--in TIMECODE] [--out TIMECODE] [--detect]`
///   (also through `open -a "Sermon Trim" --args …`)
///
/// Times take any form `parseTimecode` accepts: HH:MM:SS:FF, HH:MM:SS, MM:SS, or seconds.
public struct OpenRequest: Equatable, Sendable {
    public var file: URL
    public var inText: String?
    public var outText: String?
    public var detect = false

    public init(file: URL, inText: String? = nil, outText: String? = nil, detect: Bool = false) {
        self.file = file
        self.inText = inText
        self.outText = outText
        self.detect = detect
    }

    public init?(url: URL) {
        if url.isFileURL { self.init(file: url); return }
        guard url.scheme?.lowercased() == "sermontrim",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action = (c.host ?? "").lowercased()
        guard action == "open" || action.isEmpty else { return nil }
        func item(_ names: String...) -> String? {
            c.queryItems?.first { names.contains($0.name.lowercased()) }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let path = item("path", "file") else { return nil }
        self.init(file: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
                  inText: item("in", "start"), outText: item("out", "end"),
                  detect: ["1", "true", "yes"].contains(item("detect")?.lowercased() ?? ""))
    }

    /// Reads launch arguments. Only an existing file counts as the video, so system arguments such as
    /// `-NSDocumentRevisionsDebugMode YES` are ignored.
    public static func fromArguments(_ args: [String], fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> OpenRequest? {
        var file: URL?
        var inText: String?, outText: String?, detect = false
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--in", "--start": if i + 1 < args.count { inText = args[i + 1]; i += 1 }
            case "--out", "--end": if i + 1 < args.count { outText = args[i + 1]; i += 1 }
            case "--detect": detect = true
            default:
                if file == nil, !a.hasPrefix("-") {
                    let path = (a as NSString).expandingTildeInPath
                    if fileExists(path) { file = URL(fileURLWithPath: path) }
                    else if let u = URL(string: a), let r = OpenRequest(url: u) { return r }
                }
            }
            i += 1
        }
        guard let file else { return nil }
        return OpenRequest(file: file, inText: inText, outText: outText, detect: detect)
    }
}
