import Foundation

/// Thread-safe cancel flag. The engine's reader/writer loops run on dispatch queues, where Task.isCancelled isn't visible.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    public func cancel() { lock.lock(); flag = true; lock.unlock() }
}
