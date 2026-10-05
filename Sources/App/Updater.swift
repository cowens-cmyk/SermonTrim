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

    // MARK: GitHub Releases (works on any Mac, no Xcode or source folder needed)

    static let releasesURL = ProcessInfo.processInfo.environment["SERMONTRIM_RELEASES_URL"]
        ?? "https://api.github.com/repos/cowens-cmyk/SermonTrim/releases/latest"

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// The source-folder (rebuild) path is only used on the Mac that has the repository.
    static var hasSourceFolder: Bool {
        ProcessInfo.processInfo.environment["SERMONTRIM_FORCE_RELEASE_CHECK"] == nil
            && sourcePath.map { FileManager.default.fileExists(atPath: $0 + "/.git") } == true
    }

    struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String; let digest: String? }
        let tag_name: String
        let body: String?
        let assets: [Asset]
        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
        var dmg: Asset? { assets.first { $0.name.lowercased().hasSuffix(".dmg") } }
    }

    enum ReleaseResult {
        case upToDate
        case available(Release)
        case failed(String)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func checkRelease() async -> ReleaseResult {
        guard let url = URL(string: releasesURL) else { return .failed("Bad update address.") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 { return .upToDate }                 // nothing published yet
                guard http.statusCode == 200 else { return .failed("GitHub answered with status \(http.statusCode).") }
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard release.dmg != nil else { return .failed("The newest release has no download attached.") }
            return isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
        } catch {
            return .failed("Couldn't reach GitHub: \(error.localizedDescription)")
        }
    }

    private static func run(_ path: String, _ args: [String]) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            p.terminationHandler = { proc in
                cont.resume(returning: (proc.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)))
            }
            do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)) }
        }
    }

    /// Downloads the DMG, checks it, swaps the app in place after this one quits, and reopens it.
    @MainActor
    static func installRelease(_ release: Release) async -> String? {
        guard let asset = release.dmg, let url = URL(string: asset.browser_download_url) else { return "No download found." }
        let dest = Bundle.main.bundleURL
        if dest.path.contains("/AppTranslocation/") || dest.path.hasPrefix("/Volumes/") {
            return "Move Sermon Trim into your Applications folder first, then check for updates again."
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("SermonTrim-update-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let (tmp, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { return "Download failed (status \(http.statusCode))." }
            let dmg = work.appendingPathComponent("update.dmg")
            try fm.moveItem(at: tmp, to: dmg)

            if let digest = asset.digest, digest.hasPrefix("sha256:") {
                let (st, out) = await run("/usr/bin/shasum", ["-a", "256", dmg.path])
                guard st == 0, out.hasPrefix(digest.dropFirst(7)) else { return "The download didn't match its checksum, so it was not installed." }
            }

            let mount = work.appendingPathComponent("mnt")
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            let (attach, attachOut) = await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmg.path])
            guard attach == 0 else { return "Couldn't open the download: \(attachOut)" }
            defer { Task { _ = await run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) } }

            let staged = work.appendingPathComponent("Sermon Trim.app")
            let (cp, cpOut) = await run("/usr/bin/ditto", [mount.appendingPathComponent("Sermon Trim.app").path, staged.path])
            guard cp == 0 else { return "Couldn't unpack the update: \(cpOut)" }
            guard Bundle(url: staged)?.bundleIdentifier == Bundle.main.bundleIdentifier else { return "The download isn't Sermon Trim, so it was not installed." }
            let (verify, verifyOut) = await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
            guard verify == 0 else { return "The update's signature is damaged: \(verifyOut)" }

            let script = work.appendingPathComponent("swap.sh")
            let text = """
            #!/bin/zsh
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
            rm -rf "$1" && ditto "$2" "$1" && xattr -dr com.apple.quarantine "$1" 2>/dev/null
            open "$1"
            rm -rf "$3"
            """
            try text.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [script.path, dest.path, staged.path, work.path]
            try p.run()
            try? await Task.sleep(for: .milliseconds(400))
            NSApp.terminate(nil)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @MainActor
    static func checkReleaseAndPrompt(silentIfCurrent: Bool) async {
        let result = await checkRelease()
        let alert = NSAlert()
        switch result {
        case .upToDate:
            if silentIfCurrent { return }
            alert.messageText = "Sermon Trim is up to date"
            alert.informativeText = "You have the latest version (\(currentVersion))."
            alert.runModal()
        case .failed(let message):
            if silentIfCurrent { return }
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        case .available(let release):
            // Automated tests only: install without the dialog, and only when pointed at a custom test server.
            let env = ProcessInfo.processInfo.environment
            if env["SERMONTRIM_AUTOINSTALL"] == "1", env["SERMONTRIM_RELEASES_URL"] != nil {
                _ = await installRelease(release)
                return
            }
            alert.messageText = "Sermon Trim \(release.version) is available"
            alert.informativeText = "You have \(currentVersion).\n\n" + (release.body?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600).description ?? "")
            alert.addButton(withTitle: "Install and Restart")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                if let error = await installRelease(release) {
                    let fail = NSAlert()
                    fail.messageText = "The update wasn't installed"
                    fail.informativeText = error
                    fail.alertStyle = .warning
                    fail.runModal()
                }
            }
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
        guard hasSourceFolder else { await checkReleaseAndPrompt(silentIfCurrent: silentIfCurrent); return }
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
