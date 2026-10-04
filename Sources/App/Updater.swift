import Foundation
import AppKit

/// Checks GitHub (through the git already set up on this Mac) for newer code and rebuilds the app from it.
enum Updater {
    enum Result {
        case upToDate
        case available(commits: [String])
        case failed(String)
    }

    static var sourcePath: String? { Bundle.main.object(forInfoDictionaryKey: "SermonTrimSourcePath") as? String }

    static var installedCommitFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SermonTrim/installed-commit")
    }

    private static func git(_ args: [String], in dir: String) async -> (status: Int32, out: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir] + args
            p.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: (proc.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)) }
        }
    }

    static func check() async -> Result {
        guard let dir = sourcePath, FileManager.default.fileExists(atPath: dir + "/.git") else {
            return .failed("The source folder (\(sourcePath ?? "unknown")) isn't available. Plug in the drive it lives on, then try again.")
        }
        let fetch = await git(["fetch", "--quiet", "origin", "main"], in: dir)
        guard fetch.status == 0 else { return .failed("Couldn't reach GitHub: \(fetch.out)") }
        let remote = await git(["rev-parse", "origin/main"], in: dir)
        guard remote.status == 0 else { return .failed(remote.out) }
        let installed = (try? String(contentsOf: installedCommitFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if installed == remote.out { return .upToDate }
        let range = installed.isEmpty ? ["-5"] : ["\(installed)..origin/main"]
        let log = await git(["log", "--pretty=format:%s"] + range, in: dir)
        let lines = log.status == 0 ? log.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty } : []
        return .available(commits: lines.isEmpty ? ["Newer version available"] : lines)
    }

    /// Opens Terminal running Scripts/update.sh, which rebuilds, replaces this app, and reopens it.
    static func installUpdate() {
        guard let dir = sourcePath else { return }
        let script = "#!/bin/zsh\ncd \"\(dir)\" && ./Scripts/update.sh\nstatus=$?\necho\n[ $status -eq 0 ] || read -k 1 '?Update failed. Press any key to close.'\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SermonTrim-update.command")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func checkAndPrompt(silentIfCurrent: Bool) async {
        let result = await check()
        let alert = NSAlert()
        switch result {
        case .upToDate:
            if silentIfCurrent { return }
            alert.messageText = "Sermon Trim is up to date"
            alert.informativeText = "You have the latest version from GitHub."
            alert.runModal()
        case .failed(let message):
            if silentIfCurrent { return }
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        case .available(let commits):
            alert.messageText = "A new version of Sermon Trim is available"
            alert.informativeText = "What's new:\n• " + commits.prefix(6).joined(separator: "\n• ")
                + "\n\nUpdating rebuilds the app from GitHub in a Terminal window, then reopens it."
            alert.addButton(withTitle: "Update Now")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { installUpdate() }
        }
    }
}
