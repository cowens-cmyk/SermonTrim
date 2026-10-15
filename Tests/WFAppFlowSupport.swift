import XCTest
import Foundation

/// Shared helpers for the WFAppFlow* tests.
///
/// - Every AppModel setting lives in UserDefaults.standard, and AppModel.init runs cleanUpTempExports()
///   on the saved output folder (the real Desktop by default). `WFDefaults` snapshots every key AppModel
///   touches, points `outputFolder` at a scratch directory *before* any AppModel() is built, and restores
///   everything afterwards so no test touches the user's Desktop or leaks settings into other tests.
/// - Scratch files go under /private/tmp/claude-501.
enum WFDefaults {
    static let keys = ["startKind", "endKind", "startDuration", "endDuration", "tailSeconds", "outputFolder",
                       "recentSpeakers", "lastSpeaker", "startPhrases", "endPhrases"]

    static func snapshot() -> [String: Any] {
        var s: [String: Any] = [:]
        for k in keys { if let v = UserDefaults.standard.object(forKey: k) { s[k] = v } }
        return s
    }

    static func restore(_ s: [String: Any]) {
        for k in keys {
            if let v = s[k] { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    /// A clean, deterministic starting point: output into `folder`, no remembered speakers, explicit fades.
    static func prepare(outputFolder folder: URL) {
        let d = UserDefaults.standard
        for k in keys { d.removeObject(forKey: k) }
        d.set(folder.path, forKey: "outputFolder")
        d.set(TransitionKind.none.rawValue, forKey: "startKind")
        d.set(TransitionKind.fadeBlack.rawValue, forKey: "endKind")
        d.set(0.5, forKey: "startDuration")
        d.set(2.0, forKey: "endDuration")
        d.set(5.0, forKey: "tailSeconds")
    }
}

enum WFScratch {
    static let root = URL(fileURLWithPath: "/private/tmp/claude-501/wf-appflow-tests", isDirectory: true)

    static func make(_ label: String) throws -> URL {
        let dir = root.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func ls(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }
}

enum WFClip {
    static var ffmpeg: String? { ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// A small H.264 + AAC clip (2 s GOP) of `seconds` length.
    static func make(at url: URL, seconds: Int = 12) throws {
        guard let ffmpeg else { throw XCTSkip("ffmpeg not installed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30", "-f", "lavfi", "-i", "sine=frequency=440",
                       "-t", "\(seconds)", "-c:v", "libx264", "-preset", "ultrafast", "-g", "60", "-pix_fmt", "yuv420p", "-c:a", "aac", url.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "WFClip", code: Int(p.terminationStatus)) }
    }
}

struct WFTimeout: Error, CustomStringConvertible { let description: String }

@MainActor
enum WFWait {
    /// Polls `condition` every 50 ms; fails (never skips) when it doesn't become true in time.
    static func until(_ what: String, timeout: Double = 120, file: StaticString = #filePath, line: UInt = #line,
                      _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out after \(Int(timeout)) s waiting for \(what)", file: file, line: line)
                throw WFTimeout(description: what)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Waits for `.done`; a `.failed` state or a timeout is a test failure (replaces the XCTSkip in SermonFlowTests.waitUntilDone).
    static func done(_ model: AppModel, timeout: Double = 150, file: StaticString = #filePath, line: UInt = #line) async throws -> ExportEngine.Result {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch model.exportState {
            case .done(let r): return r
            case .failed(let m):
                XCTFail("export failed: \(m)", file: file, line: line)
                throw WFTimeout(description: "export failed: \(m)")
            default: break
            }
            if Date() > deadline {
                XCTFail("export did not finish within \(Int(timeout)) s: \(model.exportState)", file: file, line: line)
                throw WFTimeout(description: "export did not finish")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
