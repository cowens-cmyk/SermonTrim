import Foundation

/// Turns Apple's generic "The operation could not be completed" into something that says what to fix.
public enum ErrorExplainer {
    public struct Explanation: Sendable {
        public var message: String
        /// True when macOS privacy settings (Files & Folders / Full Disk Access) are the likely cause.
        public var isPermission: Bool
    }

    public static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    public static func code(_ error: Error) -> String {
        let e = error as NSError
        var s = "\(e.domain) \(e.code)"
        if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { s += " / \(u.domain) \(u.code)" }
        return s
    }

    /// Checks the file and (optionally) the output folder before blaming the media.
    public static func explain(_ error: Error, operation: String, input: URL? = nil, outputFolder: URL? = nil) -> Explanation {
        if let e = error as? ExportError, case .cancelled = e { return Explanation(message: e.localizedDescription, isPermission: false) }
        if let e = error as? TranscriptionError { switch e { case .stage, .audioStops: return Explanation(message: e.localizedDescription, isPermission: false); default: break } }
        let fm = FileManager.default

        if let input {
            if !fm.fileExists(atPath: input.path) {
                return Explanation(message: "\(operation) failed: “\(input.lastPathComponent)” isn't there any more. It may have been moved, renamed, or its drive unplugged.", isPermission: false)
            }
            do { let h = try FileHandle(forReadingFrom: input); try h.close() } catch {
                return Explanation(message: "\(operation) failed: macOS isn't letting Sermon Trim read “\(input.lastPathComponent)”. Open System Settings ▸ Privacy & Security ▸ Files & Folders (or Full Disk Access) and allow Sermon Trim to access that folder or drive, then try again.", isPermission: true)
            }
        }
        if let outputFolder {
            if !fm.isWritableFile(atPath: outputFolder.path) {
                return Explanation(message: "\(operation) failed: Sermon Trim can't save into “\(outputFolder.lastPathComponent)”. Allow it under System Settings ▸ Privacy & Security ▸ Files & Folders (or Full Disk Access), or move the video to a folder you can write to.", isPermission: true)
            }
        }
        if let e = error as? ExportError { return Explanation(message: e.localizedDescription, isPermission: false) }
        let detail = (error as NSError).localizedDescription
        return Explanation(message: "\(operation) failed: \(detail)\n\nDetails for support: \(code(error)). The file is readable, so this usually means the video itself uses a format Sermon Trim can't copy cleanly, or the drive is full or disconnected.", isPermission: false)
    }

    /// Free space check so a full drive produces a clear message instead of a generic one.
    public static func checkSpace(for output: URL, needing bytes: Int64) throws {
        let folder = output.deletingLastPathComponent()
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let available = values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
        if available > 0 && available < bytes + 200_000_000 {
            let f = ByteCountFormatter()
            throw ExportError.writerFailed("There isn't enough free space on that drive. The export needs about \(f.string(fromByteCount: bytes)) and only \(f.string(fromByteCount: available)) is free.")
        }
    }
}
