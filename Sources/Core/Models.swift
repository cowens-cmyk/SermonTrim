import Foundation
import CoreMedia

public enum TransitionKind: String, CaseIterable, Identifiable, Sendable {
    case none = "None"
    case fadeBlack = "Fade to Black"
    case fadeWhite = "Fade to White"
    public var id: String { rawValue }
}

public struct Transition: Equatable, Sendable {
    public var kind: TransitionKind
    public var duration: Double
    public init(kind: TransitionKind, duration: Double) {
        self.kind = kind
        self.duration = duration
    }
    public static let none = Transition(kind: .none, duration: 0)
    /// Effective duration in seconds (0 when there is no transition).
    public var effective: Double { kind == .none ? 0 : max(0, duration) }
}

public struct TrimSpec: Sendable {
    public var inTime: CMTime
    public var outTime: CMTime
    public var start: Transition
    public var end: Transition
    public init(inTime: CMTime, outTime: CMTime, start: Transition = .none, end: Transition = .none) {
        self.inTime = inTime
        self.outTime = outTime
        self.start = start
        self.end = end
    }
}

public struct ExportProgress: Sendable {
    public var stage: String
    public var fraction: Double
}

public enum ExportError: LocalizedError {
    case noVideoTrack
    case invalidRange
    case readerFailed(String)
    case writerFailed(String)
    case unsupported(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file has no video track."
        case .invalidRange: return "The In point must be before the Out point."
        case .readerFailed(let s): return "Reading failed: \(s)"
        case .writerFailed(let s): return "Writing failed: \(s)"
        case .unsupported(let s): return "Unsupported source: \(s)"
        case .cancelled: return "Export cancelled."
        }
    }
}

extension CMTime {
    var seconds_: Double { CMTimeGetSeconds(self) }
}

public func formatTimecode(_ seconds: Double, frameRate: Double = 30) -> String {
    guard seconds.isFinite else { return "00:00:00:00" }
    let s = max(0, seconds)
    let fps = max(1, Int(frameRate.rounded()))
    let totalFrames = Int((s * Double(fps)).rounded())
    let frames = totalFrames % fps
    let totalSeconds = totalFrames / fps
    return String(format: "%02d:%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, frames)
}

/// Parses "HH:MM:SS:FF", "MM:SS", "SS.s" etc. Returns seconds.
public func parseTimecode(_ text: String, frameRate: Double = 30) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard !parts.isEmpty, parts.count <= 4 else { return nil }
    if parts.count == 4 {
        guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]), let f = Double(parts[3]) else { return nil }
        return h * 3600 + m * 60 + s + f / max(1, frameRate.rounded())
    }
    var total = 0.0
    for p in parts {
        guard let v = Double(p) else { return nil }
        total = total * 60 + v
    }
    return total
}
