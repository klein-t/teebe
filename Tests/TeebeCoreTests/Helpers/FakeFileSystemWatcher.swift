import Foundation
@testable import TeebeCore

/// Hand-written `FileSystemWatcher` fake: records start/stop and lets a test fire
/// change events synchronously.
final class FakeFileSystemWatcher: FileSystemWatcher, @unchecked Sendable {
    private(set) var isWatching = false
    private(set) var watchedPaths: [String] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@Sendable ([String]) -> Void)?

    func start(paths: [String], debounce: TimeInterval, onChange: @escaping @Sendable ([String]) -> Void) {
        isWatching = true
        watchedPaths = paths
        startCount += 1
        handler = onChange
    }

    func stop() {
        isWatching = false
        stopCount += 1
        handler = nil
    }

    /// Simulate a coalesced change event.
    func fire(_ paths: [String]) {
        handler?(paths)
    }
}
