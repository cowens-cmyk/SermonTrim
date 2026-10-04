import Foundation
import AVFoundation
import CoreMedia

public struct FileFacts: Sendable {
    public var codec: String
    public var width: Int
    public var height: Int
    public var frameRate: Double
    public var videoBitRate: Double
    public var audioCodec: String
    public var duration: Double
    public var fileSize: Int64
}

/// Input vs. output summary shown after every export.
public struct FileComparison: Sendable {
    public var original: FileFacts
    public var output: FileFacts
    public var sizeRatio: Double { original.fileSize > 0 ? Double(output.fileSize) / Double(original.fileSize) : 1 }
    public var looksTooLarge: Bool { sizeRatio > 1.15 }

    public var summary: String {
        func line(_ n: String, _ f: FileFacts) -> String {
            String(format: "%@: %@ %dx%d @ %.2f fps, %.2f Mbps video, %@ audio, %.1f s, %@", n, f.codec, f.width, f.height, f.frameRate,
                   f.videoBitRate / 1_000_000, f.audioCodec, f.duration, ByteCountFormatter.string(fromByteCount: f.fileSize, countStyle: .file))
        }
        return line("Original", original) + "\n" + line("Output  ", output) + String(format: "\nSize: %.1f%% of original", sizeRatio * 100)
    }

    static func facts(_ url: URL) async throws -> FileFacts {
        let asset = AVURLAsset(url: url)
        let info = try await SourceAnalyzer.analyze(asset: asset)
        let dur = try await asset.load(.duration).seconds_
        var audio = "none"
        if let a = try await asset.loadTracks(withMediaType: .audio).first, let fd = try await a.load(.formatDescriptions).first {
            audio = SourceAnalyzer.fourCC(CMFormatDescriptionGetMediaSubType(fd))
        }
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return FileFacts(codec: SourceAnalyzer.fourCC(info.codec), width: info.width, height: info.height, frameRate: info.frameRate,
                         videoBitRate: info.estimatedBitRate, audioCodec: audio, duration: dur, fileSize: size)
    }

    public static func compare(original: URL, output: URL) async throws -> FileComparison {
        FileComparison(original: try await facts(original), output: try await facts(output))
    }
}
