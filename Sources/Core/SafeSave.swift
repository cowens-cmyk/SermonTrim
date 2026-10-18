import Foundation

/// Writes big exports somewhere iCloud doesn't sync, then puts the finished file in place in one coordinated step.
/// Writing a hidden temp file straight into an iCloud-synced Desktop and renaming it confuses iCloud: the file shows up
/// greyed out, only appears via "Reveal in Finder", or goes missing locally.
public enum SafeSave {
    /// A private staging folder on the same volume as `folder` (so the final move is an instant rename, not a copy).
    public static func stagingFolder(near folder: URL) -> URL {
        let fm = FileManager.default
        if let dir = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true) {
            return dir
        }
        let dir = fm.temporaryDirectory.appendingPathComponent("SermonTrim-staging-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func stagingURL(near folder: URL, ext: String) -> URL {
        stagingFolder(near: folder).appendingPathComponent("export-\(UUID().uuidString)").appendingPathExtension(ext)
    }

    /// Moves a finished file into its final place, telling iCloud / Finder about it (NSFileCoordinator).
    public static func move(_ source: URL, to destination: URL) throws {
        var coordError: NSError?
        var moveError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destination, options: .forReplacing, error: &coordError) { dest in
            do {
                try FileManager.default.moveItem(at: source, to: dest)
            } catch {
                moveError = error
            }
        }
        if let e = coordError ?? moveError { throw e }
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())   // empty staging folder
    }
}
