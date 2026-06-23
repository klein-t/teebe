import Foundation

/// Watches one or more directory roots and reports coalesced, debounced change
/// events. `FSEventsWatcher` is the production implementation (FSEvents);
/// `FakeFileSystemWatcher` lets tests fire events synchronously.
public protocol FileSystemWatcher: AnyObject {
    var isWatching: Bool { get }

    /// Begin watching `paths`. Change notifications are debounced by `debounce`
    /// seconds and coalesced, then delivered as a batch of affected paths.
    func start(paths: [String], debounce: TimeInterval, onChange: @escaping @Sendable ([String]) -> Void)

    /// Stop watching and release resources. Safe to call when not watching.
    func stop()
}

public extension FileSystemWatcher {
    /// Convenience: start with the default debounce window (200ms).
    func start(paths: [String], onChange: @escaping @Sendable ([String]) -> Void) {
        start(paths: paths, debounce: 0.2, onChange: onChange)
    }
}
